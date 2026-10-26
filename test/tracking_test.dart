import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:asodya_tracking/asodya_tracking.dart';

const search = TrackingElement(
  id: 'article.search.input',
  label: 'Search articles',
  path: 'article > content > search',
);
const password = TrackingElement(
  id: 'login.password.input',
  label: 'Password',
  path: 'login > form > password',
);
AsodyaTracker tracker(http.Client client, {DateTime Function()? now}) =>
    AsodyaTracker(
      appId: 'annotations',
      baseUrl: 'https://api.example',
      buildVersion: '1.2.0',
      screens: const [
        TrackingScreen(
          name: 'article',
          route: '/article/:slug',
          label: 'Article',
        ),
      ],
      client: client,
      autoFlush: false,
      now: now,
    );
void main() {
  test(
    'sensitive values are absent from every request, including later errors',
    () async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      t.view('/article/rag?token=query-secret#fragment');
      t.event('input', password, value: 'private-password');
      t.event('input', search, value: 'RAG study');
      t.error(
        'Failure private-password Bearer bearer-value',
        StackTrace.fromString('stack private-password'),
      );
      await t.flush();
      expect(requests.length, 2);
      final all = requests.map((r) => r.body).join();
      expect(all, contains('RAG study'));
      for (final secret in [
        'private-password',
        'bearer-value',
        'query-secret',
        'fragment',
      ]) {
        expect(all, isNot(contains(secret)));
      }
      final batch = jsonDecode(requests.first.body) as Map<String, dynamic>;
      final sensitive = (batch['events'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((v) => v['element_id'] == password.id);
      expect(sensitive['value'], isNull);
      expect(batch.containsKey('user_id'), isFalse);
      expect(batch.containsKey('ip'), isFalse);
      t.dispose();
    },
  );
  test(
    'explicit sensitive fields with translated labels also drop on device',
    () async {
      final requests = <String>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r.body);
          return http.Response('{}', 202);
        }),
      );
      t.event(
        'input',
        const TrackingElement(
          id: 'checkout.card.input',
          label: 'Número',
          path: 'checkout > form > card',
        ),
        value: '4111111111111111',
        sensitive: true,
      );
      await t.flush();
      expect(requests.single, isNot(contains('4111111111111111')));
      t.dispose();
    },
  );
  test('batches stay below body limit and queued events are bounded', () async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    for (var i = 0; i < 300; i++) {
      t.event('input', search, value: 'ไทย' * 1200);
    }
    for (var i = 0; i < 100; i++) {
      await t.flush();
    }
    var count = 0;
    for (final r in requests) {
      expect(utf8.encode(r.body).length, lessThanOrEqualTo(60000));
      final events = (jsonDecode(r.body) as Map)['events'] as List;
      expect(events.length, lessThanOrEqualTo(50));
      count += events.length;
    }
    expect(count, 200);
    t.dispose();
  });
  test(
    'global error capture forwards previous handlers and restores them',
    () async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      final before = FlutterError.onError;
      var forwarded = 0;
      void previous(FlutterErrorDetails details) {
        forwarded++;
      }

      FlutterError.onError = previous;
      try {
        t.installErrorCapture();
        FlutterError.onError!(
          FlutterErrorDetails(
            exception: StateError('capture fixture'),
            stack: StackTrace.current,
          ),
        );
        await t.flush();
        expect(forwarded, 1);
        expect(requests.single.url.path, '/apps/api/v1/telemetry/errors');
        expect(requests.single.body, contains('capture fixture'));
        t.dispose();
        expect(FlutterError.onError, previous);
      } finally {
        t.dispose();
        FlutterError.onError = before;
      }
    },
  );
  test('sensitive capability paths never enter telemetry', () async {
    final bodies = <String>[];
    final t = AsodyaTracker(
      appId: 'annotations',
      baseUrl: 'https://api.example',
      buildVersion: '1',
      screens: const [
        TrackingScreen(
          name: 'instant',
          route: '/instant/:code',
          label: 'Shared room',
          sensitivePath: true,
        ),
      ],
      client: MockClient((r) async {
        bodies.add(r.body);
        return http.Response('{}', 202);
      }),
      autoFlush: false,
    );
    t.view('/instant/private-room-token');
    await t.flush();
    expect(bodies.single, isNot(contains('private-room-token')));
    expect(bodies.single, contains('/instant/:code'));
    t.dispose();
  });
  test(
    'manual reports complete only when the errors endpoint accepts them',
    () async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', requests.length == 1 ? 503 : 202);
        }),
      );
      await expectLater(t.sendError('manual report'), throwsStateError);
      await t.sendError('manual report');
      expect(requests.length, 2);
      expect(requests.last.url.path, '/apps/api/v1/telemetry/errors');
      t.dispose();
    },
  );
  test('explicit error routes are safe and do not change navigation', () async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    t.view('/article/rag');
    t.error('failure', null, route: '/callback?token=private');
    t.event('click', search);
    await t.flush();
    final error = jsonDecode(requests.last.body) as Map;
    expect(error['route'], '/callback');
    final batch = jsonDecode(requests.first.body) as Map;
    expect((batch['events'] as List).last['path'], '/article/rag');
    t.dispose();
  });
  testWidgets('custom UI locale metadata does not change child localization', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: TrackingRoot(
          tracker: t,
          locale: 'th',
          child: Builder(
            builder: (context) =>
                Text(Localizations.localeOf(context).languageCode),
          ),
        ),
      ),
    );
    t.event('click', search);
    await t.flush();
    expect((jsonDecode(requests.single.body) as Map)['locale'], 'th');
    expect(find.text('en'), findsOneWidget);
    t.dispose();
  });
  testWidgets(
    'declared semantic aliases map an existing control without editing it',
    (tester) async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TrackingRoot(
            tracker: t,
            resolveElement: (_, result) =>
                elementFromSemantics(result, {'Existing control': search}),
            child: Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () {},
                    child: const Text('Existing control'),
                  ),
                  const Text('Existing control'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Existing control').first);
      await t.flush();
      final batch = jsonDecode(requests.single.body) as Map;
      expect((batch['events'] as List).single['element_id'], search.id);
      requests.clear();
      await tester.tap(find.text('Existing control').last);
      await t.flush();
      final surface = jsonDecode(requests.single.body) as Map;
      expect(
        (surface['events'] as List).single['element_id'],
        'article.surface',
      );
      t.dispose();
    },
  );
  testWidgets(
    'nearest mapped ancestor names a nested control without layout changes',
    (tester) async {
      final requests = <http.Request>[];
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TrackingRoot(
            tracker: t,
            child: Scaffold(
              body: TrackedElement(
                element: search,
                child: TextButton(
                  onPressed: () {},
                  child: const Text('Search'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Search'));
      await t.flush();
      final events =
          (jsonDecode(requests.single.body) as Map)['events'] as List;
      expect(events.single['element_id'], search.id);
      expect(events.single['element_label'], 'Search articles');
      expect(events.single['element_path'], 'article > content > search');
      t.dispose();
    },
  );
  testWidgets(
    'controller wrapper records text changes while dropping password values',
    (tester) async {
      final requests = <http.Request>[];
      final controller = TextEditingController();
      final t = tracker(
        MockClient((r) async {
          requests.add(r);
          return http.Response('{}', 202);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: TrackingRoot(
            tracker: t,
            child: Scaffold(
              body: TrackedInput(
                element: password,
                sensitive: true,
                controller: controller,
                child: TextField(controller: controller, obscureText: true),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'secret-input');
      await t.flush();
      final all = requests.map((r) => r.body).join();
      expect(all, isNot(contains('secret-input')));
      expect(all, contains('"event_type":"input"'));
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      t.dispose();
    },
  );
  testWidgets('navigation observer tracks screen, template and path', (
    tester,
  ) async {
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', 202);
      }),
    );
    await tester.pumpWidget(
      MaterialApp(
        initialRoute: '/article/rag',
        navigatorObservers: [TrackingNavigatorObserver(t)],
        onGenerateRoute: (settings) => MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => const SizedBox(),
        ),
      ),
    );
    await t.flush();
    final events = (jsonDecode(requests.single.body) as Map)['events'] as List;
    expect(events.last['screen'], 'article');
    expect(events.last['route'], '/article/:slug');
    expect(events.last['path'], '/article/rag');
    t.dispose();
  });
  testWidgets('failed batches retry with the same session and sequence', (
    tester,
  ) async {
    var current = DateTime(2026);
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', requests.length == 1 ? 503 : 202);
      }),
      now: () => current,
    );
    t.event('click', search);
    await t.flush();
    current = current.add(const Duration(seconds: 3));
    await t.flush();
    expect(requests.length, 2);
    expect(requests[0].body, requests[1].body);
    t.dispose();
  });
  testWidgets('identity conflicts rotate UUID and retain pending events', (
    tester,
  ) async {
    var current = DateTime(2026);
    final requests = <http.Request>[];
    final t = tracker(
      MockClient((r) async {
        requests.add(r);
        return http.Response('{}', requests.length == 1 ? 409 : 202);
      }),
      now: () => current,
    );
    t.event('click', search);
    await t.flush();
    current = current.add(const Duration(seconds: 3));
    await t.flush();
    expect(requests.length, 2);
    final first = jsonDecode(requests[0].body) as Map;
    final next = jsonDecode(requests[1].body) as Map;
    expect(first['session_id'], isNot(next['session_id']));
    expect((next['events'] as List).single['element_id'], search.id);
    t.dispose();
  });
}
