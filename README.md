# Asodya Tracking

Shared Flutter error and usability tracking for Asodya applications. The gateway
stores errors and usage in separate relational tables. This package sends no user
id or IP. The gateway derives both.

## Integration

Consume this repository as a pinned Git dependency. Create one tracker per app.
Use its Navigator observer with GoRouter or MaterialApp. Wrap the existing app
builder child in `TrackingRoot`. Install error capture once and dispose the tracker
with the app. `TrackingRoot` preserves the existing layout and input behavior.

```dart
final tracker = AsodyaTracker(
  appId: 'annotations',
  baseUrl: 'https://api.asodya.com',
  buildVersion: '1.1.0',
  screens: const [
    TrackingScreen(name: 'article', route: '/article/:slug', label: 'Article'),
  ],
);
tracker.installErrorCapture();
final observer = TrackingNavigatorObserver(tracker);
```

Commit a tracking manifest in each app. The manifest lists screen names, route
templates, element ids, human labels, tree paths and descriptions. Use stable dot
ids, such as `article.content_language.dropdown`. Never use widget hashes or row
indexes as identities. Repeated controls share their semantic action identity.

Wrap controls with `TrackedElement`. Wrap fields with `TrackedInput` and their
existing controller. Fields without a controller can call `TrackedInput.input`
from their existing `onChanged`. Use `TrackedSubmit` or record a submit event in
the existing form callback. Unknown clicks use the nearest mapped ancestor, or
the screen surface. The root listener rejects drags and samples scrolling.

For routers whose route settings contain names instead of paths, also call
`tracker.view(router.routeInformationProvider.value.uri.path)` from the router's
existing navigation listener. This supplies the concrete path and template.

## Privacy and transport

Password, token, secret and payment values are dropped on the device before they
enter a queue. Mark sensitive fields explicitly, including fields with translated
labels. Only the fact that the field changed is recorded. Remembered sensitive
values are also removed from pending error text. Query strings and fragments are
removed from navigation paths. Bearer tokens and credential patterns are redacted.
Non-sensitive typed text is recorded as required by the applications' consent.

A browser tab keeps an anonymous session UUID and sequence in session storage.
Browser requests include the existing gateway cookie. The package never reads
that cookie. A gateway identity conflict rotates the UUID and retries pending
activity. No extra login screen or consent banner is added.

Events are batched every two seconds, up to 50 events and 60,000 encoded bytes.
Queues are bounded to 200 events and 20 errors. Retry uses exponential backoff,
up to 64 seconds, and keeps session/sequence for idempotency. Errors use their
separate endpoint. Transport failures never report themselves recursively.
Invalid payloads are discarded. Network and server failures retry.

`FlutterError.onError` and `PlatformDispatcher.onError` preserve previous handlers.
They are restored when the tracker is disposed. Inject `http.Client`, disable
`autoFlush` and inject `now` for isolated tests. Tests use fake transports only.

```sh
flutter pub get
flutter analyze
flutter test
```

For an existing shared component that cannot be edited, `TrackingRoot.resolveElement`
can use `elementFromSemantics` with declared localized label aliases. The helper
accepts interactive hits only. It never sends widget identifiers or arbitrary labels.
Explicit `TrackedElement` metadata takes priority. Include aliases in the app manifest.
An error can supply a route override; it is sanitized without changing navigation.
`sendError` waits for gateway acceptance for user-requested reports.
