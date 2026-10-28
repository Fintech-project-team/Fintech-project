import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_text_field.dart';
import '../../shared/design/payse_tokens.dart';
import '../../shared/design/primary_button.dart';
import '../../shared/design/selection_controls.dart';
import '../overview/home_screen.dart' show NoticeBand;
import 'connection_flow_controller.dart';
import 'connection_page.dart';
import 'connection_review.dart';
import 'salary_settings_controller.dart';

/// 2026-10-28: 월급 설정(03-7, #28 4b-1). 01-2 월급 묶음의 '확인·수정'에서 연다. 월급일·예상 금액·계좌를 고쳐
/// 저장하며, 저장 값과 다를 때만 저장 버튼이 켜지고 나갈 때 확인 창을 띄운다. 입금 거래 고르기·확인은 4b-2다.
class SalarySettingsScreen extends StatefulWidget {
  /// 2026-10-28: 상태 [controller], 새 Snapshot을 받았을 때 [onSnapshot](저장 성공·최신 정보 불러오기),
  /// 01-2로 돌아가기 [onBack]으로 만든다.
  const SalarySettingsScreen({
    super.key,
    required this.controller,
    required this.onSnapshot,
    required this.onBack,
  });

  final SalarySettingsController controller;
  final ValueChanged<FinancialSnapshot> onSnapshot;
  final VoidCallback onBack;

  /// 2026-10-28: 화면 상태 객체를 반환한다.
  @override
  State<SalarySettingsScreen> createState() => _SalarySettingsScreenState();
}

/// 2026-10-28: 금액 입력칸과 컨트롤러 변화를 화면에 잇는다.
class _SalarySettingsScreenState extends State<SalarySettingsScreen> {
  late final TextEditingController _amount = TextEditingController(
    text: groupDigits(widget.controller.amountDigits),
  );

  SalarySettingsController get _c => widget.controller;

  /// 2026-10-28: 컨트롤러 변화를 듣는다.
  @override
  void initState() {
    super.initState();
    _c.addListener(_refresh);
  }

  /// 2026-10-28: 듣기를 멈추고 입력칸을 폐기한다.
  @override
  void dispose() {
    _c.removeListener(_refresh);
    _amount.dispose();
    super.dispose();
  }

  /// 2026-10-28: 다시 그린다.
  void _refresh() {
    if (mounted) setState(() {});
  }

  /// 2026-10-28: 저장한다. 성공하면 입력칸을 저장 값으로 맞추고 01-2에 새 Snapshot을 넘기며 저장했다고 알린다.
  /// 알림은 아래 버튼을 가리지 않게 버튼 위에 띄운다.
  Future<void> _save() async {
    final next = await _c.submit();
    if (!mounted || next == null) return;
    _amount.text = groupDigits(_c.amountDigits);
    widget.onSnapshot(next);
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('월급 설정을 저장했어요.'),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(
            PayseSpace.x4,
            0,
            PayseSpace.x4,
            PayseSize.primaryBandHeight + PayseSpace.x3,
          ),
        ),
      );
  }

  /// 2026-10-28: 최신 정보를 불러온다. 성공하면 입력칸을 컨트롤러 값으로 맞추고 01-2에도 새 Snapshot을 넘긴다.
  Future<void> _reload() async {
    final next = await _c.reloadLatest();
    if (!mounted || next == null) return;
    _amount.text = groupDigits(_c.amountDigits);
    widget.onSnapshot(next);
  }

  /// 2026-10-28: 01-2로 돌아간다. 저장 값과 다르면 확인 창을 띄우고 '저장 안 하고 나가기'일 때만 나간다. 진행 중에는 나가지 않는다.
  /// 저장 알림이 01-2 버튼을 가리지 않게 나가기 전에 닫는다.
  Future<void> _leave() async {
    if (_c.busy) return;
    if (_c.dirty) {
      final stay = await showConnectionConfirm(
        context,
        key: const ValueKey('salary-leave-dialog'),
        title: '저장하지 않은 변경이 있어요',
        body: '나가면 바꾼 월급 설정이 저장되지 않아요.',
        secondaryLabel: '저장 안 하고 나가기',
        secondaryKey: const ValueKey('salary-leave'),
        primaryLabel: '계속 수정하기',
        primaryKey: const ValueKey('salary-keep-editing'),
      );
      if (stay != false || !mounted) return;
    }
    ScaffoldMessenger.maybeOf(context)?.hideCurrentSnackBar();
    widget.onBack();
  }

  /// 2026-10-28: 월급일 선택을 열고 고른 날짜를 반영한다.
  /// 2026-10-28: 바텀시트 달력형(1~31일)으로 바꿨다(혜연 요청).
  Future<void> _pickDay() async {
    final day = await _sheet<int>(_DaySheet(selected: _c.day));
    if (day != null) _c.setDay(day);
  }

  /// 2026-10-28: [content]를 흰 면·위 반경 16·덮개 50% 바텀시트로 열고 고른 값을 반환한다. 높이는 화면의 85%까지이며
  /// 상태 표시줄을 가리지 않는다.
  Future<T?> _sheet<T>(Widget content) => showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.85,
    ),
    backgroundColor: PayseColors.background,
    barrierColor: const Color(0x80242629),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(PayseRadius.lg)),
    ),
    builder: (_) => content,
  );

  /// 2026-10-28: 월급 계좌 선택을 열고 고른 계좌를 반영한다.
  /// 2026-10-28: 월급일과 같은 바텀시트로 바꿨다(혜연 요청).
  Future<void> _pickAccount() async {
    final id = await _sheet<String>(
      _AccountSheet(
        snapshot: _c.snapshot,
        accounts: _c.selectableAccounts,
        selected: _c.accountId,
      ),
    );
    if (id != null) _c.setAccount(id);
  }

  /// 2026-10-28: 입력 중인 계좌의 이름을 반환한다. 숨겨졌으면 볼 수 없다고, 없으면 null이다.
  String? _accountText() {
    if (_c.accountHidden) return '월급 계좌 정보를 볼 수 없어요';
    final id = _c.accountId;
    if (id == null) return null;
    final a = accountById(_c.snapshot, id);
    return a == null ? '계좌 정보 없음' : accountLabel(_c.snapshot, a);
  }

  /// 2026-10-28: 저장·불러오기 실패 안내 띠를 반환한다. 실패가 없으면 null이다.
  Widget? _band() {
    if (_c.reload == ReloadStatus.failed) {
      return NoticeBand(
        key: const ValueKey('salary-band-reload-failed'),
        title: '최신 정보를 불러오지 못했어요',
        body: '입력한 내용은 그대로 남아 있어요. 다시 불러와 주세요.',
        actionLabel: '다시 불러오기',
        actionKey: const ValueKey('salary-reload'),
        onAction: _reload,
      );
    }
    return switch (_c.save) {
      SaveFailed(failure: ConnectionSaveFailure.retryable) => const NoticeBand(
        key: ValueKey('salary-band-retryable'),
        title: '월급 설정을 저장하지 못했어요',
        body: '입력한 내용은 그대로 남아 있어요. 잠시 후 다시 저장해 주세요.',
      ),
      SaveFailed(failure: ConnectionSaveFailure.outdated) => NoticeBand(
        key: const ValueKey('salary-band-outdated'),
        title: '저장 전에 정보가 바뀌었어요',
        body: '최신 정보를 불러온 뒤 다시 저장해 주세요. 입력한 내용은 그대로 남아 있어요.',
        actionLabel: _c.reload == ReloadStatus.loading
            ? '불러오는 중'
            : '최신 정보 불러오기',
        actionKey: const ValueKey('salary-reload'),
        onAction: _c.reload == ReloadStatus.loading ? null : _reload,
      ),
      SaveFailed(failure: ConnectionSaveFailure.rejected) => const NoticeBand(
        key: ValueKey('salary-band-rejected'),
        title: '월급 설정을 저장할 수 없어요',
        body: '입력한 내용을 다시 확인해 주세요.',
      ),
      _ => null,
    };
  }

  /// 2026-10-28: 제목 → 안내 띠 → '월급 설정' 묶음(월급일·예상 금액·계좌) → 저장 버튼 → 하단 '확인 화면으로 돌아가기'.
  @override
  Widget build(BuildContext context) {
    final busy = _c.busy;
    final band = _band();
    const field = EdgeInsets.fromLTRB(
      PayseSpace.screenHorizontal,
      PayseSpace.x5,
      PayseSpace.screenHorizontal,
      0,
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: ConnectionPage(
        onBack: busy ? null : _leave,
        body: ListView(
          children: [
            const ConnectionHeading(
              '월급 정보를\n확인해 주세요',
              subtitle: '월급 설정을 확인하고 필요하면 수정해 주세요.',
            ),
            if (band != null)
              Padding(
                padding: const EdgeInsets.only(top: PayseSpace.x2),
                child: band,
              ),
            const _SettingsSection('월급 설정'),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PayseSpace.screenHorizontal,
                PayseSpace.x4,
                PayseSpace.screenHorizontal,
                0,
              ),
              child: _PickerField(
                key: const ValueKey('salary-day'),
                label: '월급일',
                value: _c.day == null ? null : '매월 ${_c.day}일',
                placeholder: '월급일 선택',
                helper: '해당 날짜가 없는 달에는 말일로 계산해요.',
                onTap: busy ? null : _pickDay,
              ),
            ),
            Padding(
              padding: field,
              child: PayseTextField(
                key: const ValueKey('salary-amount'),
                label: '예상 월급 금액',
                controller: _amount,
                enabled: !busy,
                hintText: '금액 입력',
                keyboardType: TextInputType.number,
                inputFormatters: const [GroupedDigitsFormatter()],
                textInputAction: TextInputAction.done,
                onChanged: (text) => _c.setAmount(text.replaceAll(',', '')),
                errorText: _c.amountMissing ? '예상 월급 금액을 입력해 주세요.' : null,
                helperText: '앞으로 받을 것으로 예상하는 금액이며, 현재 잔액에는 더하지 않아요.',
                trailing: const Padding(
                  padding: EdgeInsets.only(left: PayseSpace.x1),
                  child: Text(
                    '원',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: field,
              child: _PickerField(
                key: const ValueKey('salary-account'),
                label: '월급 계좌',
                value: _accountText(),
                muted: _c.accountHidden,
                placeholder: '계좌 선택',
                helper: '계산에 쓰기로 고른 계좌 중에서 고를 수 있어요.',
                onTap: busy ? null : _pickAccount,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PayseSpace.screenHorizontal,
                PayseSpace.x6,
                PayseSpace.screenHorizontal,
                PayseSpace.x6,
              ),
              child: _SaveButton(
                label: _c.save is SaveInProgress ? '저장하는 중' : '월급 설정 저장하기',
                onPressed: _c.canSave ? _save : null,
              ),
            ),
          ],
        ),
        bottom: PrimaryButton(
          key: const ValueKey('salary-done'),
          label: '확인 화면으로 돌아가기',
          back: true,
          onPressed: busy ? null : _leave,
        ),
      ),
    );
  }
}

/// 2026-10-28: 숫자를 세 자리마다 쉼표로 묶어 반환한다(표시 형식만, 계산하지 않음).
String groupDigits(String digits) {
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return b.toString();
}

/// 2026-10-28: 금액 입력 형식. 숫자만 13자리까지 받아 쉼표로 묶고 앞의 0을 지운다. 커서는 끝에 둔다.
class GroupedDigitsFormatter extends TextInputFormatter {
  /// 2026-10-28: 상태 없는 형식기를 만든다.
  const GroupedDigitsFormatter();

  static const int maxDigits = 13;

  /// 2026-10-28: 새 입력 [newValue]를 숫자만 남겨 쉼표로 묶은 값으로 바꾼다. 13자리를 넘으면 이전 값 [oldValue]를 유지한다.
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp(r'[^0-9]'), '');
    digits = digits.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
    if (digits.length > maxDigits) return oldValue;
    final text = groupDigits(digits);
    return TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }
}

/// 2026-10-28: 월급 설정 묶음 이름(15/700) + 1.5px 차콜 아래선.
class _SettingsSection extends StatelessWidget {
  /// 2026-10-28: 묶음 이름 [title]로 만든다.
  const _SettingsSection(this.title);

  final String title;

  /// 2026-10-28: 묶음 이름 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.section,
        PayseSpace.screenHorizontal,
        0,
      ),
      padding: const EdgeInsets.only(bottom: PayseSpace.x2),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: PayseColors.charcoal, width: 1.5),
        ),
      ),
      child: Semantics(
        header: true,
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 15,
            height: 22 / 15,
            fontWeight: FontWeight.w700,
            color: PayseColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// 2026-10-28: 누르면 선택 화면을 여는 밑줄 칸. PayseTextField와 같은 라벨(13/600)·높이 52·1px borderStrong 밑줄·
/// 값(17/500)·도움말(12/18)에 오른쪽 › 18을 둔다. 값이 없으면 [placeholder]를 보조 글자색으로 보인다.
class _PickerField extends StatelessWidget {
  /// 2026-10-28: 라벨 [label], 값 [value], 빈 값 문구 [placeholder], 도움말 [helper], 누름 [onTap](null이면 비활성),
  /// 값을 보조 글자색으로 보일지 [muted]로 만든다.
  const _PickerField({
    super.key,
    required this.label,
    required this.value,
    required this.placeholder,
    required this.helper,
    required this.onTap,
    this.muted = false,
  });

  final String label;
  final String? value;
  final String placeholder;
  final String helper;
  final VoidCallback? onTap;
  final bool muted;

  /// 2026-10-28: 라벨·값 줄·도움말을 반환한다.
  @override
  Widget build(BuildContext context) {
    final shown = value ?? placeholder;
    final secondary = muted || value == null;
    return Semantics(
      button: true,
      enabled: onTap != null,
      label: '$label, $shown',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                height: 18 / 13,
                fontWeight: FontWeight.w600,
                color: PayseColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              constraints: const BoxConstraints(
                minHeight: PayseTextField.fieldHeight,
              ),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: PayseColors.borderStrong),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      shown,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: secondary
                            ? FontWeight.w400
                            : FontWeight.w500,
                        color: secondary
                            ? PayseColors.textSecondary
                            : PayseColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: PayseSpace.x2),
                  const Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: PayseColors.borderStrong,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              helper,
              style: const TextStyle(
                fontSize: 12,
                height: 18 / 12,
                color: PayseColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-28: '월급 설정 저장하기' 버튼. 높이 48·반경 8·15/600. 켜지면 1px borderStrong·textPrimary,
/// 꺼지면 1px dividerSection·textSecondary이며 접근성 상태도 비활성이다.
class _SaveButton extends StatelessWidget {
  /// 2026-10-28: 글자 [label]과 누름 [onPressed](null이면 비활성)로 만든다.
  const _SaveButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  /// 2026-10-28: 테두리 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return OutlinedButton(
      key: const ValueKey('salary-save'),
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(48),
        backgroundColor: PayseColors.background,
        foregroundColor: PayseColors.textPrimary,
        disabledForegroundColor: PayseColors.textSecondary,
        side: BorderSide(
          color: enabled
              ? PayseColors.borderStrong
              : PayseColors.dividerSection,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PayseRadius.sm),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );
  }
}

/// 2026-10-28: 월급 설정 바텀시트 틀. 손잡이 36×4 → 제목(17/700) → 도움말(13, textSecondary) → 내용 [child].
/// 내용이 길면(계좌가 많을 때 등) 내용만 스크롤한다.
class _SheetFrame extends StatelessWidget {
  /// 2026-10-28: 시트 키 [sheetKey], 제목 [title], 도움말 [helper], 내용 [child]로 만든다.
  const _SheetFrame({
    required this.sheetKey,
    required this.title,
    required this.helper,
    required this.child,
  });

  final Key sheetKey;
  final String title;
  final String helper;
  final Widget child;

  /// 2026-10-28: 시트 내용을 반환한다. 손잡이·제목·도움말은 고정하고 내용만 시트 안에서 스크롤한다.
  @override
  Widget build(BuildContext context) {
    const side = PayseSpace.screenHorizontal;
    return SafeArea(
      top: false,
      child: Column(
        key: sheetKey,
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              side,
              PayseSpace.x3,
              side,
              PayseSpace.x4,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: PayseColors.dividerSection,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: PayseSpace.x5),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      height: 1.45,
                      fontWeight: FontWeight.w700,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(height: PayseSpace.x1),
                Text(
                  helper,
                  style: const TextStyle(
                    fontSize: 13,
                    height: 19 / 13,
                    color: PayseColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(side, 0, side, PayseSpace.x6),
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-10-28: 월급일 바텀시트. 달력형 1~31일. 날짜 칸은 가로·세로 모두 48dp 이상이며, 7칸이 들어가면 7칸, 좁은 화면에서는
/// 48dp가 지켜지는 만큼으로 칸 수를 줄인다(예: 320dp 5칸, 360dp 6칸). 고른 날은 지름 40 차콜 원 + 흰 글자 600.
/// 누르면 그 날짜를 돌려주고 닫는다.
class _DaySheet extends StatelessWidget {
  /// 2026-10-28: 지금 고른 날짜 [selected]로 만든다.
  const _DaySheet({required this.selected});

  final int? selected;

  /// 2026-10-28: 날짜 칸 한 변의 최소 크기(터치 48dp).
  static const double _minCell = 48;

  /// 2026-10-28: 시트 내용을 반환한다.
  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      sheetKey: const ValueKey('salary-day-sheet'),
      title: '월급일 선택',
      helper: '해당 날짜가 없는 달에는 말일로 계산해요.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / _minCell).floor().clamp(1, 7);
          final cell = constraints.maxWidth / columns;
          return Wrap(
            children: [
              for (var day = 1; day <= 31; day++)
                SizedBox(
                  width: cell,
                  height: cell,
                  child: _DayCell(
                    day: day,
                    selected: day == selected,
                    onTap: () => Navigator.of(context).pop(day),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// 2026-10-28: 달력형 날짜 한 칸. 고른 날은 차콜 원·흰 글자, 나머지는 textPrimary 글자만 둔다.
class _DayCell extends StatelessWidget {
  /// 2026-10-28: 날짜 [day], 고름 여부 [selected], 누름 [onTap]으로 만든다.
  const _DayCell({
    required this.day,
    required this.selected,
    required this.onTap,
  });

  final int day;
  final bool selected;
  final VoidCallback onTap;

  /// 2026-10-28: 날짜 칸을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: '매월 $day일',
      excludeSemantics: true,
      child: InkResponse(
        key: ValueKey('salary-day-$day'),
        onTap: onTap,
        radius: 22,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: selected
                ? const BoxDecoration(
                    color: PayseColors.charcoal,
                    shape: BoxShape.circle,
                  )
                : null,
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: 16,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected
                    ? PayseColors.onCharcoal
                    : PayseColors.textPrimary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 2026-10-28: 월급 계좌 바텀시트. 계산에 쓰기로 고른 계좌만 SelectionListRow로 보이며 하나를 누르면 그 계좌를 돌려주고 닫는다.
class _AccountSheet extends StatelessWidget {
  /// 2026-10-28: 이름을 찾을 [snapshot], 고를 수 있는 [accounts], 지금 고른 계좌 [selected]로 만든다.
  const _AccountSheet({
    required this.snapshot,
    required this.accounts,
    required this.selected,
  });

  final FinancialSnapshot snapshot;
  final List<Account> accounts;
  final String? selected;

  /// 2026-10-28: 시트 내용을 반환한다.
  @override
  Widget build(BuildContext context) {
    return _SheetFrame(
      sheetKey: const ValueKey('salary-account-sheet'),
      title: '월급 계좌 선택',
      helper: '계산에 쓰기로 고른 계좌 중에서 고를 수 있어요.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final a in accounts)
            SelectionListRow(
              key: ValueKey('salary-account-${a.accountId}'),
              title: a.productName,
              subtitle: accountLabel(snapshot, a),
              selected: a.accountId == selected,
              onChanged: (_) => Navigator.of(context).pop(a.accountId),
            ),
        ],
      ),
    );
  }
}
