import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/app/dev/fixture_debug_screen.dart';
import 'package:payse/app/payse_app.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/shared/design/primary_button.dart';

import '../../app/app_test_utils.dart';

/// 2026-10-21: 테스트 전용 계정. 코드는 테스트 값이며 서버 확정 값이 아니다.
/// 2026-10-22: userId는 금융 원본을 고르기 위해 개발 데모 alpha와 같게 둔다(이름·번호·코드는 테스트 값).
const _account = FakeDemoAccount(
  userId: 'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c',
  name: '테스트계정',
  phone: '01099990000',
  code: '246810',
);

/// 2026-10-21: 가짜 저장소 호출을 세는 감시 구현. 결과는 그대로 넘긴다.
class _SpyAuthRepository implements AuthRepository, SessionResolver {
  /// 2026-10-21: 실제로 처리할 [inner]로 만든다.
  _SpyAuthRepository(this.inner);

  final FakeAuthRepository inner;
  int createCalls = 0;
  int reverifyCalls = 0;
  int endCalls = 0;
  Completer<void>? createGate;
  Completer<void>? endGate;

  /// 2026-10-21: 발급 요청 수를 세고 [inner]에 넘긴다.
  @override
  Future<AuthOutcome<DemoSession>> createSession(DemoCredentials credentials) {
    createCalls++;
    final gate = createGate;
    if (gate == null) {
      return inner.createSession(credentials);
    }
    return gate.future.then((_) => inner.createSession(credentials));
  }

  /// 2026-10-21: 재확인 요청 수를 세고 [inner]에 넘긴다.
  @override
  Future<AuthOutcome<ReverifiedSession>> reverify(
    String accessToken,
    DemoCredentials credentials,
  ) {
    reverifyCalls++;
    return inner.reverify(accessToken, credentials);
  }

  /// 2026-10-22: 금융 조회의 세션 판정을 [inner]에 넘긴다.
  @override
  String? userIdForToken(String accessToken) =>
      inner.userIdForToken(accessToken);

  /// 2026-10-21: 종료 요청 수를 세고 [inner]에 넘긴다.
  @override
  Future<AuthOutcome<void>> endSession(String accessToken) {
    endCalls++;
    final gate = endGate;
    if (gate == null) return inner.endSession(accessToken);
    return gate.future.then((_) => inner.endSession(accessToken));
  }
}

/// 2026-10-21: 이름·번호를 넣고 인증번호 받기를 누른다.
Future<void> fillIdentity(
  WidgetTester tester,
  String name,
  String phone,
) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('identity-name')),
      matching: find.byType(TextField),
    ),
    name,
  );
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('identity-phone')),
      matching: find.byType(TextField),
    ),
    phone,
  );
  await tester.pump();
  await tester.tap(find.text('인증번호 받기'));
  await tester.pumpAndSettle();
}

/// 2026-10-21: 인증번호를 넣고 확인을 누른다.
Future<void> submitCode(WidgetTester tester, String code) async {
  await tester.enterText(
    find.descendant(
      of: find.byKey(const ValueKey('code-field')),
      matching: find.byType(TextField),
    ),
    code,
  );
  await tester.pump();
  await tester.tap(find.text('확인'));
  await tester.pumpAndSettle();
}

/// 2026-10-21: 가입 흐름에서 쓰는 앱 의존성 묶음.
class _Harness {
  final clock = FakeClock();
  final fake = FakeAuthRepository(accounts: const [_account]);
  late final spy = _SpyAuthRepository(fake);
  final sessions = MemorySessionStore();
  final pins = MemoryLocalPinStore();
  bool devTools = false;

  /// 2026-10-21: 이 의존성으로 앱을 띄운다.
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      PayseApp(
        snapshotSource: PreloadedAssetSource(),
        enableDevTools: devTools,
        authRepository: spy,
        sessionStore: sessions,
        pinStore: pins,
        now: clock.now,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 2026-10-21: 00-1 → 10-1 → 10-2 → 10-3을 통과해 10-4까지 간다.
  Future<void> reachPinSetup(WidgetTester tester) async {
    await pump(tester);
    await tester.tap(find.text('시작하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terms-all')));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
    await fillIdentity(tester, _account.name, '010-9999-0000');
    await submitCode(tester, _account.code);
  }
}

/// 2026-10-21: 현재 PIN 화면의 점 아래 문구(오류 아이콘 포함 행)를 찾는다.
Finder pinMessage(String text) => find.descendant(
  of: find.byKey(const ValueKey('pin-message')),
  matching: find.text(text),
);

void main() {
  testWidgets('10-1: next stays off until every required term is checked', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('시작하기'));
    await tester.pumpAndSettle();

    bool nextEnabled() =>
        tester
            .widget<PrimaryButton>(find.widgetWithText(PrimaryButton, '다음'))
            .onPressed !=
        null;
    expect(nextEnabled(), isFalse);

    await tester.tap(find.byKey(const ValueKey('terms-item-0')));
    await tester.pump();
    expect(nextEnabled(), isFalse);

    await tester.tap(find.byKey(const ValueKey('terms-item-1')));
    await tester.pump();
    expect(nextEnabled(), isTrue);
    expect(await h.pins.hasPin(), isFalse);
  });

  testWidgets('10-2: name error first, then phone error, under the field', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('시작하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terms-all')));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();

    await fillIdentity(tester, 'ㄱㄴ', '0101');
    expect(find.text('이름을 확인해주세요.'), findsOneWidget);
    expect(
      find.text('휴대폰 번호를 확인해주세요.'),
      findsNothing,
      reason: '이름이 틀리면 이름 문구만',
    );

    await fillIdentity(tester, _account.name, '0101');
    expect(find.text('이름을 확인해주세요.'), findsNothing);
    expect(find.text('휴대폰 번호를 확인해주세요.'), findsOneWidget);
    expect(h.spy.createCalls, 0, reason: '형식 오류는 서버로 보내지 않음');
  });

  testWidgets('signup: wrong code keeps input, right code leads to PIN setup', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('시작하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terms-all')));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
    await fillIdentity(tester, _account.name, '010 9999 0000');

    await submitCode(tester, '111111');
    expect(find.text('인증번호가 맞지 않아요'), findsOneWidget);
    expect(find.text('111111'), findsOneWidget, reason: '실패해도 입력 유지');
    expect(await h.sessions.read(), isNull);

    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('code-field')),
        matching: find.byType(TextField),
      ),
      _account.code,
    );
    await tester.pump();
    expect(find.text('인증번호가 맞지 않아요'), findsNothing, reason: '고치면 오류 문구를 지움');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('pin-setup-pad')), findsOneWidget);
    expect((await h.sessions.read())?.userId, _account.userId);
  });

  testWidgets(
    '10-2: a name with an inner space is a name error; 10-2 sends nothing',
    (tester) async {
      final h = _Harness();
      await h.pump(tester);
      await tester.tap(find.text('시작하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terms-all')));
      await tester.pump();
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();

      await fillIdentity(tester, '테스트 계정', '01099990000');
      expect(find.text('이름을 확인해주세요.'), findsOneWidget);
      expect(h.spy.createCalls, 0);
    },
  );

  testWidgets(
    'signup with edge spaces and separators stores the account name, not the input',
    (tester) async {
      final h = _Harness();
      await h.pump(tester);
      await tester.tap(find.text('시작하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terms-all')));
      await tester.pump();
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();

      await fillIdentity(tester, '  테스트계정 ', '010-9999 0000');
      await submitCode(tester, _account.code);

      expect(find.byKey(const ValueKey('pin-setup-pad')), findsOneWidget);
      final stored = await h.sessions.read();
      expect(stored?.name, _account.name);
      expect(stored?.userId, _account.userId);
    },
  );

  testWidgets('10-3 timer is display-only and restarts only after 0:00', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('시작하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terms-all')));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
    await fillIdentity(tester, _account.name, '01099990000');

    expect(find.text('3:00'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('code-resend')));
    await tester.pump();
    h.clock.advance(const Duration(seconds: 61));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('1:59'), findsOneWidget, reason: '0:00 전 다시 받기는 동작 안 함');

    h.clock.advance(const Duration(minutes: 5));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('0:00'), findsOneWidget, reason: '0:00 아래로 내려가지 않음');

    await tester.tap(find.byKey(const ValueKey('code-resend')));
    await tester.pump();
    expect(find.text('3:00'), findsOneWidget);
    expect(h.spy.createCalls, 0, reason: '다시 받기는 서버 요청 없음');
  });

  testWidgets(
    '10-4/10-5: weak PIN rejected under the dots, mismatch retried, match saves',
    (tester) async {
      final h = _Harness();
      await h.reachPinSetup(tester);

      await enterPin(tester, '111111');
      expect(pinMessage('같은 숫자나 연속된 숫자는 쓸 수 없어요'), findsOneWidget);
      expect(
        find.text('앱 비밀번호 6자리를\n만들어주세요'),
        findsOneWidget,
        reason: '같은 단계 유지',
      );
      final dotsY = tester
          .getCenter(find.byKey(const ValueKey('pin-dot-0')))
          .dy;
      final messageY = tester
          .getCenter(find.byKey(const ValueKey('pin-message')))
          .dy;
      expect(messageY, greaterThan(dotsY), reason: '오류 문구는 점 아래');

      await enterPin(tester, testPin);
      expect(find.text('비밀번호를 한 번 더\n입력해주세요'), findsOneWidget);

      await enterPin(tester, '246802');
      expect(pinMessage('비밀번호가 일치하지 않아요. 다시 입력해주세요'), findsOneWidget);
      expect(await h.pins.hasPin(), isFalse);

      await enterPin(tester, testPin);
      expect((await h.pins.verify(testPin)).matched, isTrue);
      expect(
        find.text('금융사 연결 화면이 들어갈 자리예요.'),
        findsOneWidget,
        reason: '첫 가입 후 연결 자리',
      );
    },
  );

  testWidgets('10-4 back: confirm, end the session, return to 10-2', (
    tester,
  ) async {
    final h = _Harness();
    await h.reachPinSetup(tester);

    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    expect(find.text('본인 확인을 처음부터 다시 할까요?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('restart-identity-confirm')));
    await tester.pumpAndSettle();

    expect(h.spy.endCalls, 1);
    expect(await h.sessions.read(), isNull);
    expect(find.byKey(const ValueKey('identity-name')), findsOneWidget);

    await fillIdentity(tester, _account.name, '01099990000');
    await submitCode(tester, _account.code);
    expect(
      find.byKey(const ValueKey('pin-setup-pad')),
      findsOneWidget,
      reason: '종료 후 같은 계정 재발급 가능',
    );
  });

  testWidgets(
    '09-13: recovery with a server-ended session goes to a new login at 10-2',
    (tester) async {
      final h = _Harness();
      await h.reachPinSetup(tester);
      await enterPin(tester, testPin);
      await enterPin(tester, testPin);
      await tester.tap(find.text('홈으로 가기'));
      await tester.pumpAndSettle();
      h.fake.terminateSessionOf(_account.userId);

      h.clock.advance(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pin-key-auxiliary')));
      await tester.pumpAndSettle();
      await fillIdentity(tester, _account.name, '01099990000');
      await submitCode(tester, _account.code);

      expect(
        find.text('인증번호가 맞지 않아요'),
        findsNothing,
        reason: '무효 세션을 코드 오류로 보이지 않음',
      );
      expect(find.byKey(const ValueKey('lock-overlay')), findsNothing);
      expect(
        find.byKey(const ValueKey('identity-name')),
        findsOneWidget,
        reason: '10-2 신규 로그인',
      );
      expect(find.byKey(const ValueKey('identity-notice')), findsOneWidget);
      expect(await h.sessions.read(), isNull);
      expect(await h.pins.hasPin(), isFalse);

      await fillIdentity(tester, _account.name, '01099990000');
      await submitCode(tester, _account.code);
      expect(
        find.byKey(const ValueKey('pin-setup-pad')),
        findsOneWidget,
        reason: '새 세션 발급 후 PIN 만들기',
      );
      expect(h.spy.createCalls, 2);
    },
  );

  testWidgets(
    '09-13: screens opened above home (dev snapshot screen) close on session invalid',
    (tester) async {
      final h = _Harness()..devTools = true;
      await h.reachPinSetup(tester);
      await enterPin(tester, testPin);
      await enterPin(tester, testPin);
      await tester.tap(find.text('홈으로 가기'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('내 정보').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('개발용: 더미 스냅샷 확인'));
      await tester.pumpAndSettle();
      expect(find.byType(FixtureDebugScreen), findsOneWidget);

      h.fake.terminateSessionOf(_account.userId);
      h.clock.advance(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pin-key-auxiliary')));
      await tester.pumpAndSettle();
      await fillIdentity(tester, _account.name, '01099990000');
      await submitCode(tester, _account.code);

      expect(
        find.byType(FixtureDebugScreen, skipOffstage: false),
        findsNothing,
      );
      expect(find.byType(NavigationBar, skipOffstage: false), findsNothing);
      expect(find.byKey(const ValueKey('identity-name')), findsOneWidget);
    },
  );

  testWidgets(
    '10-4: session end finishing after the app is gone still clears device state without errors',
    (tester) async {
      final h = _Harness();
      await h.reachPinSetup(tester);
      h.spy.endGate = Completer<void>();
      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('restart-identity-confirm')));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      h.spy.endGate!.complete();
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull, reason: '폐기한 알림 객체를 건드리지 않음');
      expect(await h.sessions.read(), isNull, reason: '정리는 화면과 무관하게 끝냄');
      expect(await h.pins.hasPin(), isFalse);
    },
  );

  testWidgets('⑦ a dev snapshot override is cleared when the session changes', (
    tester,
  ) async {
    final h = _Harness()..devTools = true;
    await h.reachPinSetup(tester);
    await enterPin(tester, testPin);
    await enterPin(tester, testPin);
    await tester.tap(find.text('홈으로 가기'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 정보').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('개발용: 더미 스냅샷 확인'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scenario-alpha-ready')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    h.fake.terminateSessionOf(_account.userId);
    h.clock.advance(const Duration(minutes: 10));
    await tester.pump(const Duration(minutes: 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pin-key-auxiliary')));
    await tester.pumpAndSettle();
    await fillIdentity(tester, _account.name, '01099990000');
    await submitCode(tester, _account.code);
    await fillIdentity(tester, _account.name, '01099990000');
    await submitCode(tester, _account.code);
    await enterPin(tester, testPin);
    await enterPin(tester, testPin);

    expect(
      find.text('금융사 연결 화면이 들어갈 자리예요.'),
      findsOneWidget,
      reason: '새 세션은 개발용 덮어쓰기(연결된 alpha-ready) 대신 사용자 저장 상태(연결 전)를 따름',
    );
  });

  testWidgets('10-3: leaving is blocked while the session request is pending', (
    tester,
  ) async {
    final h = _Harness();
    await h.pump(tester);
    await tester.tap(find.text('시작하기'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terms-all')));
    await tester.pump();
    await tester.tap(find.text('다음'));
    await tester.pumpAndSettle();
    await fillIdentity(tester, _account.name, '01099990000');

    h.spy.createGate = Completer<void>();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('code-field')),
        matching: find.byType(TextField),
      ),
      _account.code,
    );
    await tester.pump();
    await tester.tap(find.text('확인'));
    await tester.pump();

    expect(find.byTooltip('뒤로'), findsNothing, reason: '요청 중 뒤로 버튼 숨김');
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(
      find.byKey(const ValueKey('code-field')),
      findsOneWidget,
      reason: '시스템 뒤로도 막힘',
    );

    h.spy.createGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pin-setup-pad')), findsOneWidget);
    expect(
      (await h.sessions.read())?.userId,
      _account.userId,
      reason: '저장과 화면 단계 일치',
    );
  });

  testWidgets('10-4: PIN input is locked while ending the session', (
    tester,
  ) async {
    final h = _Harness();
    await h.reachPinSetup(tester);

    h.spy.endGate = Completer<void>();
    await tester.tap(find.byTooltip('뒤로'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('restart-identity-confirm')));
    await tester.pump();

    await enterPin(tester, testPin);
    await enterPin(tester, testPin);
    expect(await h.pins.hasPin(), isFalse, reason: '종료 중 PIN 설정 안 됨');
    expect(
      find.text('금융사 연결 화면이 들어갈 자리예요.'),
      findsNothing,
      reason: '활성 화면으로 가지 않음',
    );

    h.spy.endGate!.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('identity-name')), findsOneWidget);
    expect(await h.sessions.read(), isNull);
    expect(h.spy.endCalls, 1);
  });

  testWidgets(
    'release default (no server): 10-3 shows a connection error and stays',
    (tester) async {
      final sessions = MemorySessionStore();
      await tester.pumpWidget(
        PayseApp(
          enableDevTools: false,
          authRepository: const UnavailableAuthRepository(),
          sessionStore: sessions,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('시작하기'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('terms-all')));
      await tester.pump();
      await tester.tap(find.text('다음'));
      await tester.pumpAndSettle();
      await fillIdentity(tester, _account.name, '01099990000');
      await submitCode(tester, '000001');

      expect(find.text('연결하지 못했어요. 잠시 후 다시 시도해주세요'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('code-field')),
        findsOneWidget,
        reason: '10-3에 머묾',
      );
      expect(await sessions.read(), isNull);
    },
  );

  testWidgets(
    'PIN failure count survives an app restart; 5 failures stay at 09-12',
    (tester) async {
      final (sessions, pins, auth) = await signedInStores();

      /// 2026-10-21: 같은 기기 저장소로 앱을 새로 띄워 재시작을 흉내 낸다.
      Future<void> launch() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          PayseApp(
            snapshotSource: PreloadedAssetSource(),
            enableDevTools: false,
            authRepository: auth,
            sessionStore: sessions,
            pinStore: pins,
          ),
        );
        await tester.pumpAndSettle();
      }

      await launch();
      for (var i = 0; i < 4; i++) {
        await enterPin(tester, '246802');
      }
      expect(pinMessage('비밀번호가 맞지 않아요 (4/5)'), findsOneWidget);

      await launch();
      expect(
        pinMessage('비밀번호가 맞지 않아요 (4/5)'),
        findsOneWidget,
        reason: '재시작해도 4회 유지',
      );
      await enterPin(tester, '246802');
      expect(find.byKey(const ValueKey('pin-keypad')), findsNothing);

      await launch();
      expect(
        pinMessage('비밀번호를 5번 틀렸어요'),
        findsOneWidget,
        reason: '재시작해도 09-12 유지',
      );
      expect(find.byKey(const ValueKey('pin-keypad')), findsNothing);
      expect(find.text('본인 확인하기'), findsOneWidget);
      expect(
        (await pins.verify(testPin)).matched,
        isFalse,
        reason: '복구 전에는 맞는 PIN도 거절',
      );
    },
  );

  testWidgets('small phone (320x568): auth screens render without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = _Harness();
    await h.reachPinSetup(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('pin-key-0')), findsOneWidget);
  });

  testWidgets(
    '11-1: 5 wrong PINs hide the keypad; recovery reverifies without a new session',
    (tester) async {
      final h = _Harness();
      await h.reachPinSetup(tester);
      await enterPin(tester, testPin);
      await enterPin(tester, testPin);
      await tester.tap(find.text('홈으로 가기'));
      await tester.pumpAndSettle();

      h.clock.advance(const Duration(minutes: 10));
      await tester.pump(const Duration(minutes: 10));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('lock-overlay')), findsOneWidget);

      for (var i = 1; i <= 4; i++) {
        await enterPin(tester, '246802');
        expect(pinMessage('비밀번호가 맞지 않아요 ($i/5)'), findsOneWidget);
      }
      await enterPin(tester, '246802');
      expect(pinMessage('비밀번호를 5번 틀렸어요'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pin-secondary-message')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pin-keypad')),
        findsNothing,
        reason: '09-12는 키패드 숨김',
      );

      final sessionBefore = await h.sessions.read();
      await tester.tap(find.text('본인 확인하기'));
      await tester.pumpAndSettle();
      await fillIdentity(tester, _account.name, '01099990000');
      await submitCode(tester, _account.code);

      expect(h.spy.reverifyCalls, 1);
      expect(h.spy.createCalls, 1, reason: '복구는 새 세션을 발급하지 않음');
      expect(
        (await h.sessions.read())?.accessToken,
        sessionBefore?.accessToken,
      );

      await enterPin(tester, '246813');
      await enterPin(tester, '246813');
      expect(find.byKey(const ValueKey('lock-overlay')), findsNothing);
      expect(
        await h.pins.failureCount(),
        0,
        reason: '복구로 PIN을 새로 만들면 실패 횟수 초기화',
      );
      expect((await h.pins.verify('246813')).matched, isTrue);
      expect(find.byType(NavigationBar), findsOneWidget);
    },
  );
}
