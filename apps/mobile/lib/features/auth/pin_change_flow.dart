import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';
import '../../shared/design/pin_pad.dart';
import '../../shared/design/primary_button.dart';
import 'auth_screens.dart';
import 'auth_services.dart';
import 'auth_view_models.dart';

/// 2026-11-04: 비밀번호 바꾸기 첫 화면 경로 이름. 복구 화면을 쌓은 뒤 이 화면까지 한 번에 돌아올 때 쓴다.
const String pinChangeRouteName = '/pin-change';

/// 2026-11-04: 앱 비밀번호 바꾸기(#213)를 연다. 바꾸면 true, 그냥 나가면 false를 돌려준다. '비밀번호를 잊었어요'와 5번 틀린 뒤의
/// '본인 확인하기'는 잠금 해제와 같은 본인 확인 복구(10-2 → 10-3 재확인 → 10-4·10-5)로 새 비밀번호를 만든다. 복구 중 세션이
/// 이미 무효면 [onSessionInvalid]를 부른다.
Future<bool> openPinChange(
  BuildContext context, {
  required AuthServices services,
  required VoidCallback onSessionInvalid,
}) async {
  final changed = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      settings: const RouteSettings(name: pinChangeRouteName),
      builder: (_) => PinChangeScreen(
        services: services,
        onSessionInvalid: onSessionInvalid,
      ),
    ),
  );
  return changed ?? false;
}

/// 2026-11-04: 앱 비밀번호 바꾸기 화면. 지금 비밀번호 → 새 비밀번호 → 한 번 더를 한 화면에서 단계로 바꾼다. 뒤로 가기는 한 단계씩
/// 돌아가고, 지금 비밀번호 단계에서는 화면을 닫는다.
class PinChangeScreen extends StatefulWidget {
  /// 2026-11-04: 의존성 [services], 복구 중 무효 세션 콜백 [onSessionInvalid]로 만든다.
  const PinChangeScreen({
    super.key,
    required this.services,
    required this.onSessionInvalid,
  });

  final AuthServices services;
  final VoidCallback onSessionInvalid;

  /// 2026-11-04: 입력 상태 객체를 반환한다.
  @override
  State<PinChangeScreen> createState() => _PinChangeScreenState();
}

/// 2026-11-04: [PinChangeViewModel]을 소유한다.
class _PinChangeScreenState extends State<PinChangeScreen> {
  late final PinChangeViewModel _vm = PinChangeViewModel(
    widget.services.pinStore,
  );

  /// 2026-11-04: ViewModel을 폐기한다.
  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// 2026-11-04: [digit]을 넣고 저장까지 끝나면 바꿈 결과와 함께 닫는다.
  Future<void> _digit(int digit) async {
    await _vm.addDigit(digit);
    if (_vm.completed && mounted) Navigator.of(context).pop(true);
  }

  /// 2026-11-04: 한 단계 뒤로 가고, 첫 단계면 바꾸지 않고 닫는다.
  void _back() {
    if (!_vm.back()) Navigator.of(context).pop(false);
  }

  /// 2026-11-04: [page]를 새 화면 경로로 감싼다.
  Route<void> _route(Widget page) =>
      MaterialPageRoute<void>(builder: (_) => page);

  /// 2026-11-04: 이 화면까지 쌓인 복구 화면을 닫는다.
  void _backToChange() =>
      Navigator.of(context)
          .popUntil((r) => r.settings.name == pinChangeRouteName);

  /// 2026-11-04: 본인 확인 복구를 시작한다(10-2).
  void _recover() =>
      Navigator.of(context).push(_route(_identity(initial: null)));

  /// 2026-11-04: 복구용 10-2 화면을 반환한다.
  Widget _identity({required IdentityDraft? initial}) => IdentityScreen(
    initial: initial,
    onBack: () => Navigator.of(context).pop(),
    onSubmitted: (draft) => Navigator.of(context).push(_route(_code(draft))),
  );

  /// 2026-11-04: 기존 세션을 재확인하는 10-3 화면을 반환한다. 성공하면 이 화면 위에 10-4만 남긴다.
  Widget _code(IdentityDraft draft) => CodeScreen(
    services: widget.services,
    draft: draft,
    purpose: IdentityPurpose.recovery,
    onBack: () => Navigator.of(context).pop(),
    onSessionInvalid: widget.onSessionInvalid,
    onVerified: () => Navigator.of(context).pushAndRemoveUntil(
      _route(
        PinSetupScreen(
          services: widget.services,
          onCompleted: () {
            _backToChange();
            Navigator.of(context).pop(true);
          },
          onExit: _backToChange,
        ),
      ),
      (r) => r.settings.name == pinChangeRouteName,
    ),
  );

  /// 2026-11-04: 단계에 맞는 PIN 화면을 반환한다. 5번 틀렸으면 키패드 대신 '본인 확인하기'를 둔다.
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: ListenableBuilder(
        listenable: _vm,
        builder: (context, _) {
          final locked = _vm.recoveryRequired;
          final current = _vm.phase == PinChangePhase.current;
          return AuthPage(
            onBack: _back,
            body: Padding(
              padding: const EdgeInsets.only(top: PayseSpace.x5),
              child: PinPad(
                key: const ValueKey('pin-change-pad'),
                title: switch (_vm.phase) {
                  PinChangePhase.current => '지금 쓰는 비밀번호를\n입력해주세요',
                  PinChangePhase.create => '새 비밀번호 6자리를\n만들어주세요',
                  PinChangePhase.confirm => '새 비밀번호를 한 번 더\n입력해주세요',
                },
                filled: _vm.filled,
                message: _vm.error,
                isError: _vm.error != null,
                secondaryMessage: locked ? '본인 확인 후 비밀번호를 다시 만들 수 있어요' : null,
                showKeypad: !locked,
                onDigit: _digit,
                onBackspace: _vm.removeDigit,
                auxiliaryLabel: current ? '비밀번호를 잊었어요' : null,
                onAuxiliary: current ? _recover : null,
              ),
            ),
            bottom: locked
                ? PrimaryButton(label: '본인 확인하기', onPressed: _recover)
                : null,
          );
        },
      ),
    );
  }
}
