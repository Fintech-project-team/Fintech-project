import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/payse_app.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/http/api_transport.dart';

import '../data/http/fake_api_transport.dart';
import 'app_test_utils.dart';

/// 2026-11-01: 세션 읽기가 실패하는 저장소(기기 보안 저장소 오류 흉내).
/// 2026-11-02: [cleared]면 다시 읽을 수 있다(지우기 뒤 복구 확인용).
class _BrokenSessionStore extends MemorySessionStore {
  bool cleared = false;

  @override
  Future<StoredSession?> read() async =>
      cleared ? null : throw Exception('keystore');

  @override
  Future<void> clear() async => cleared = true;
}

/// 2026-11-01: 실제 서버 모드로 세션·PIN이 있는 기기를 띄우고 PIN을 넣는다. 받은 요청을 남기는 [transport]를 쓴다.
Future<void> _openServerMode(
  WidgetTester tester,
  FakeApiTransport transport,
) async {
  final sessions = MemorySessionStore();
  await sessions.save(
    const StoredSession(
      userId: 'u1',
      name: '테스트',
      sessionId: 's1',
      accessToken: 'token-1',
    ),
  );
  final pins = MemoryLocalPinStore();
  await pins.setPin(testPin);
  await tester.pumpWidget(
    PayseApp(
      server: (config: testApiConfig, transport: transport),
      sessionStore: sessions,
      pinStore: pins,
      presentationPolicy: instantPresentation(),
    ),
  );
  await tester.pumpAndSettle();
  await enterPin(tester, testPin);
}

void main() {
  testWidgets(
    'with a server address the real repositories are used in any build mode',
    (tester) async {
      final transport = FakeApiTransport(
        (_) => errorResponse(503, 'TEMPORARILY_UNAVAILABLE'),
      );
      await _openServerMode(tester, transport);

      final snapshot = transport.requests.single;
      expect(snapshot.method, 'GET');
      expect(snapshot.uri.toString(), 'https://payse.test/api/snapshot');
      expect(snapshot.headers['authorization'], 'Bearer token-1');
      expect(
        find.byKey(const ValueKey('load-error-unavailable')),
        findsOneWidget,
        reason: '서버 실패를 가짜 자료로 바꾸지 않는다',
      );
      expect(find.byKey(const ValueKey('dev-entry')), findsNothing);
    },
  );

  testWidgets(
    'a TLS or proxy rejection asks to check certificates, not the internet',
    (tester) async {
      final transport = FakeApiTransport(
        (_) => throw const ApiTransportException(ApiFailureKind.tls, 'x'),
      );
      await _openServerMode(tester, transport);
      expect(
        find.byKey(const ValueKey('load-error-secure-connection')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('load-error-offline')), findsNothing);
    },
  );

  testWidgets('a session the server rejects goes to a new sign-in', (
    tester,
  ) async {
    final transport = FakeApiTransport(
      (_) => errorResponse(401, 'SESSION_INVALID'),
    );
    await _openServerMode(tester, transport);
    expect(find.byKey(const ValueKey('signup-flow-again')), findsOneWidget);
  });

  testWidgets('a storage read failure shows a retry, not a signed-out start', (
    tester,
  ) async {
    await tester.pumpWidget(
      PayseApp(
        server: (
          config: testApiConfig,
          transport: FakeApiTransport((_) => plainResponse(500)),
        ),
        sessionStore: _BrokenSessionStore(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('storage-failed')), findsOneWidget);
    expect(find.byKey(const ValueKey('signup-flow')), findsNothing);
  });

  testWidgets(
    'clearing the login info on this device asks first, then starts over',
    (tester) async {
      final sessions = _BrokenSessionStore();
      final pins = MemoryLocalPinStore();
      await pins.setPin(testPin);
      final transport = FakeApiTransport((_) => plainResponse(500));
      await tester.pumpWidget(
        PayseApp(
          server: (config: testApiConfig, transport: transport),
          sessionStore: sessions,
          pinStore: pins,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('storage-clear')));
      await tester.pumpAndSettle();
      expect(find.textContaining('이 기기에 저장된 로그인 정보만 지워져요'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('storage-clear-confirm')));
      await tester.pumpAndSettle();
      expect(sessions.cleared, isTrue);
      expect(await pins.hasPin(), isFalse);
      expect(transport.requests, isEmpty, reason: '서버 세션을 우회하거나 끝내지 않는다');
      expect(find.byKey(const ValueKey('signup-flow')), findsOneWidget);
    },
  );
}
