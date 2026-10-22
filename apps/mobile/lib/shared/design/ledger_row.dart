import 'package:flutter/material.dart';

import 'amount_format.dart';
import 'payse_tokens.dart';

/// 2026-10-20: 장부 한 줄(마이너스 선 → 항목명 → 색 칩 … 금액 › ). 홈과 계산 내역이 함께 쓴다.
/// 기본값은 확정 홈 규칙이며, 보조 설명·화살표·행 간격은 화면별로 바꿀 수 있다.
/// 금액이 우선이며 잘리지 않는다(행 폭의 60%를 넘으면 한 줄 그대로 비율 축소). 항목명은 남은 폭에서 최대 2줄, 넘치면 말줄임표.
class LedgerRow extends StatelessWidget {
  /// 2026-10-20: 한 줄을 만든다.
  /// [name] 항목명, [amountKrw] 원 단위 정수 금액(계산된 값을 그대로 표시).
  /// [isDeduction]이 true면 항목명 앞에 마이너스 선을 그린다.
  /// [chipColor]는 구성 색 칩(없으면 생략), [subtitle]은 보조 설명 줄(없으면 생략).
  /// [showChevron]은 화살표 표시, [verticalPadding]은 행 위아래 여백(dp), [onTap]은 누를 때 동작.
  const LedgerRow({
    super.key,
    required this.name,
    required this.amountKrw,
    this.isDeduction = false,
    this.chipColor,
    this.subtitle,
    this.showChevron = false,
    this.verticalPadding = 15,
    this.emphasizeName = false,
    this.onTap,
  });

  final String name;
  final int amountKrw;
  final bool isDeduction;
  final Color? chipColor;
  final String? subtitle;
  final bool showChevron;
  final double verticalPadding;
  final bool emphasizeName;
  final VoidCallback? onTap;

  static const double minusWidth = 16;
  static const double minusThickness = 1.75;
  static const double minusColumnWidth = 24;
  static const double chipSize = 8;
  static const double firstLineHeight = 22;
  static const int nameMaxLines = 2;
  static const double amountMaxWidthFactor = 0.6;

  /// 2026-10-20: 첫 줄 높이에 기호·칩·금액·화살표를 맞춘 행을 반환한다.
  @override
  Widget build(BuildContext context) {
    final nameStyle = PayseTypography.ledgerName.copyWith(
      fontWeight: emphasizeName ? FontWeight.w600 : FontWeight.w500,
    );
    final semanticsLabel = [
      if (isDeduction) '빼기',
      name,
      ?subtitle,
      spokenKrw(amountKrw),
    ].join(' ');

    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPadding),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: minusColumnWidth,
              height: firstLineHeight,
              child: isDeduction
                  ? const Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(
                        key: ValueKey('ledger-minus'),
                        width: minusWidth,
                        height: minusThickness,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: PayseColors.charcoal,
                            borderRadius: BorderRadius.all(Radius.circular(1)),
                          ),
                        ),
                      ),
                    )
                  : null,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          key: const ValueKey('ledger-name'),
                          style: nameStyle,
                          maxLines: nameMaxLines,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (chipColor != null) ...[
                        const SizedBox(width: 6),
                        Padding(
                          padding: const EdgeInsets.only(
                            top: (firstLineHeight - chipSize) / 2,
                          ),
                          child: Container(
                            key: const ValueKey('ledger-chip'),
                            width: chipSize,
                            height: chipSize,
                            decoration: BoxDecoration(
                              color: chipColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: PayseTypography.caption.copyWith(height: 18 / 12),
                    ),
                ],
              ),
            ),
            SizedBox(
              height: firstLineHeight,
              child: Padding(
                padding: const EdgeInsets.only(left: PayseSpace.x3),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * amountMaxWidthFactor,
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      formatKrw(amountKrw),
                      key: const ValueKey('ledger-amount'),
                      style: PayseTypography.ledgerAmount,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ),
                ),
              ),
            ),
            if (showChevron)
              const SizedBox(
                width: 24,
                height: firstLineHeight,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Icon(
                    Icons.chevron_right,
                    key: ValueKey('ledger-chevron'),
                    size: 18,
                    color: PayseColors.textSecondary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    return Semantics(
      label: semanticsLabel,
      button: onTap != null,
      excludeSemantics: true,
      child: onTap == null
          ? row
          : InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: PayseSize.touchMin,
                ),
                child: row,
              ),
            ),
    );
  }
}
