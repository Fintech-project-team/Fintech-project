import 'package:flutter/material.dart';

import '../../data/auth/auth_repository.dart';
import 'auth_screens.dart';
import 'auth_services.dart';

/// 2026-10-21: 첫 가입 흐름(00-1 → 10-1 → 10-2 → 10-3 → 10-4/10-5). 자체 Navigator로 단계를 쌓는다.
/// [startAtPin]이면 세션은 있고 PIN이 없는 기기로 보고 10-4부터, [startAtIdentity]이면 무효 세션 정리 뒤
/// 신규 로그인으로 10-2부터 시작한다(09-13).
class SignupFlow extends StatefulWidget {
  /// 2026-10-21: 의존성 [services], 완료 콜백 [onCompleted], 시작 단계 [startAtPin]·[startAtIdentity]로 만든다.
  const SignupFlow({
    super.key,
    required this.services,
    required this.onCompleted,
    this.startAtPin = false,
    this.startAtIdentity = false,
  });

  final AuthServices services;
  final VoidCallback onCompleted;
  final bool startAtPin;
  final bool startAtIdentity;

  /// 2026-10-21: 흐름 상태 객체를 반환한다.
  @override
  State<SignupFlow> createState() => _SignupFlowState();
}

/// 2026-10-21: 흐름 Navigator와 같은 흐름 안의 10-2 입력을 보관한다. 흐름을 떠나면 입력도 사라진다.
class _SignupFlowState extends State<SignupFlow> {
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();
  final ValueNotifier<bool> _restarting = ValueNotifier<bool>(false);
  IdentityDraft? _draft;

  /// 2026-10-21: 처음부터 다시 하기 상태 알림을 폐기한다.
  @override
  void dispose() {
    _restarting.dispose();
    super.dispose();
  }

  /// 2026-10-21: 흐름 Navigator를 반환한다.
  NavigatorState get _navigator => _nav.currentState!;

  /// 2026-10-21: [page]를 새 화면 경로로 감싸 반환한다.
  Route<void> _route(Widget page) =>
      MaterialPageRoute<void>(builder: (_) => page);

  /// 2026-10-21: 00-1 화면을 반환한다. 이미 약관에 동의한 기기는 10-2로 바로 간다.
  Widget _start() => StartScreen(
    onStart: () async {
      final agreed = await widget.services.consentStore.hasAgreed();
      if (!mounted) return;
      _navigator.push(_route(agreed ? _identity() : _terms()));
    },
  );

  /// 2026-10-21: 10-1 화면을 반환한다. 동의하면 기기에 기록하고 10-2로 간다.
  Widget _terms() => TermsScreen(
    onBack: () => _navigator.pop(),
    onViewTerm: (title) =>
        _navigator.push(_route(TermDetailScreen(title: title))),
    onAgreed: () async {
      await widget.services.consentStore.saveAgreed();
      if (!mounted) return;
      _navigator.push(_route(_identity()));
    },
  );

  /// 2026-10-21: 10-2 화면을 반환한다. 이전 단계가 없으면 뒤로 가기는 00-1로 바꾼다.
  /// 무효 세션 뒤 신규 로그인([SignupFlow.startAtIdentity])이면 [notice]로 까닭을 알린다.
  Widget _identity({String? notice}) => IdentityScreen(
    initial: _draft,
    notice: notice,
    onBack: () => _navigator.canPop()
        ? _navigator.pop()
        : _navigator.pushReplacement(_route(_start())),
    onSubmitted: (draft) {
      _draft = draft;
      _navigator.push(_route(_code(draft)));
    },
  );

  /// 2026-10-21: [draft]로 세션 발급을 요청하는 10-3 화면을 반환한다. 성공하면 입력을 버리고 10-4로 간다.
  Widget _code(IdentityDraft draft) => CodeScreen(
    services: widget.services,
    draft: draft,
    purpose: IdentityPurpose.signup,
    onBack: () => _navigator.pop(),
    onVerified: () {
      _draft = null;
      _navigator.pushAndRemoveUntil(_route(_pin()), (_) => false);
    },
  );

  /// 2026-10-21: 10-4·10-5 화면을 반환한다. 세션 종료 중에는 PIN 입력·완료를 받지 않는다.
  Widget _pin() => PinSetupScreen(
    services: widget.services,
    busy: _restarting,
    onCompleted: () {
      if (!_restarting.value) widget.onCompleted();
    },
    onExit: _restartIdentity,
  );

  /// 2026-10-21: 10-4 뒤로 가기. 확인 후 세션 종료가 성공했거나 토큰이 이미 무효일 때만 기기 정보를 지우고 10-2로 간다.
  /// 전송 실패만으로 종료 성공 처리하지 않는다(api-contract §2). 종료 중에는 PIN 완료와 중복 요청을 막고,
  /// 기기 정보 정리는 화면이 사라져도 끝까지 수행한다. 화면 이동과 화면용 상태 알림 갱신은 화면이 있을 때만 한다.
  Future<void> _restartIdentity() async {
    if (_restarting.value) return;
    final context = _nav.currentContext!;
    if (!await confirmRestartIdentity(context) || !mounted) return;
    _restarting.value = true;
    try {
      final stored = await widget.services.sessionStore.read();
      if (stored != null) {
        final result = await widget.services.repository.endSession(
          stored.accessToken,
        );
        if (result is! AuthOk && result is! AuthSessionInvalid) {
          if (mounted) {
            ScaffoldMessenger.of(_nav.currentContext!).showSnackBar(
              const SnackBar(content: Text('연결하지 못했어요. 잠시 후 다시 시도해주세요')),
            );
          }
          return;
        }
      }
      await widget.services.sessionStore.clear();
      await widget.services.pinStore.clear();
      if (!mounted) return;
      _draft = null;
      _navigator.pushAndRemoveUntil(_route(_identity()), (_) => false);
    } finally {
      if (mounted) _restarting.value = false;
    }
  }

  /// 2026-10-21: 시스템 뒤로 가기를 흐름 Navigator로 넘기는 흐름 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return NavigatorPopHandler<void>(
      onPopWithResult: (_) => _nav.currentState?.maybePop(),
      child: HeroControllerScope.none(
        child: Navigator(
          key: _nav,
          onGenerateInitialRoutes: (_, _) => [
            _route(
              widget.startAtPin
                  ? _pin()
                  : widget.startAtIdentity
                  ? _identity(notice: '로그인 정보가 없어 본인 확인부터 다시 진행해요')
                  : _start(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-21: 잠금 해제 흐름(11-1). 5회 오류·분실이면 10-2 → 10-3(재확인) → 10-4/10-5로 PIN만 다시 만든다.
/// 새 세션을 발급하지 않는다. 복구를 취소하면 11-1로 돌아간다.
class UnlockFlow extends StatefulWidget {
  /// 2026-10-21: 의존성 [services], 해제 콜백 [onUnlocked], 복구 중 무효 세션 콜백 [onSessionInvalid]로 만든다.
  const UnlockFlow({
    super.key,
    required this.services,
    required this.onUnlocked,
    required this.onSessionInvalid,
  });

  final AuthServices services;
  final VoidCallback onUnlocked;
  final VoidCallback onSessionInvalid;

  /// 2026-10-21: 흐름 상태 객체를 반환한다.
  @override
  State<UnlockFlow> createState() => _UnlockFlowState();
}

/// 2026-10-21: 해제 흐름 Navigator와 복구용 10-2 입력을 보관한다.
class _UnlockFlowState extends State<UnlockFlow> {
  final GlobalKey<NavigatorState> _nav = GlobalKey<NavigatorState>();
  IdentityDraft? _draft;

  /// 2026-10-21: 흐름 Navigator를 반환한다.
  NavigatorState get _navigator => _nav.currentState!;

  /// 2026-10-21: [page]를 새 화면 경로로 감싸 반환한다.
  Route<void> _route(Widget page) =>
      MaterialPageRoute<void>(builder: (_) => page);

  /// 2026-10-21: 복구용 10-2 화면을 반환한다.
  Widget _identity() => IdentityScreen(
    initial: _draft,
    onBack: () => _navigator.pop(),
    onSubmitted: (draft) {
      _draft = draft;
      _navigator.push(_route(_code(draft)));
    },
  );

  /// 2026-10-21: 기존 세션을 재확인하는 10-3 화면을 반환한다. 성공하면 11-1 위에 10-4만 남긴다.
  Widget _code(IdentityDraft draft) => CodeScreen(
    services: widget.services,
    draft: draft,
    purpose: IdentityPurpose.recovery,
    onBack: () => _navigator.pop(),
    onSessionInvalid: widget.onSessionInvalid,
    onVerified: () {
      _draft = null;
      _navigator.pushAndRemoveUntil(
        _route(
          PinSetupScreen(
            services: widget.services,
            onCompleted: widget.onUnlocked,
            onExit: () => _navigator.popUntil((r) => r.isFirst),
          ),
        ),
        (r) => r.isFirst,
      );
    },
  );

  /// 2026-10-21: 11-1부터 시작하는 해제 흐름 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return NavigatorPopHandler<void>(
      onPopWithResult: (_) => _nav.currentState?.maybePop(),
      child: HeroControllerScope.none(
        child: Navigator(
          key: _nav,
          onGenerateInitialRoutes: (_, _) => [
            _route(
              PinLoginScreen(
                services: widget.services,
                onUnlocked: widget.onUnlocked,
                onRecover: () => _navigator.push(_route(_identity())),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
