import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/auth/auth_repository.dart';
import 'package:payse/data/auth/credential_stores.dart';
import 'package:payse/data/auth/session_cleanup.dart';
import 'package:payse/features/auth/auth_services.dart';
import 'package:payse/features/auth/auth_view_models.dart';

import '../../app/app_test_utils.dart';

/// 2026-10-21: 결과를 미리 정해 두거나 응답을 늦출 수 있는 테스트용 인증 저장소.
class _ScriptedAuthRepository implements AuthRepository {
  AuthOutcome<DemoSession> createResult = const AuthRejected();
  AuthOutcome<ReverifiedSession> reverifyResult = const AuthRejected();
  Completer<void>? createGate;
  int createCalls = 0;
  int reverifyCalls = 0;
  final List<String> endedTokens = [];
  final List<AuthOutcome<void>> endResults = [];

  /// 2026-10-21: 호출 수를 세고 [createGate]가 있으면 열릴 때까지 기다린 뒤 정해 둔 결과를 반환한다.
  @override
  Future<AuthOutcome<DemoSession>> createSession(
    DemoCredentials credentials, {
    required String installationId,
  }) async {
    createCalls++;
    await createGate?.future;
    return createResult;
  }

  /// 2026-10-21: 호출 수를 세고 정해 둔 재확인 결과를 반환한다.
  @override
  Future<AuthOutcome<ReverifiedSession>> reverify(
    String accessToken,
    DemoCredentials credentials,
  ) async {
    reverifyCalls++;
    return reverifyResult;
  }

  /// 2026-10-21: 종료 요청한 토큰을 기록하고, [endResults]에 넣어 둔 결과를 차례로(없으면 성공) 반환한다.
  @override
  Future<AuthOutcome<void>> endSession(String accessToken) async {
    endedTokens.add(accessToken);
    return endResults.isEmpty ? const AuthOk(null) : endResults.removeAt(0);
  }
}

const _draft = IdentityDraft(name: 'PAYSE 합성 test', phone: '01099990000');

/// 2026-10-21: 테스트용 의존성 묶음.
class _Env {
  final clock = FakeClock();
  final repo = _ScriptedAuthRepository();
  final sessions = MemorySessionStore();
  final pins = MemoryLocalPinStore();
  late final cleanup = PendingSessionCleanup(repo);

  /// 2026-10-21: 이 의존성으로 [purpose] 10-3 ViewModel을 만든다.
  CodeViewModel vm(IdentityPurpose purpose) => CodeViewModel(
    services: AuthServices(
      repository: repo,
      sessionStore: sessions,
      pinStore: pins,
      consentStore: MemoryConsentStore(),
      installationId: '3f2c9a4e-1b7d-4c2e-9a10-7f6e5d4c3b2a',
      now: clock.now,
      cleanup: cleanup,
    ),
    draft: _draft,
    purpose: purpose,
  );
}

final _session = DemoSession(
  userId: 'u',
  sessionId: 's',
  accessToken: 'tok',
  issuedAt: DateTime(2026, 10, 21, 9),
);

void main() {
  testWidgets('each failure outcome maps to its own status and keeps input', (
    tester,
  ) async {
    final env = _Env();
    final vm = env.vm(IdentityPurpose.signup);
    vm.code.text = '123456';

    for (final (outcome, status) in [
      (const AuthRejected<DemoSession>(), CodeStatus.rejected),
      (const AuthInvalidInput<DemoSession>(), CodeStatus.invalidInput),
      (const AuthUnavailable<DemoSession>(), CodeStatus.unavailable),
      (AuthNetworkFailure<DemoSession>(Exception('x')), CodeStatus.unavailable),
    ]) {
      env.repo.createResult = outcome;
      expect(await vm.submit(), isFalse);
      expect(vm.status, status, reason: '$outcome');
      expect(vm.code.text, '123456', reason: '실패해도 입력 유지');
    }
    expect(await env.sessions.read(), isNull);
    vm.dispose();
  });

  testWidgets('429: no request until Retry-After passes, even after editing', (
    tester,
  ) async {
    final env = _Env();
    final vm = env.vm(IdentityPurpose.signup);
    env.repo.createResult = const AuthRateLimited(Duration(seconds: 90));
    vm.code.text = '123456';

    await vm.submit();
    expect(vm.status, CodeStatus.rateLimited);
    expect(vm.canSubmit, isFalse);

    vm.code.text = '654321';
    vm.onEdited();
    expect(vm.status, CodeStatus.rateLimited, reason: '입력을 고쳐도 제한 안내 유지');
    expect(await vm.submit(), isFalse);
    expect(env.repo.createCalls, 1, reason: '대기 중 재요청 없음');

    env.clock.advance(const Duration(seconds: 89));
    await tester.pump(const Duration(seconds: 1));
    expect(vm.retryRemaining, const Duration(seconds: 1));
    expect(vm.canSubmit, isFalse);

    env.clock.advance(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(vm.status, CodeStatus.editing, reason: '대기가 끝나면 안내를 지움');
    expect(vm.canSubmit, isTrue);
    vm.dispose();
  });

  testWidgets(
    'resend turns on when the display reaches 0:00, without other input',
    (tester) async {
      final env = _Env();
      final vm = env.vm(IdentityPurpose.signup);
      var notified = 0;
      vm.addListener(() => notified++);

      env.clock.advance(const Duration(milliseconds: 179200));
      await tester.pump(const Duration(seconds: 1));
      expect(vm.remaining.inSeconds, 0, reason: '0.8초 남음 = 표시 0:00');
      expect(notified, greaterThan(0), reason: '0:00이 된 순간 화면 갱신');

      vm.resend();
      expect(
        vm.remaining,
        CodeViewModel.displayTimer,
        reason: '표시 0:00이면 다시 받기 동작',
      );
      vm.dispose();
    },
  );

  testWidgets('recovery with an invalid stored token clears device state', (
    tester,
  ) async {
    final env = _Env();
    await env.sessions.save(
      const StoredSession(userId: 'u', sessionId: 's', accessToken: 'tok'),
    );
    await env.pins.setPin(testPin);
    env.repo.reverifyResult = const AuthSessionInvalid();
    final vm = env.vm(IdentityPurpose.recovery);
    vm.code.text = '123456';

    expect(await vm.submit(), isFalse);
    expect(vm.status, CodeStatus.sessionInvalid);
    expect(await env.sessions.read(), isNull);
    expect(await env.pins.hasPin(), isFalse);
    expect(vm.canSubmit, isFalse);
    vm.dispose();
  });

  testWidgets('recovery without any stored token is also session invalid', (
    tester,
  ) async {
    final env = _Env();
    final vm = env.vm(IdentityPurpose.recovery);
    vm.code.text = '123456';

    await vm.submit();
    expect(vm.status, CodeStatus.sessionInvalid);
    expect(env.repo.reverifyCalls, 0);
    vm.dispose();
  });

  testWidgets('a late signup success after leaving is ended, not saved', (
    tester,
  ) async {
    final env = _Env();
    env.repo.createGate = Completer<void>();
    env.repo.createResult = AuthOk(_session);
    final vm = env.vm(IdentityPurpose.signup);
    vm.code.text = '123456';

    final pending = vm.submit();
    vm.dispose();
    env.repo.createGate!.complete();
    expect(await pending, isFalse);

    expect(await env.sessions.read(), isNull, reason: '떠난 뒤 성공은 저장하지 않음');
    expect(env.repo.endedTokens, ['tok'], reason: '서버 활성 세션을 남기지 않음');
  });

  testWidgets(
    'a late success whose session end fails is kept and ended before the next signup',
    (tester) async {
      final env = _Env();
      env.repo.createGate = Completer<void>();
      env.repo.createResult = AuthOk(_session);
      env.repo.endResults.add(const AuthUnavailable());
      final first = env.vm(IdentityPurpose.signup);
      first.code.text = '123456';

      final pending = first.submit();
      first.dispose();
      env.repo.createGate!.complete();
      await pending;
      expect(env.cleanup.pendingCount, 1, reason: '종료 실패 시 토큰을 버리지 않음');
      expect(await env.sessions.read(), isNull);

      env.repo.createGate = null;
      env.repo.createResult = const AuthRejected();
      final second = env.vm(IdentityPurpose.signup);
      second.code.text = '123456';
      await second.submit();
      expect(env.repo.endedTokens, ['tok', 'tok'], reason: '다음 발급 전에 다시 종료');
      expect(env.cleanup.pendingCount, 0);
      second.dispose();
    },
  );
}
