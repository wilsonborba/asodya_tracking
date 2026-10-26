import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/model.dart';
import '../dal/platform.dart';

class AsodyaTracker {
  AsodyaTracker({
    required this.appId,
    required this.baseUrl,
    required this.buildVersion,
    required this.screens,
    http.Client? client,
    bool autoFlush = true,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       _client = client ?? createTrackingClient(),
       _ownsClient = client == null {
    _session = readSession('tracking.$appId.session') ?? _uuid();
    _seq = int.tryParse(readSession('tracking.$appId.seq') ?? '') ?? 0;
    _saveSession();
    if (autoFlush) {
      _timer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(flush()),
      );
    }
  }
  final String appId, baseUrl, buildVersion;
  final List<TrackingScreen> screens;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _now;
  final TrackingPrivacy privacy = TrackingPrivacy();
  final List<Map<String, dynamic>> _events = [], _errors = [];
  Timer? _timer;
  late String _session;
  int _seq = 0, _failures = 0;
  bool _sending = false, _disposed = false;
  DateTime _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
  String _path = '/', locale = 'en', theme = 'system';
  int viewportWidth = 0, viewportHeight = 0;
  TrackingScreen? _screen;
  FlutterExceptionHandler? _previousFlutter, _ownFlutter;
  bool Function(Object, StackTrace)? _previousPlatform, _ownPlatform;
  static String _uuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 15) | 64;
    b[8] = (b[8] & 63) | 128;
    final s = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-${s.substring(16, 20)}-${s.substring(20)}';
  }

  void _saveSession() {
    writeSession('tracking.$appId.session', _session);
    writeSession('tracking.$appId.seq', '$_seq');
  }

  TrackingScreen get currentScreen =>
      _screen ??
      (screens.isEmpty
          ? const TrackingScreen(name: 'app', route: '/', label: 'Application')
          : screens.first);
  void view(String path) {
    final safe = routePath(path);
    final matches = screens.where((s) => s.matches(safe));
    final selected = matches.isEmpty ? currentScreen : matches.first;
    if (_screen == selected && _path == safe) return;
    _screen = selected;
    _path = selected.sensitivePath ? selected.route : safe;
    event('view', selected.surface);
  }

  void event(
    String type,
    TrackingElement element, {
    String? value,
    bool sensitive = false,
  }) {
    if (_disposed || !element.valid) return;
    final secret = sensitive || sensitiveName('${element.id} ${element.label}');
    if (secret && value != null) privacy.remember(value);
    final event = <String, dynamic>{
      'seq': _seq++,
      'event_type': type,
      'screen': currentScreen.name,
      'route': currentScreen.route,
      'path': _path,
      ...element.toJson(),
      'value': secret || value == null ? null : privacy.clean(value),
      'sensitive': secret,
    };
    // A sensitive value never enters the queue or a serialized request.
    _events.add(event);
    if (_events.length > 200) _events.removeAt(0);
    _saveSession();
  }

  /// A user-requested error report completes only after the gateway accepts it.
  Future<void> sendError(
    Object error, {
    StackTrace? stack,
    String type = 'ClientReport',
  }) async {
    final value = <String, dynamic>{
      'app_id': appId,
      'session_id': _session,
      'route': _path,
      'error_type': bounded(type, 100),
      'message': privacy.clean(error.toString()),
      'stack': privacy.clean(stack?.toString() ?? '', maxBytes: 8000),
      'build_version': bounded(buildVersion, 80),
    };
    final response = await _post('errors', value);
    if (response.statusCode != 202) {
      throw StateError('Error report service unavailable');
    }
  }

  String _safeErrorRoute(String route) {
    final path = routePath(route);
    final sensitive = screens.where(
      (screen) => screen.sensitivePath && screen.matches(path),
    );
    return sensitive.isEmpty ? path : sensitive.first.route;
  }

  void error(
    Object error,
    StackTrace? stack, {
    String type = 'FlutterError',
    String? route,
  }) {
    if (_disposed) return;
    _errors.add({
      'app_id': appId,
      'session_id': _session,
      'route': route == null ? _path : _safeErrorRoute(route),
      'error_type': bounded(type, 100),
      'message': privacy.clean(error.toString()),
      'stack': privacy.clean(stack?.toString() ?? '', maxBytes: 8000),
      'build_version': bounded(buildVersion, 80),
    });
    if (_errors.length > 20) _errors.removeAt(0);
  }

  void installErrorCapture() {
    if (_ownFlutter != null) return;
    _previousFlutter = FlutterError.onError;
    _ownFlutter = (details) {
      error(details.exception, details.stack);
      _previousFlutter?.call(details);
    };
    FlutterError.onError = _ownFlutter;
    _previousPlatform = PlatformDispatcher.instance.onError;
    _ownPlatform = (error, stack) {
      this.error(error, stack, type: 'PlatformDispatcher');
      return _previousPlatform?.call(error, stack) ?? false;
    };
    PlatformDispatcher.instance.onError = _ownPlatform;
  }

  Map<String, dynamic> _batch(List<Map<String, dynamic>> events) => {
    'app_id': appId,
    'session_id': _session,
    'locale': bounded(locale, 35),
    'theme': bounded(theme, 32),
    'viewport_width': viewportWidth.clamp(0, 50000),
    'viewport_height': viewportHeight.clamp(0, 50000),
    'events': events,
  };
  void rotateSession() {
    _session = _uuid();
    _seq = 0;
    for (final e in _events) {
      e['seq'] = _seq++;
    }
    for (final e in _errors) {
      e['session_id'] = _session;
    }
    _saveSession();
  }

  Future<void> flush() async {
    if (_sending || _disposed || _now().isBefore(_retryAfter)) return;
    _sending = true;
    try {
      if (_events.isNotEmpty) {
        final selected = <Map<String, dynamic>>[];
        for (final event in _events.take(50)) {
          final trial = [...selected, event];
          if (utf8.encode(jsonEncode(_batch(trial))).length > 60000) break;
          selected.add(event);
        }
        if (selected.isNotEmpty) {
          final response = await _post('events', _batch(selected));
          if (response.statusCode == 409) {
            rotateSession();
            _backoff();
            return;
          }
          if (!_complete(response)) {
            _backoff();
            return;
          }
          _events.removeWhere(selected.contains);
        } else {
          _events.removeAt(0);
        }
      }
      if (_errors.isNotEmpty) {
        final error = _errors.first;
        // Re-scrub pending errors if a sensitive value was learned after capture.
        error['message'] = privacy.clean(error['message'] as String);
        error['stack'] = privacy.clean(
          error['stack'] as String,
          maxBytes: 8000,
        );
        final response = await _post('errors', error);
        if (!_complete(response)) {
          _backoff();
          return;
        }
        _errors.remove(error);
      }
      _failures = 0;
      _retryAfter = DateTime.fromMillisecondsSinceEpoch(0);
    } catch (_) {
      _backoff(); /* Never report transport errors recursively. */
    } finally {
      _sending = false;
    }
  }

  Future<http.Response> _post(
    String resource,
    Map<String, dynamic> value,
  ) => _client
      .post(
        Uri.parse(
          '${baseUrl.replaceFirst(RegExp(r'/$'), '')}/apps/api/v1/telemetry/$resource',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(value),
      )
      .timeout(const Duration(seconds: 10));
  bool _complete(http.Response response) =>
      response.statusCode == 202 ||
      [400, 413, 422].contains(response.statusCode);
  void _backoff() {
    _failures = (_failures + 1).clamp(1, 6);
    _retryAfter = _now().add(Duration(seconds: 1 << _failures));
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (FlutterError.onError == _ownFlutter) {
      FlutterError.onError = _previousFlutter;
    }
    if (PlatformDispatcher.instance.onError == _ownPlatform) {
      PlatformDispatcher.instance.onError = _previousPlatform;
    }
    if (_ownsClient) _client.close();
  }
}
