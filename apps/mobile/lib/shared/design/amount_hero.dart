import 'package:flutter/material.dart';

import 'amount_format.dart';
import 'payse_theme.dart';
import 'payse_tokens.dart';

/// 2026-10-20: 홈 핵심 금액 영역. 계산된 정수 금액만 받아 표시하며 값을 보정하지 않는다.
class AmountHero extends StatelessWidget {
  /// 2026-10-20: 라벨·금액·기준 시각·안내 문장으로 위젯을 만든다.
  /// [amountKrw]가 null이면 정보 부족으로 보고 0원 대신 '계산할 수 없어요'를 보인다.
  /// [message]는 호출자가 만든 부족·정보 부족 안내 문장이며 없으면 생략한다.
  const AmountHero({
    super.key,
    required this.label,
    required this.amountKrw,
    this.asOfLabel,
    this.message,
  });

  final String label;
  final int? amountKrw;
  final String? asOfLabel;
  final String? message;

  static const String unavailableText = '계산할 수 없어요';

  /// 2026-10-20: 상태(정상·음수·정보 부족)에 맞는 금액 영역을 반환한다.
  @override
  Widget build(BuildContext context) {
    final finance = Theme.of(context).extension<PayseFinanceColors>()!;
    final amount = amountKrw;
    final isNegative = amount != null && amount < 0;

    final Widget amountLine;
    if (amount == null) {
      amountLine = Text(
        unavailableText,
        style: PayseTypography.amountLabel.copyWith(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: finance.unknown,
        ),
      );
    } else {
      final color = isNegative ? finance.negative : PayseColors.textPrimary;
      amountLine = Semantics(
        label: spokenKrw(amount),
        excludeSemantics: true,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(text: formatKrwDigits(amount)),
                const TextSpan(text: '원', style: PayseTypography.amountUnit),
              ],
            ),
            maxLines: 1,
            softWrap: false,
            style: PayseTypography.amountDisplay.copyWith(color: color),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: PayseTypography.amountLabel),
        const SizedBox(height: PayseSpace.x2),
        amountLine,
        if (asOfLabel != null) ...[
          const SizedBox(height: 10),
          Text(asOfLabel!, style: PayseTypography.caption),
        ],
        if (message != null) ...[
          const SizedBox(height: PayseSpace.x2),
          Text(
            message!,
            style: PayseTypography.caption.copyWith(
              fontSize: 13,
              color: PayseColors.textPrimary,
            ),
          ),
        ],
      ],
    );
  }
}
