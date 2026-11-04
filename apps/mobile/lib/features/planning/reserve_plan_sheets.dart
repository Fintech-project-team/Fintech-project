import 'package:flutter/material.dart';

import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_text_field.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/salary_settings_screen.dart' show GroupedDigitsFormatter;
import '../overview/calculation_detail_screen.dart' show mdText;
import '../overview/transaction_sheets.dart' show RadioRow;
import 'reserve_edit.dart';
import '../../shared/design/underlined_text.dart';

/// 2026-11-04: 지출 선택창에서 고른 결과(예정 지출과 이 돈에서 쓸 금액).
typedef PlanPick = ({String obligationId, int amountKrw});

/// 2026-11-04: 사용 계획 행 시트의 결과. 금액을 [amountKrw]로 바꾸거나([PlanRowAmount]) 해제한다([PlanRowRelease]).
sealed class PlanRowAction {
  const PlanRowAction();
}

/// 2026-11-04: 쓸 금액을 바꾼다.
final class PlanRowAmount extends PlanRowAction {
  /// 2026-11-04: 새 금액 [amountKrw]로 만든다.
  const PlanRowAmount(this.amountKrw);

  final int amountKrw;
}

/// 2026-11-04: 사용 계획을 해제한다(예정 지출은 그대로).
final class PlanRowRelease extends PlanRowAction {
  /// 2026-11-04: 해제 결과를 만든다.
  const PlanRowRelease();
}

/// 2026-11-04: 사용 계획 시트 틀. 손잡이·제목·닫기·보조 줄 → 본문(스크롤) → 선 → (있으면) 밑줄 글자 버튼 → 아래 버튼. 키보드가
/// 올라오면 그만큼 위로 올린다.
class _PlanSheet extends StatelessWidget {
  /// 2026-11-04: 제목 [title], 보조 줄 [meta], 본문 [children], 아래 버튼 [bottom], 그 위 글자 버튼 [link]로 만든다.
  const _PlanSheet({
    required this.title,
    required this.meta,
    required this.children,
    required this.bottom,
    this.link,
    this.divider = true,
  });

  final String title;
  final String meta;
  final List<Widget> children;
  final Widget bottom;
  final Widget? link;
  final bool divider;

  /// 2026-11-04: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: PayseSpace.x2),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              PayseSpace.x2,
              PayseSpace.x2,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '닫기',
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, size: 22),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              0,
              PayseSpace.screenHorizontal,
              PayseSpace.x1,
            ),
            child: Text(
              meta,
              key: const ValueKey('plan-sheet-meta'),
              style: PayseTypography.caption,
            ),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(
                PayseSpace.screenHorizontal,
                0,
                PayseSpace.screenHorizontal,
                PayseSpace.x6,
              ),
              children: children,
            ),
          ),
          if (divider) const Divider(height: 1, color: PayseColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              PayseSpace.x3,
              PayseSpace.screenHorizontal,
              PayseSpace.x6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (link case final link?) ...[
                  Center(child: link),
                  const SizedBox(height: PayseSpace.x1),
                ],
                bottom,
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-11-04: 차콜 '적용하기' 버튼. [onPressed]가 null이면 비활성이다.
Widget _applyButton(VoidCallback? onPressed) => SizedBox(
  height: 52,
  child: FilledButton(
    key: const ValueKey('plan-sheet-apply'),
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: PayseColors.charcoal,
      foregroundColor: PayseColors.onCharcoal,
      disabledBackgroundColor: PayseColors.surfaceMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    child: const Text('적용하기'),
  ),
);

/// 2026-11-04: '이 돈에서 쓸 금액' 입력칸과 그 아래 한 줄(왼쪽 안내 [left], 오른쪽 '최대 n원'). [over]면 왼쪽을 오류 색으로 보인다.
class _AmountField extends StatelessWidget {
  /// 2026-11-04: 입력 [controller], 최대 [maxKrw], 왼쪽 안내 [left]로 만든다.
  const _AmountField({
    required this.controller,
    required this.maxKrw,
    required this.left,
    required this.over,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int maxKrw;
  final String? left;
  final bool over;
  final ValueChanged<String> onChanged;

  /// 2026-11-04: 입력칸과 안내 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final style = PayseTypography.caption;
    return Padding(
      padding: const EdgeInsets.only(top: PayseSpace.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PayseTextField(
            key: const ValueKey('plan-amount'),
            label: '이 돈에서 쓸 금액',
            controller: controller,
            hintText: '0',
            textAlign: TextAlign.end,
            keyboardType: TextInputType.number,
            inputFormatters: const [GroupedDigitsFormatter()],
            textInputAction: TextInputAction.done,
            onChanged: onChanged,
            valueStyle: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w500,
              color: PayseColors.textPrimary,
              fontFeatures: PayseTypography.tabular,
            ),
            trailing: const Text(
              '원',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  over ? '최대 금액보다 많아요.' : left ?? '',
                  key: const ValueKey('plan-amount-left'),
                  style: over
                      ? style.copyWith(color: PayseColors.error)
                      : style,
                ),
              ),
              const SizedBox(width: PayseSpace.x3),
              Text(
                '최대 ${formatKrw(maxKrw)}',
                key: const ValueKey('plan-amount-max'),
                style: style,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 2026-11-04: 입력 글자 [text](쉼표 포함)의 금액. 비었거나 숫자가 아니면 null이다.
int? _amountOf(String text) => int.tryParse(text.replaceAll(',', ''));

/// 2026-11-04: R-3 '이 돈으로 낼 지출 선택'. 이번 월급 주기 [range]의 후보 [candidates]에서 하나를 고르고 쓸 금액을 입력한다.
/// 다른 남겨둘 돈이 이미 다 쓰기로 한 지출은 흐리게 두고 고를 수 없다. [maxOf]는 지출별 최대 금액이다.
class PlanPickSheet extends StatefulWidget {
  /// 2026-11-04: 후보 [candidates], 범위 [range], 최대 금액 [maxOf]로 만든다.
  const PlanPickSheet({
    super.key,
    required this.candidates,
    required this.range,
    required this.maxOf,
  });

  final List<PlanCandidate> candidates;
  final String range;
  final int Function(String obligationId) maxOf;

  /// 2026-11-04: 고른 지출·금액 상태를 반환한다.
  @override
  State<PlanPickSheet> createState() => _PlanPickSheetState();
}

/// 2026-11-04: 고른 지출과 금액 입력을 보관한다.
class _PlanPickSheetState extends State<PlanPickSheet> {
  String? _picked;
  final TextEditingController _amount = TextEditingController();

  /// 2026-11-04: 입력칸을 폐기한다.
  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// 2026-11-04: 지출 [id]를 고르고 금액을 그 최대 금액으로 채운다.
  void _pick(String id) => setState(() {
    _picked = id;
    _amount.text = formatKrwDigits(widget.maxOf(id));
  });

  /// 2026-11-04: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    final picked = _picked;
    final max = picked == null ? null : widget.maxOf(picked);
    final amount = _amountOf(_amount.text);
    final over = max != null && amount != null && amount > max;
    final ok = picked != null && amount != null && amount > 0 && !over;
    return _PlanSheet(
      title: '이 돈으로 낼 지출 선택',
      meta: '이번 월급 주기(${widget.range}) 예정 지출에서 골라요',
      bottom: _applyButton(
        ok
            ? () =>
                  Navigator.of(context)
                      .pop<PlanPick>((obligationId: picked, amountKrw: amount))
            : null,
      ),
      children: [
        for (final c in widget.candidates)
          Opacity(
            opacity: c.maxKrw > 0 ? 1 : .45,
            child: IgnorePointer(
              ignoring: c.maxKrw == 0,
              child: RadioRow(
                key: ValueKey('plan-candidate-${c.obligationId}'),
                label: c.label,
                caption: [
                  '${mdText(c.dueDate)} 예정',
                  if (c.maxKrw == 0)
                    '${c.heldBy ?? '다른 남겨둘 돈'}에서 낼 계획이 있어요'
                  else
                    '최대 ${formatKrw(c.maxKrw)}',
                ].join(' · '),
                selected: picked == c.obligationId,
                onTap: () => _pick(c.obligationId),
              ),
            ),
          ),
        if (picked != null && max != null)
          _AmountField(
            controller: _amount,
            maxKrw: max,
            left: null,
            over: over,
            onChanged: (_) => setState(() {}),
          ),
      ],
    );
  }
}

/// 2026-11-04: R-5a·R-6 사용 계획 행 시트. 금액을 바꿀 수 있으면([adjustable]) 금액 입력칸(왼쪽에 이미 나간 금액이나 줄이기만
/// 되는 이유, 오른쪽에 최대 금액)과 '사용 계획 해제' 글자 버튼·'적용하기'를, 다음 월급 기간 지출이면 금액 한 줄과 '사용 계획 해제'
/// 버튼만 보인다.
class PlanRowSheet extends StatefulWidget {
  /// 2026-11-04: 사용 계획 [item], 최대 금액 [maxKrw], 조정 가능 [adjustable], 월급 주기를 아는지 [cycleKnown]으로 만든다.
  const PlanRowSheet({
    super.key,
    required this.item,
    required this.maxKrw,
    required this.adjustable,
    required this.cycleKnown,
  });

  final PlanItem item;
  final int maxKrw;
  final bool adjustable;
  final bool cycleKnown;

  /// 2026-11-04: 금액 입력 상태를 반환한다.
  @override
  State<PlanRowSheet> createState() => _PlanRowSheetState();
}

/// 2026-11-04: 금액 입력을 보관한다.
class _PlanRowSheetState extends State<PlanRowSheet> {
  late final TextEditingController _amount = TextEditingController(
    text: formatKrwDigits(widget.item.amountKrw),
  );

  /// 2026-11-04: 입력칸을 폐기한다.
  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// 2026-11-04: 해제를 돌려주며 닫는다.
  void _release() =>
      Navigator.of(context).pop<PlanRowAction>(const PlanRowRelease());

  /// 2026-11-04: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final title = item.label ?? '예정 지출';
    final due = [
      if (item.dueDate case final d?) '${mdText(d)} 예정',
      if (!widget.adjustable) '다음 월급 기간',
    ].join(' · ');
    if (!widget.adjustable) {
      return _PlanSheet(
        title: title,
        meta: due,
        divider: false,
        bottom: SizedBox(
          height: 52,
          child: OutlinedButton(
            key: const ValueKey('plan-row-release'),
            onPressed: _release,
            style: OutlinedButton.styleFrom(
              foregroundColor: PayseColors.textPrimary,
              side: const BorderSide(color: PayseColors.borderStrong),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PayseRadius.sm),
              ),
              textStyle: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text('사용 계획 해제'),
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: PayseSpace.x4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '이 돈에서 쓸 금액',
                    style: TextStyle(
                      fontSize: 15,
                      color: PayseColors.textSecondary,
                    ),
                  ),
                ),
                Text(
                  formatKrw(item.amountKrw),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: PayseColors.textPrimary,
                    fontFeatures: PayseTypography.tabular,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final amount = _amountOf(_amount.text);
    final over = amount != null && amount > widget.maxKrw;
    final ok = amount != null && amount > 0 && !over;
    return _PlanSheet(
      title: title,
      meta: due,
      link: TextButton(
        key: const ValueKey('plan-row-release'),
        onPressed: _release,
        style: TextButton.styleFrom(
          foregroundColor: PayseColors.textPrimary,
          minimumSize: const Size(0, 44),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        child: const UnderlinedText('사용 계획 해제'),
      ),
      bottom: _applyButton(
        ok
            ? () =>
                  Navigator.of(context)
                      .pop<PlanRowAction>(PlanRowAmount(amount))
            : null,
      ),
      children: [
        _AmountField(
          controller: _amount,
          maxKrw: widget.maxKrw,
          left: !widget.cycleKnown
              ? '월급 주기를 확인할 수 없어 줄이기만 할 수 있어요'
              : item.releasedKrw > 0
              ? '이미 ${formatKrw(item.releasedKrw)}이 나갔어요'
              : null,
          over: over,
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }
}
