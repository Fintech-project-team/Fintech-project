import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/payse_app.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/http/api_transport.dart';

import 'app_test_utils.dart';

/// 2026-11-02: 세션 종료만 [endResult]로 바꾸고 나머지는 가짜 인증 저장소에 맡기는 저장소. 금융 가짜 서버가 세션을 판정하도록
/// [SessionResolver]도 위임한다.
class _EndSessionOverride implements AuthRepository, SessionResolver {
  _EndSessionOverride(this.inner, this.endResult);

  final FakeAuthRepository inner;
  AuthOutcome<void>? endResult;
  int endCalls = 0;

  @override
  Future<AuthOutcome<DemoSession>> createSession(DemoCredentials c) =>
      inner.createSession(c);

  @override
  Future<AuthOutcome<ReverifiedSession>> reverify(
    String token,
    DemoCredentials c,
  ) => inner.reverify(token, c);

  @override
  Future<AuthOutcome<void>> endSession(String token) async {
    endCalls++;
    return endResult ?? await inner.endSession(token);
  }

  @override
  String? userIdForToken(String token) => inner.userIdForToken(token);
}

/// 2026-11-02: 세션·PIN이 있는 기기로 홈까지 연 뒤 내 정보 탭에서 로그아웃 확인 창의 '네'를 누른다.
Future<(MemorySessionStore, MemoryLocalPinStore, _EndSessionOverride)>
_logoutFromHome(WidgetTester tester, AuthOutcome<void>? endResult) async {
  final (sessions, pins, auth) = await signedInStores();
  final repo = _EndSessionOverride(auth, endResult);
  await tester.pumpWidget(
    PayseApp(
      snapshotSource: PreloadedAssetSource(),
      enableDevTools: false,
      authRepository: repo,
      sessionStore: sessions,
      pinStore: pins,
      presentationPolicy: instantPresentation(),
    ),
  );
  await tester.pumpAndSettle();
  await enterPin(tester, testPin);
  await connectAndChooseAccounts(tester);
  await tester.tap(find.text('내 정보').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('logout-button')));
  await tester.pumpAndSettle();
  expect(find.text('로그아웃 하시겠습니까?'), findsOneWidget);
  await tester.tap(find.byKey(const ValueKey('logout-confirm')));
  await tester.pumpAndSettle();
  return (sessions, pins, repo);
}

void main() {
  testWidgets(
    'logout ends the server session, then clears the session and PIN',
    (tester) async {
      final (sessions, pins, repo) = await _logoutFromHome(tester, null);
      expect(repo.endCalls, 1);
      expect(await sessions.read(), isNull);
      expect(await pins.hasPin(), isFalse);
      expect(find.byKey(const ValueKey('signup-flow')), findsOneWidget);
    },
  );

  testWidgets('a failed logout keeps the token and says why', (tester) async {
    final (sessions, pins, _) = await _logoutFromHome(
      tester,
      AuthNetworkFailure<void>(
        const ApiTransportException(ApiFailureKind.tls, 'handshake'),
      ),
    );
    expect(await sessions.read(), isNotNull, reason: '종료 확인 전에는 토큰 유지');
    expect(await pins.hasPin(), isTrue);
    expect(find.textContaining('보안 연결을 확인하지 못했어요'), findsOneWidget);
    expect(find.byKey(const ValueKey('logout-button')), findsOneWidget);
  });

  testWidgets('no on the confirm dialog keeps everything', (tester) async {
    final (sessions, pins, auth) = await signedInStores();
    await tester.pumpWidget(
      PayseApp(
        snapshotSource: PreloadedAssetSource(),
        enableDevTools: false,
        authRepository: auth,
        sessionStore: sessions,
        pinStore: pins,
        presentationPolicy: instantPresentation(),
      ),
    );
    await tester.pumpAndSettle();
    await enterPin(tester, testPin);
    await connectAndChooseAccounts(tester);
    await tester.tap(find.text('내 정보').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('logout-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('아니오'));
    await tester.pumpAndSettle();
    expect(await sessions.read(), isNotNull);
    expect(find.byKey(const ValueKey('logout-button')), findsOneWidget);
  });
}
