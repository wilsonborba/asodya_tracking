import 'package:http/http.dart' as http;

final Map<String, String> _storage = {};
String? readSession(String key) => _storage[key];
void writeSession(String key, String value) {
  _storage[key] = value;
}

http.Client createTrackingClient() => http.Client();
