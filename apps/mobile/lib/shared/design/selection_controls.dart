import 'package:flutter/material.dart';

import 'payse_tokens.dart';

/// 2026-10-21: 원형 체크 표시(design.md §5 SelectionCheck). 선택 상태를 채움과 체크 모양으로 함께 보인다.
class SelectionCheckMark extends StatelessWidget {
  /// 2026-10-21: 선택 여부 [selected], 사용 가능 여부 [enabled]로 만든다.
  const SelectionCheckMark({
    super.key,
    required this.selected,
    this.enabled = true,
  });

  static const double size = 24;
  static const double borderWidth = 1.5;

  final bool selected;
  final bool enabled;

  /// 2026-10-21: 선택(charcoal + moonYellow 체크)·미선택(테두리 + 흐린 체크)·비활성 모양을 반환한다.
  @override
  Widget build(BuildContext context) {
    final (Color fill, Color? border, Color? check) = !enabled
        ? (PayseColors.surfaceMuted, PayseColors.dividerSection, null)
        : selected
        ? (PayseColors.charcoal, null, PayseColors.moonYellow)
        : (
            PayseColors.background,
            PayseColors.borderStrong,
            PayseColors.dividerSection,
          );
    return Container(
      key: const ValueKey('selection-check-mark'),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: border == null
            ? null
            : Border.all(color: border, width: borderWidth),
      ),
      child: check == null ? null : Icon(Icons.check, size: 16, color: check),
    );
  }
}

/// 2026-10-21: 체크 행(10-1 약관 등). 체크 → 이름 → 보기 링크. 행 전체를 눌러 선택을 바꾼다.
class SelectionCheckRow extends StatelessWidget {
  /// 2026-10-21: 이름 [label], 선택 [selected], 변경 콜백 [onChanged]로 만든다. [prefix]는 이름 앞 짧은 표시(예: 필수),
  /// [emphasis]는 '모두 동의' 같은 대표 행, [linkLabel]·[onLink]는 오른쪽 보기 링크다.
  const SelectionCheckRow({
    super.key,
    required this.label,
    required this.selected,
    required this.onChanged,
    this.prefix,
    this.emphasis = false,
    this.enabled = true,
    this.linkLabel,
    this.onLink,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final String? prefix;
  final bool emphasis;
  final bool enabled;
  final String? linkLabel;
  final VoidCallback? onLink;

  /// 2026-10-21: 최소 48dp 높이의 체크 행을 반환한다. 비활성이면 흐리게 표시하고 누를 수 없다.
  @override
  Widget build(BuildContext context) {
    final active = enabled && onChanged != null;
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: PayseSize.touchMin),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              checked: selected,
              enabled: active,
              label: [?prefix, label].join(' '),
              excludeSemantics: true,
              onTap: active ? () => onChanged!(!selected) : null,
              child: InkWell(
                onTap: active ? () => onChanged!(!selected) : null,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PayseSize.touchMin,
                  ),
                  child: Row(
                    children: [
                      SelectionCheckMark(selected: selected, enabled: enabled),
                      const SizedBox(width: PayseSpace.x3),
                      if (prefix != null) ...[
                        Text(
                          prefix!,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: PayseColors.textSecondary,
                          ),
                        ),
                        const SizedBox(width: PayseSpace.x1),
                      ],
                      Expanded(
                        child: Text(
                          label,
                          style: emphasis
                              ? const TextStyle(
                                  fontSize: 16,
                                  height: 1.4,
                                  fontWeight: FontWeight.w700,
                                  color: PayseColors.textPrimary,
                                )
                              : PayseTypography.ledgerName,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (linkLabel != null && onLink != null)
            Semantics(
              link: true,
              label: '$label $linkLabel',
              excludeSemantics: true,
              onTap: onLink,
              child: InkWell(
                onTap: onLink,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: PayseSize.touchMin,
                    minWidth: PayseSize.touchMin,
                  ),
                  child: Center(
                    child: Text(
                      linkLabel!,
                      style: const TextStyle(
                        fontSize: 13,
                        color: PayseColors.textSecondary,
                        decoration: TextDecoration.underline,
                        decorationColor: PayseColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return enabled ? row : Opacity(opacity: 0.45, child: row);
  }
}

/// 2026-10-21: 목록 선택 행(12-1 금융사·01-1 계좌 등). 이름·보조 줄 … 오른쪽 체크, 아래 dividerRow.
class SelectionListRow extends StatelessWidget {
  /// 2026-10-21: 이름 [title], 보조 줄 [subtitle], 선택 [selected], 변경 콜백 [onChanged]로 만든다.
  /// 2026-10-22: 이름 앞 그림 [leading](예: 금융사 표시)과 체크 앞 값 [trailing](예: 잔액)을 선택으로 받는다.
  /// [trailingLabel]은 화면 읽기 프로그램에 [trailing] 대신 읽힐 문장이다.
  const SelectionListRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onChanged,
    this.subtitle,
    this.enabled = true,
    this.leading,
    this.trailing,
    this.trailingLabel,
  });

  static const double minHeight = 64;

  final String title;
  final String? subtitle;
  final bool selected;
  final ValueChanged<bool>? onChanged;
  final bool enabled;
  final Widget? leading;
  final Widget? trailing;
  final String? trailingLabel;

  /// 2026-10-21: 최소 64dp 높이의 선택 행을 반환한다.
  @override
  Widget build(BuildContext context) {
    final active = enabled && onChanged != null;
    return Semantics(
      checked: selected,
      enabled: active,
      label: [title, ?subtitle, ?trailingLabel].join(', '),
      excludeSemantics: true,
      onTap: active ? () => onChanged!(!selected) : null,
      child: InkWell(
        onTap: active ? () => onChanged!(!selected) : null,
        child: Container(
          constraints: const BoxConstraints(minHeight: minHeight),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
          ),
          child: Row(
            children: [
              if (leading != null) ...[
                leading!,
                const SizedBox(width: PayseSpace.x3),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: PayseTypography.ledgerName.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null)
                      Text(subtitle!, style: PayseTypography.caption),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: PayseSpace.x3),
                trailing!,
              ],
              const SizedBox(width: PayseSpace.x3),
              SelectionCheckMark(selected: selected, enabled: enabled),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-21: 여러 값 중 고르는 칩(design.md §5 PayseChip). 선택은 charcoal 채움·흰 글자·옐로 체크.
class PayseChip extends StatelessWidget {
  /// 2026-10-21: 표시 [label], 선택 [selected], 누름 콜백 [onSelected]로 만든다.
  const PayseChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  static const double height = 36;

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;

  /// 2026-10-21: 보이는 높이 36dp, 누르는 영역 48dp의 칩을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onSelected == null ? null : () => onSelected!(!selected),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onSelected == null ? null : () => onSelected!(!selected),
        child: SizedBox(
          height: PayseSize.touchMin,
          child: Center(
            child: Container(
              key: const ValueKey('payse-chip-body'),
              height: height,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: selected ? PayseColors.charcoal : PayseColors.background,
                borderRadius: BorderRadius.circular(PayseRadius.xl),
                border: selected
                    ? null
                    : Border.all(color: PayseColors.borderStrong),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (selected) ...[
                    const Icon(
                      Icons.check,
                      size: 14,
                      color: PayseColors.moonYellow,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: selected
                          ? PayseColors.onCharcoal
                          : PayseColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 2026-10-21: 켜기·끄기 토글(design.md §5 PayseToggle). 아이콘 없이 색과 손잡이 위치로 함께 구분한다.
class PayseToggle extends StatelessWidget {
  /// 2026-10-21: 켜짐 [value], 변경 콜백 [onChanged], 접근성 이름 [semanticLabel]로 만든다.
  const PayseToggle({
    super.key,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
  });

  static const double width = 52;
  static const double height = 32;
  static const double knob = 21;

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String semanticLabel;

  /// 2026-10-21: 보이는 크기 52×32dp, 누르는 높이 48dp의 토글을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      toggled: value,
      enabled: onChanged != null,
      label: semanticLabel,
      excludeSemantics: true,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: SizedBox(
          height: PayseSize.touchMin,
          width: width,
          child: Center(
            child: AnimatedContainer(
              key: const ValueKey('payse-toggle-track'),
              duration: const Duration(milliseconds: 150),
              width: width,
              height: height,
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: value ? PayseColors.charcoal : PayseColors.background,
                borderRadius: BorderRadius.circular(PayseRadius.xl),
                border: value
                    ? null
                    : Border.all(color: PayseColors.borderStrong, width: 1.5),
              ),
              child: AnimatedAlign(
                duration: const Duration(milliseconds: 150),
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  key: const ValueKey('payse-toggle-knob'),
                  width: knob,
                  height: knob,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: value
                        ? PayseColors.moonYellow
                        : PayseColors.borderStrong,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
