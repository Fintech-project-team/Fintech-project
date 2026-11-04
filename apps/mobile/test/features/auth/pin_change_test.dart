import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/auth/fake_auth_repository.dart';
import 'package:payse/data/auth/session_cleanup.dart';
import 'package:payse/features/auth/auth_services.dart';
import 'package:payse/features/auth/auth_view_models.dart';
import 'package:payse/features/auth/pin_change_flow.dart';
import 'package:payse/shared/design/payse_theme.dart';

import '../../app/app_test_utils.dart';

/// 2026-11-04: 테스트 전용 계정. 코드는 테스트 값이다.
const _account = FakeDemoAccount(
  userId: 'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c',
  name: '테스트계정',
  phone: '01099990000',
  code: '246810',
);

/// 2026-11-04: 지금 비밀번호(테스트 값).
const _old = '135790';

/// 2026-11-04: 새 비밀번호(테스트 값).
const _new = '258036';

/// 2026-11-04: 저장된 비밀번호가 [_old]인 PIN 저장소.
Future<MemoryLocalPinStore> _pins() async {
  final pins = MemoryLocalPinStore();
  await pins.setPin(_old);
  return pins;
}

/// 2026-11-04: 로그인 세션과 비밀번호가 저장된 의존성 묶음.
class _Env {
  final repo = FakeAuthRepository(accounts: const [_account]);
  final sessions = MemorySessionStore();
  late final MemoryLocalPinStore pins;
  int sessionInvalid = 0;

  /// 2026-11-04: 세션을 만들어 저장하고 비밀번호를 둔다.
  Future<void> init() async {
    pins = await _pins();
    final created = await repo.createSession(
      DemoCredentials(
        name: _account.name,
        phone: _account.phone,
        code: _account.code,
      ),
    );
    final s = (created as AuthOk<DemoSession>).value;
    await sessions.save(
      StoredSession(
        userId: s.userId,
        name: s.name,
        sessionId: s.sessionId,
        accessToken: s.accessToken,
      ),
    );
  }

  AuthServices get services => AuthServices(
    repository: repo,
    sessionStore: sessions,
    pinStore: pins,
    consentStore: MemoryConsentStore(),
    now: FakeClock().now,
    cleanup: PendingSessionCleanup(repo),
  );
}

/// 2026-11-04: '열기' 버튼으로 비밀번호 바꾸기를 여는 화면을 띄우고, 돌려받은 결과를 담을 목록을 반환한다.
Future<List<bool>> _pump(WidgetTester tester, _Env env) async {
  final results = <bool>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPayseTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => results.add(
                await openPinChange(
                  context,
                  services: env.services,
                  onSessionInvalid: () => env.sessionInvalid++,
                ),
              ),
              child: const Text('열기'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('열기'));
  await tester.pumpAndSettle();
  return results;
}

/// 2026-11-04: 6자리를 넣고 저장소 응답까지 기다린다.
Future<void> _enter(WidgetTester tester, String pin) async {
  await tester.runAsync(() async {
    for (final c in pin.split('')) {
      await tester.tap(find.byKey(ValueKey('pin-key-$c')));
      await tester.pump();
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  await tester.pumpAndSettle();
}

/// 2026-11-04: 10-2에 이름·휴대폰 번호를 넣고 인증번호를 받는다.
Future<void> fillIdentity(
  WidgetTester tester,
  String name,
  String phone,
) async {
  for (final (key, text) in [
    ('identity-name', name),
    ('identity-phone', phone),
  ]) {
    await tester.enterText(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(TextField),
      ),
      text,
    );
  }
  await tester.pump();
  await tester.tap(find.text('인증번호 받기'));
  await tester.pumpAndSettle();
}

/// 2026-11-04: [vm]에 [pin]을 한 자리씩 넣는다.
Future<void> _type(PinChangeViewModel vm, String pin) async {
  for (final c in pin.split('')) {
    await vm.addDigit(int.parse(c));
  }
}

void main() {
  group('PinChangeViewModel', () {
    test('지금 비밀번호 → 새 비밀번호 → 한 번 더, 저장 뒤 새 비밀번호로만 풀린다', () async {
      final pins = await _pins();
      final vm = PinChangeViewModel(pins);
      await _type(vm, _old);
      expect(vm.phase, PinChangePhase.create);
      await _type(vm, _new);
      expect(vm.phase, PinChangePhase.confirm);
      await _type(vm, _new);
      expect(vm.completed, isTrue);
      expect((await pins.verify(_old)).matched, isFalse);
      expect((await pins.verify(_new)).matched, isTrue);
    });

    test('지금 비밀번호 틀림은 잠금 해제와 같은 횟수를 쓰고 5번이면 복구를 요구한다', () async {
      final pins = await _pins();
      final vm = PinChangeViewModel(pins);
      await _type(vm, '111111');
      expect(vm.error, '비밀번호가 맞지 않아요 (1/5)');
      expect(await pins.failureCount(), 1);
      for (var i = 0; i < 4; i++) {
        await _type(vm, '111111');
      }
      expect(vm.recoveryRequired, isTrue);
      expect(vm.error, '비밀번호를 5번 틀렸어요');
      await _type(vm, _old);
      expect(vm.phase, PinChangePhase.current, reason: '5번 뒤에는 맞는 비밀번호도 받지 않음');
      final reopened = PinChangeViewModel(pins);
      await Future<void>.delayed(Duration.zero);
      expect(reopened.recoveryRequired, isTrue, reason: '다시 열어도 이어짐');
    });

    test('지금 비밀번호와 같거나 쉬운 숫자는 거절, 확인이 다르면 새 비밀번호부터 다시', () async {
      final vm = PinChangeViewModel(await _pins());
      await _type(vm, _old);
      await _type(vm, _old);
      expect(vm.error, '지금 쓰는 비밀번호와 다르게 만들어주세요');
      expect(vm.phase, PinChangePhase.create);
      await _type(vm, '123456');
      expect(vm.error, '같은 숫자나 연속된 숫자는 쓸 수 없어요');
      await _type(vm, _new);
      await _type(vm, '258037');
      expect(vm.error, '비밀번호가 일치하지 않아요. 다시 입력해주세요');
      expect(vm.phase, PinChangePhase.create);
      expect(vm.completed, isFalse);
    });

    test('뒤로: 한 번 더 → 새 비밀번호 → 지금 비밀번호(다시 확인) → 닫기', () async {
      final vm = PinChangeViewModel(await _pins());
      await _type(vm, _old);
      await _type(vm, _new);
      expect(vm.back(), isTrue);
      expect(vm.phase, PinChangePhase.create);
      expect(vm.back(), isTrue);
      expect(vm.phase, PinChangePhase.current);
      expect(vm.back(), isFalse);
    });
  });

  group('화면', () {
    testWidgets('바꾸면 true를 돌려주고 닫힌다', (tester) async {
      final env = _Env();
      await tester.runAsync(env.init);
      final results = await _pump(tester, env);
      expect(find.text('지금 쓰는 비밀번호를\n입력해주세요'), findsOneWidget);
      expect(find.text('비밀번호를 잊었어요'), findsOneWidget);
      await _enter(tester, _old);
      expect(find.text('새 비밀번호 6자리를\n만들어주세요'), findsOneWidget);
      expect(find.text('비밀번호를 잊었어요'), findsNothing);
      await _enter(tester, _new);
      expect(find.text('새 비밀번호를 한 번 더\n입력해주세요'), findsOneWidget);
      await _enter(tester, _new);
      expect(results, [true]);
      expect(find.text('열기'), findsOneWidget);
    });

    testWidgets('뒤로 가기는 한 단계씩, 첫 단계면 바꾸지 않고 닫힌다', (tester) async {
      final env = _Env();
      await tester.runAsync(env.init);
      final results = await _pump(tester, env);
      await _enter(tester, _old);
      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      expect(find.text('지금 쓰는 비밀번호를\n입력해주세요'), findsOneWidget);
      await tester.tap(find.byTooltip('뒤로'));
      await tester.pumpAndSettle();
      expect(results, [false]);
      expect(
        await tester.runAsync(() => env.pins.verify(_old)),
        isA<PinCheckResult>().having((r) => r.matched, 'matched', isTrue),
      );
    });

    testWidgets('5번 틀리면 키패드 대신 본인 확인하기', (tester) async {
      final env = _Env();
      await tester.runAsync(env.init);
      await _pump(tester, env);
      for (var i = 0; i < 5; i++) {
        await _enter(tester, '111111');
      }
      expect(find.text('비밀번호를 5번 틀렸어요'), findsOneWidget);
      expect(find.text('본인 확인 후 비밀번호를 다시 만들 수 있어요'), findsOneWidget);
      expect(find.byKey(const ValueKey('pin-key-1')), findsNothing);
      expect(find.text('본인 확인하기'), findsOneWidget);
    });

    testWidgets('비밀번호를 잊었어요 → 본인 확인 → 새 비밀번호를 만들면 바꾼 것으로 닫힌다', (tester) async {
      final env = _Env();
      await tester.runAsync(env.init);
      final results = await _pump(tester, env);
      await tester.tap(find.text('비밀번호를 잊었어요'));
      await tester.pumpAndSettle();
      await fillIdentity(tester, _account.name, '010-9999-0000');
      await tester.runAsync(() async {
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('code-field')),
            matching: find.byType(TextField),
          ),
          _account.code,
        );
        await tester.pump();
        await tester.tap(find.text('확인'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(find.text('앱 비밀번호 6자리를\n만들어주세요'), findsOneWidget);
      await _enter(tester, _new);
      await _enter(tester, _new);
      expect(results, [true]);
      expect(env.sessionInvalid, 0);
      expect(
        await tester.runAsync(() => env.pins.verify(_new)),
        isA<PinCheckResult>().having((r) => r.matched, 'matched', isTrue),
      );
    });
  });
}
