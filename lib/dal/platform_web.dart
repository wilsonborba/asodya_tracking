import 'package:web/web.dart' as web;
import 'package:http/browser_client.dart';

String? readSession(String key) {
  try {
    return web.window.sessionStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void writeSession(String key, String value) {
  try {
    web.window.sessionStorage.setItem(key, value);
  } catch (_) {
    /* Storage can be disabled. */
  }
}

BrowserClient createTrackingClient() => BrowserClient()..withCredentials = true;
