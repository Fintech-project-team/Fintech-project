import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../shared/design/code_timer_field.dart';
import '../../shared/design/moon_glyph.dart';
import '../../shared/design/payse_text_field.dart';
import '../../shared/design/payse_tokens.dart';
import '../../shared/design/pin_pad.dart';
import '../../shared/design/primary_button.dart';
import '../../shared/design/selection_controls.dart';
import 'auth_services.dart';
import 'auth_view_models.dart';

/// 2026-10-21: 인증 화면 공통 틀. 위쪽 뒤로 가기, 좌우 24dp 본문, 아래 차콜 띠 버튼.
class AuthPage extends StatelessWidget {
  /// 2026-10-21: 본문 [body], 아래 버튼 [bottom], 뒤로 가기 [onBack](null이면 숨김)으로 만든다.
  const AuthPage({super.key, required this.body, this.bottom, this.onBack});

  final Widget body;
  final Widget? bottom;
  final VoidCallback? onBack;

  /// 2026-10-21: 안전 영역 안에 본문과 아래 버튼을 배치해 반환한다.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: Align(
                alignment: Alignment.centerLeft,
                child: onBack == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(left: PayseSpace.x3),
                        child: IconButton(
                          tooltip: '뒤로',
                          icon: const Icon(Icons.chevron_left, size: 28),
                          onPressed: onBack,
                        ),
                      ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PayseSpace.screenHorizontal,
                ),
                child: body,
              ),
            ),
            ?bottom,
          ],
        ),
      ),
    );
  }
}

/// 2026-10-21: 인증 화면 제목(22, 700).
class _Heading extends StatelessWidget {
  /// 2026-10-21: 제목 [title]으로 만든다.
  const _Heading(this.title);

  final String title;

  /// 2026-10-21: 제목을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: PayseSpace.x2),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 22,
            height: 31 / 22,
            fontWeight: FontWeight.w700,
            color: PayseColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// 2026-10-21: 00-1 시작. 세션이 없는 기기에서 가입·로그인 흐름을 연다.
class StartScreen extends StatelessWidget {
  /// 2026-10-21: 시작 버튼 콜백 [onStart]로 만든다.
  const StartScreen({super.key, required this.onStart});

  final VoidCallback onStart;

  /// 2026-10-21: 달 표시·PAYSE 표기와 시작 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return AuthPage(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: PayseSpace.x8),
          const MoonGlyph(size: 40),
          const SizedBox(height: PayseSpace.x5),
          Semantics(
            header: true,
            child: const Text(
              'PAYSE',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                letterSpacing: 5,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: PayseSpace.x3),
          const Text(
            '다음 월급일까지 쓸 수 있는 돈을\n한눈에 확인해요',
            style: TextStyle(
              fontSize: 17,
              height: 1.5,
              color: PayseColors.textSecondary,
            ),
          ),
        ],
      ),
      bottom: PrimaryButton(label: '시작하기', onPressed: onStart),
    );
  }
}

/// 2026-10-21: 10-1 약관 동의. 필수 항목을 모두 골라야 다음 버튼이 켜진다.
class TermsScreen extends StatefulWidget {
  /// 2026-10-21: 동의 완료 [onAgreed], 뒤로 [onBack], 약관 보기 [onViewTerm]으로 만든다.
  const TermsScreen({
    super.key,
    required this.onAgreed,
    required this.onBack,
    required this.onViewTerm,
  });

  static const List<String> requiredItems = ['서비스 이용 약관', '개인정보 처리 안내'];

  final VoidCallback onAgreed;
  final VoidCallback onBack;
  final ValueChanged<String> onViewTerm;

  /// 2026-10-21: 동의 상태를 가진 상태 객체를 반환한다.
  @override
  State<TermsScreen> createState() => _TermsScreenState();
}

/// 2026-10-21: [TermsViewModel]을 소유하고 변화를 화면에 반영한다.
class _TermsScreenState extends State<TermsScreen> {
  late final TermsViewModel _vm = TermsViewModel(TermsScreen.requiredItems);

  /// 2026-10-21: ViewModel을 폐기한다.
  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// 2026-10-21: 모두 동의 행, 필수 항목 행, 다음 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) => AuthPage(
        onBack: widget.onBack,
        body: ListView(
          children: [
            const _Heading('PAYSE를 시작하려면\n약관에 동의해주세요'),
            const SizedBox(height: PayseSpace.section),
            SelectionCheckRow(
              key: const ValueKey('terms-all'),
              label: '모두 동의',
              emphasis: true,
              selected: _vm.allAgreed,
              onChanged: _vm.setAll,
            ),
            const Divider(color: PayseColors.dividerSection, height: 13),
            for (var i = 0; i < _vm.requiredItems.length; i++)
              SelectionCheckRow(
                key: ValueKey('terms-item-$i'),
                prefix: '필수',
                label: _vm.requiredItems[i],
                selected: _vm.isAgreed(i),
                onChanged: (v) => _vm.setAgreed(i, v),
                linkLabel: '보기',
                onLink: () => widget.onViewTerm(_vm.requiredItems[i]),
              ),
          ],
        ),
        bottom: PrimaryButton(
          label: '다음',
          onPressed: _vm.allAgreed ? widget.onAgreed : null,
        ),
      ),
    );
  }
}

/// 2026-10-21: 약관 본문 자리. 본문 문안은 아직 정해지지 않았다.
class TermDetailScreen extends StatelessWidget {
  /// 2026-10-21: 약관 이름 [title]으로 만든다.
  const TermDetailScreen({super.key, required this.title});

  final String title;

  /// 2026-10-21: 제목과 본문 자리 안내를 반환한다.
  @override
  Widget build(BuildContext context) {
    return AuthPage(
      onBack: () => Navigator.of(context).pop(),
      body: ListView(
        children: [
          _Heading(title),
          const SizedBox(height: PayseSpace.x5),
          const Text(
            '약관 본문이 들어갈 자리예요.',
            style: TextStyle(fontSize: 15, color: PayseColors.textSecondary),
          ),
        ],
      ),
    );
  }
}

/// 2026-10-21: 10-2 합성 이름·휴대폰 번호. 형식 오류 문구는 입력칸 아래에 둔다.
class IdentityScreen extends StatefulWidget {
  /// 2026-10-21: 이전 입력 [initial], 통과 콜백 [onSubmitted], 뒤로 [onBack], 제목 아래 안내 [notice]로 만든다.
  const IdentityScreen({
    super.key,
    required this.onSubmitted,
    required this.onBack,
    this.initial,
    this.notice,
  });

  final IdentityDraft? initial;
  final String? notice;
  final ValueChanged<IdentityDraft> onSubmitted;
  final VoidCallback onBack;

  /// 2026-10-21: 입력 상태 객체를 반환한다.
  @override
  State<IdentityScreen> createState() => _IdentityScreenState();
}

/// 2026-10-21: [IdentityViewModel]을 소유한다.
class _IdentityScreenState extends State<IdentityScreen> {
  late final IdentityViewModel _vm = IdentityViewModel(initial: widget.initial);

  /// 2026-10-21: ViewModel을 폐기한다.
  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// 2026-10-21: 형식을 검사하고 통과하면 다음 단계로 넘긴다.
  void _submit() {
    final draft = _vm.submit();
    if (draft != null) widget.onSubmitted(draft);
  }

  /// 2026-10-21: 제목, 두 입력칸, 인증번호 받기 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) => AuthPage(
        onBack: widget.onBack,
        body: ListView(
          children: [
            const _Heading('본인 확인 정보를\n입력해주세요'),
            if (widget.notice != null) ...[
              const SizedBox(height: 6),
              Text(
                widget.notice!,
                key: const ValueKey('identity-notice'),
                style: const TextStyle(
                  fontSize: 14,
                  color: PayseColors.textSecondary,
                ),
              ),
            ],
            const SizedBox(height: PayseSpace.section),
            PayseTextField(
              key: const ValueKey('identity-name'),
              label: '이름',
              hintText: '이름 입력',
              controller: _vm.name,
              textInputAction: TextInputAction.next,
              errorText: _vm.error == IdentityError.name ? '이름을 확인해주세요.' : null,
            ),
            const SizedBox(height: PayseSpace.x5),
            PayseTextField(
              key: const ValueKey('identity-phone'),
              label: '휴대폰 번호',
              hintText: '010-0000-0000',
              controller: _vm.phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _submit(),
              errorText: _vm.error == IdentityError.phone
                  ? '휴대폰 번호를 확인해주세요.'
                  : null,
            ),
          ],
        ),
        bottom: PrimaryButton(
          label: '인증번호 받기',
          onPressed: _vm.canSubmit ? _submit : null,
        ),
      ),
    );
  }
}

/// 2026-10-21: 10-3 인증번호. 가입은 세션 발급, 복구는 기존 세션 재확인을 요청한다.
class CodeScreen extends StatefulWidget {
  /// 2026-10-21: 의존성 [services], 10-2 입력 [draft], 목적 [purpose], 성공 [onVerified], 뒤로 [onBack]으로 만든다.
  /// [onSessionInvalid]는 복구 중 저장된 토큰이 이미 무효일 때(09-13) 신규 로그인으로 넘기는 콜백이다.
  const CodeScreen({
    super.key,
    required this.services,
    required this.draft,
    required this.purpose,
    required this.onVerified,
    required this.onBack,
    this.onSessionInvalid,
  });

  final AuthServices services;
  final IdentityDraft draft;
  final IdentityPurpose purpose;
  final VoidCallback onVerified;
  final VoidCallback onBack;
  final VoidCallback? onSessionInvalid;

  /// 2026-10-21: 요청 상태 객체를 반환한다.
  @override
  State<CodeScreen> createState() => _CodeScreenState();
}

/// 2026-10-21: [CodeViewModel]을 소유한다. 화면을 떠나면 타이머와 입력을 폐기한다.
class _CodeScreenState extends State<CodeScreen> {
  late final CodeViewModel _vm = CodeViewModel(
    services: widget.services,
    draft: widget.draft,
    purpose: widget.purpose,
  );

  /// 2026-10-21: ViewModel을 폐기한다.
  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// 2026-10-21: 요청하고 성공하면 다음 단계로, 무효 세션이면 신규 로그인으로 넘긴다.
  Future<void> _submit() async {
    final ok = await _vm.submit();
    if (!mounted) return;
    if (ok) {
      widget.onVerified();
    } else if (_vm.status == CodeStatus.sessionInvalid) {
      widget.onSessionInvalid?.call();
    }
  }

  /// 2026-10-21: 요청 상태별 입력칸 아래 문구를 반환한다. 입력 중이면 null이다.
  String? _errorText() => switch (_vm.status) {
    CodeStatus.rejected => '인증번호가 맞지 않아요',
    CodeStatus.invalidInput => '입력한 정보를 다시 확인해주세요',
    CodeStatus.rateLimited =>
      '여러 번 틀려서 잠시 멈췄어요. ${_wait(_vm.retryRemaining)} 후 다시 시도해주세요',
    CodeStatus.unavailable => '연결하지 못했어요. 잠시 후 다시 시도해주세요',
    CodeStatus.editing ||
    CodeStatus.submitting ||
    CodeStatus.sessionInvalid => null,
  };

  /// 2026-10-21: 대기 시간 [d]를 'N분 N초' 형식으로 반환한다.
  static String _wait(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return [if (m > 0) '$m분', if (s > 0 || m == 0) '$s초'].join(' ');
  }

  /// 2026-10-21: 제목, 인증번호 입력과 타이머, 확인 버튼을 반환한다.
  /// 요청 중에는 뒤로 가기(버튼·시스템)를 막아 응답과 화면 단계가 어긋나지 않게 한다.
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) =>
          PopScope(canPop: _vm.status != CodeStatus.submitting, child: _page()),
    );
  }

  /// 2026-10-21: 현재 상태의 10-3 화면 본문을 반환한다.
  Widget _page() {
    final submitting = _vm.status == CodeStatus.submitting;
    return AuthPage(
      onBack: submitting ? null : widget.onBack,
      body: ListView(
        children: [
          const _Heading('인증번호 6자리를\n입력해주세요'),
          const SizedBox(height: PayseSpace.section),
          CodeTimerField(
            key: const ValueKey('code-field'),
            label: '인증번호',
            controller: _vm.code,
            remaining: _vm.remaining,
            onResend: _vm.resend,
            resendLabel: '다시 받기',
            resendHint: '인증번호가 오지 않았나요?',
            errorText: _errorText(),
            onChanged: (_) => _vm.onEdited(),
            autofocus: true,
          ),
        ],
      ),
      bottom: PrimaryButton(
        label: '확인',
        onPressed: _vm.canSubmit ? _submit : null,
      ),
    );
  }
}

/// 2026-10-21: 10-4 PIN 만들기·10-5 확인. 확인 단계에서 뒤로 가면 만들기 단계로 돌아간다.
class PinSetupScreen extends StatefulWidget {
  /// 2026-10-21: 의존성 [services], 완료 [onCompleted], 만들기 단계 뒤로 [onExit]으로 만든다.
  /// [busy]가 true인 동안(예: 처음부터 다시 하기의 세션 종료 중)은 입력과 뒤로 가기를 받지 않는다.
  const PinSetupScreen({
    super.key,
    required this.services,
    required this.onCompleted,
    required this.onExit,
    this.busy,
  });

  final AuthServices services;
  final VoidCallback onCompleted;
  final VoidCallback onExit;
  final ValueListenable<bool>? busy;

  /// 2026-10-21: PIN 입력 상태 객체를 반환한다.
  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

/// 2026-10-21: [PinSetupViewModel]을 소유한다.
class _PinSetupScreenState extends State<PinSetupScreen> {
  late final PinSetupViewModel _vm = PinSetupViewModel(
    widget.services.pinStore,
  );

  /// 2026-10-21: ViewModel을 폐기한다.
  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// 2026-10-21: [PinSetupScreen.busy]가 켜져 있으면 true를 반환한다.
  bool get _busy => widget.busy?.value ?? false;

  /// 2026-10-21: [digit]을 넣고 저장까지 끝나면 완료를 알린다. 바쁜 동안에는 무시한다.
  Future<void> _digit(int digit) async {
    if (_busy) return;
    await _vm.addDigit(digit);
    if (_vm.completed && mounted) widget.onCompleted();
  }

  /// 2026-10-21: 확인 단계면 만들기로, 만들기 단계면 [PinSetupScreen.onExit]을 부른다. 바쁜 동안에는 무시한다.
  void _back() {
    if (_busy) return;
    if (_vm.phase == PinSetupPhase.confirm) {
      _vm.backToCreate();
    } else {
      widget.onExit();
    }
  }

  /// 2026-10-21: 시스템 뒤로 가기를 가로채 [_back]으로 처리하는 PIN 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ListenableBuilder(
        listenable: _vm,
        builder: (context, _) => AuthPage(
          onBack: _back,
          body: Padding(
            padding: const EdgeInsets.only(top: PayseSpace.x5),
            child: PinPad(
              key: const ValueKey('pin-setup-pad'),
              title: _vm.phase == PinSetupPhase.create
                  ? '앱 비밀번호 6자리를\n만들어주세요'
                  : '비밀번호를 한 번 더\n입력해주세요',
              filled: _vm.filled,
              message: _vm.error,
              isError: _vm.error != null,
              onDigit: _digit,
              onBackspace: _vm.removeDigit,
            ),
          ),
        ),
      ),
    );
  }
}

/// 2026-10-21: 11-1 PIN 확인(재실행·잠금 해제). 5번 틀리면 09-12로 바뀌어 키패드를 숨긴다.
class PinLoginScreen extends StatefulWidget {
  /// 2026-10-21: 의존성 [services], 해제 [onUnlocked], 복구 시작 [onRecover]로 만든다.
  const PinLoginScreen({
    super.key,
    required this.services,
    required this.onUnlocked,
    required this.onRecover,
  });

  final AuthServices services;
  final VoidCallback onUnlocked;
  final VoidCallback onRecover;

  /// 2026-10-21: PIN 확인 상태 객체를 반환한다.
  @override
  State<PinLoginScreen> createState() => _PinLoginScreenState();
}

/// 2026-10-21: [PinLoginViewModel]을 소유한다.
class _PinLoginScreenState extends State<PinLoginScreen> {
  late final PinLoginViewModel _vm = PinLoginViewModel(
    widget.services.pinStore,
  );

  /// 2026-10-21: ViewModel을 폐기한다.
  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// 2026-10-21: [digit]을 넣고 맞으면 해제를 알린다.
  Future<void> _digit(int digit) async {
    if (await _vm.addDigit(digit) && mounted) widget.onUnlocked();
  }

  /// 2026-10-21: 상태에 맞는 PIN 화면(09-12면 키패드 없이 본인 확인 버튼)을 반환한다.
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: ListenableBuilder(
        listenable: _vm,
        builder: (context, _) {
          final locked = _vm.recoveryRequired;
          final String? message;
          if (locked) {
            message = '비밀번호를 5번 틀렸어요';
          } else if (_vm.failures > 0) {
            message =
                '비밀번호가 맞지 않아요 (${_vm.failures}/${PinLoginViewModel.maxFailures})';
          } else {
            message = null;
          }
          return AuthPage(
            body: Padding(
              padding: const EdgeInsets.only(top: PayseSpace.x6),
              child: PinPad(
                key: const ValueKey('pin-login-pad'),
                title: '비밀번호를 입력해주세요',
                filled: _vm.filled,
                message: message,
                isError: message != null,
                secondaryMessage: locked ? '본인 확인 후 비밀번호를 다시 만들 수 있어요' : null,
                showKeypad: !locked,
                onDigit: _digit,
                onBackspace: _vm.removeDigit,
                auxiliaryLabel: '비밀번호를 잊었어요',
                onAuxiliary: widget.onRecover,
              ),
            ),
            bottom: locked
                ? PrimaryButton(label: '본인 확인하기', onPressed: widget.onRecover)
                : null,
          );
        },
      ),
    );
  }
}

/// 2026-10-21: 10-4에서 뒤로 갈 때 처음부터 다시 할지 묻는다. 다시 하기를 고르면 true를 반환한다.
Future<bool> confirmRestartIdentity(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: PayseColors.background,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PayseRadius.lg),
      ),
      content: const Text(
        '본인 확인을 처음부터 다시 할까요?',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(
            foregroundColor: PayseColors.textSecondary,
          ),
          child: const Text('취소'),
        ),
        TextButton(
          key: const ValueKey('restart-identity-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: PayseColors.textPrimary),
          child: const Text('다시 하기'),
        ),
      ],
    ),
  );
  return result ?? false;
}
