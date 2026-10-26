import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../core/model.dart';
import '../domain/tracker.dart';

class TrackingScope extends InheritedWidget {
  const TrackingScope({super.key, required this.tracker, required super.child});
  final AsodyaTracker tracker;
  static AsodyaTracker? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TrackingScope>()?.tracker;
  @override
  bool updateShouldNotify(TrackingScope oldWidget) =>
      tracker != oldWidget.tracker;
}

/// Wrap an existing control. This does not change its layout, color or behavior.
class TrackedElement extends StatelessWidget {
  const TrackedElement({super.key, required this.element, required this.child});
  final TrackingElement element;
  final Widget child;
  @override
  Widget build(BuildContext context) => MetaData(
    metaData: element,
    behavior: HitTestBehavior.translucent,
    child: child,
  );
}

class TrackingRoot extends StatefulWidget {
  const TrackingRoot({super.key, required this.tracker, required this.child});
  final AsodyaTracker tracker;
  final Widget child;
  @override
  State<TrackingRoot> createState() => _TrackingRootState();
}

class _TrackingRootState extends State<TrackingRoot>
    with WidgetsBindingObserver {
  final Map<int, Offset> _down = {};
  DateTime _lastScroll = DateTime.fromMillisecondsSinceEpoch(0);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(widget.tracker.flush());
    }
  }

  void _up(PointerUpEvent event) {
    final from = _down.remove(event.pointer);
    if (from == null || (from - event.position).distance > 12) return;
    final result = HitTestResult();
    RendererBinding.instance.hitTestInView(
      result,
      event.position,
      event.viewId,
    );
    TrackingElement? element;
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is TrackingElement) {
        element = target.metaData as TrackingElement;
        break;
      }
    }
    widget.tracker.event(
      'click',
      element ?? widget.tracker.currentScreen.surface,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.maybeOf(context);
    if (media != null) {
      widget.tracker.viewportWidth = media.size.width.round();
      widget.tracker.viewportHeight = media.size.height.round();
      widget.tracker.theme = Theme.of(context).brightness.name;
    }
    final locale = Localizations.maybeLocaleOf(context);
    if (locale != null) widget.tracker.locale = locale.toLanguageTag();
    return TrackingScope(
      tracker: widget.tracker,
      child: NotificationListener<ScrollNotification>(
        onNotification: (n) {
          final now = DateTime.now();
          if (n is ScrollUpdateNotification &&
              now.difference(_lastScroll).inMilliseconds >= 1000) {
            _lastScroll = now;
            widget.tracker.event(
              'scroll',
              widget.tracker.currentScreen.surface,
              value: n.metrics.pixels.round().toString(),
            );
          }
          return false;
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _down[e.pointer] = e.position,
          onPointerUp: _up,
          onPointerCancel: (e) => _down.remove(e.pointer),
          child: widget.child,
        ),
      ),
    );
  }
}

/// GoRouter accepts NavigatorObserver, so apps do not need the same GoRouter version.
class TrackingNavigatorObserver extends NavigatorObserver {
  TrackingNavigatorObserver(this.tracker);
  final AsodyaTracker tracker;
  void _visit(Route<dynamic>? route) {
    final name = route?.settings.name;
    if (name != null) tracker.view(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _visit(route);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _visit(previousRoute);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      _visit(newRoute);
}

/// Use with existing controllers, or forward onChanged through input().
/// Password and payment fields must also set sensitive even when labels are translated.
class TrackedInput extends StatefulWidget {
  const TrackedInput({
    super.key,
    required this.element,
    required this.child,
    this.controller,
    this.sensitive = false,
  });
  final TrackingElement element;
  final Widget child;
  final TextEditingController? controller;
  final bool sensitive;
  static void input(
    BuildContext context,
    TrackingElement element,
    String value, {
    bool sensitive = false,
  }) => TrackingScope.maybeOf(
    context,
  )?.event('input', element, value: value, sensitive: sensitive);
  @override
  State<TrackedInput> createState() => _TrackedInputState();
}

class _TrackedInputState extends State<TrackedInput> {
  String? _last;
  @override
  void initState() {
    super.initState();
    _last = widget.controller?.text;
    widget.controller?.addListener(_changed);
  }

  @override
  void didUpdateWidget(TrackedInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_changed);
      _last = widget.controller?.text;
      widget.controller?.addListener(_changed);
    }
  }

  void _changed() {
    final text = widget.controller?.text;
    if (text != null && text != _last) {
      _last = text;
      TrackedInput.input(
        context,
        widget.element,
        text,
        sensitive: widget.sensitive,
      );
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      TrackedElement(element: widget.element, child: widget.child);
}

class TrackedSubmit extends StatelessWidget {
  const TrackedSubmit({
    super.key,
    required this.element,
    required this.onSubmit,
    required this.builder,
  });
  final TrackingElement element;
  final VoidCallback? onSubmit;
  final Widget Function(VoidCallback? submit) builder;
  @override
  Widget build(BuildContext context) => TrackedElement(
    element: element,
    child: builder(
      onSubmit == null
          ? null
          : () {
              TrackingScope.maybeOf(context)?.event('submit', element);
              onSubmit!();
            },
    ),
  );
}
