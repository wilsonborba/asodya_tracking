import 'dart:convert';

/// Commit these identities in each application's tracking manifest.
class TrackingElement {
  const TrackingElement({
    required this.id,
    required this.label,
    required this.path,
  });
  final String id;
  final String label;
  final String path;
  bool get valid =>
      RegExp(r'^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$').hasMatch(id) &&
      label.trim().isNotEmpty &&
      path.trim().isNotEmpty;
  Map<String, dynamic> toJson() => {
    'element_id': id,
    'element_label': label,
    'element_path': path,
  };
}

class TrackingScreen {
  const TrackingScreen({
    required this.name,
    required this.route,
    required this.label,
  });
  final String name;
  final String route;
  final String label;
  bool matches(String path) {
    final pattern = route
        .split('/')
        .map((part) => part.startsWith(':') ? '[^/]+' : RegExp.escape(part))
        .join('/');
    return RegExp('^$pattern\$').hasMatch(path);
  }

  TrackingElement get surface => TrackingElement(
    id: '$name.surface',
    label: label,
    path: '$name > surface',
  );
}

String bounded(String text, int maxBytes) {
  final bytes = utf8.encode(text);
  if (bytes.length <= maxBytes) return text;
  var end = maxBytes;
  while (end > 0 && (bytes[end] & 0xc0) == 0x80) {
    end--;
  }
  return utf8.decode(bytes.sublist(0, end));
}

String routePath(String path) => path.split(RegExp(r'[?#]')).first;
bool sensitiveName(String text) => RegExp(
  r'password|passwd|token|secret|payment|credit.?card|card.?number|cvv|cvc',
  caseSensitive: false,
).hasMatch(text);

class TrackingPrivacy {
  final List<String> _secrets = [];
  void remember(String value) {
    if (value.length < 3 || _secrets.contains(value)) return;
    _secrets.add(value);
    if (_secrets.length > 100) _secrets.removeAt(0);
  }

  String clean(String text, {int maxBytes = 4000}) {
    var value = text;
    for (final secret in _secrets) {
      value = value.replaceAll(secret, '[redacted]');
    }
    value = value.replaceAll(
      RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
      'Bearer [redacted]',
    );
    value = value.replaceAll(
      RegExp(r'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'),
      '[redacted]',
    );
    value = value.replaceAll(
      RegExp(
        r'''(?:password|passwd|secret|token|authorization|cookie|(?:api|service|app)[_-]?key)["']?\s*[=:]\s*(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
        caseSensitive: false,
      ),
      'credential=[redacted]',
    );
    value = value.replaceAll(
      RegExp(r'https?://[^\s?#]+[?#][^\s]+'),
      '[url query omitted]',
    );
    return bounded(value, maxBytes);
  }
}
