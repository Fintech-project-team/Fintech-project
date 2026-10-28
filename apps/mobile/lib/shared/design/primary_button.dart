import 'package:flutter/material.dart';

import 'payse_tokens.dart';

/// 2026-10-20: 화면 폭 차콜 띠 형태의 주요 버튼(확정 홈 '계산 내역 보기').
class PrimaryButton extends StatelessWidget {
  /// 2026-10-20: [label]과 [onPressed]로 버튼을 만든다. [onPressed]가 null이면 비활성이다.
  /// [contentPadding]은 띠 안쪽 글자·화살표 여백이며 화면 좌우 여백이 아니다.
  /// 화면 여백(바깥 배치)은 상위 레이아웃이 정하고, 필요하면 같은 값을 이 인자로 넘겨 글자 시작선을 맞춘다.
  /// 2026-10-28: [back]이면 이전 화면으로 돌아가는 버튼이라 기본 모양을 좌우로 뒤집는다. 화살표 ‹를 왼쪽 끝에,
  /// 글자를 오른쪽 끝에 두고 오른쪽 화살표를 뺀다(혜연 결정).
  const PrimaryButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.contentPadding = const EdgeInsets.symmetric(
      horizontal: PayseSpace.buttonContentHorizontal,
    ),
    this.back = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final EdgeInsetsGeometry contentPadding;
  final bool back;

  /// 2026-10-20: 활성은 차콜 바탕·흰 글자·옐로 화살표, 비활성은 회색 바탕을 반환한다.
  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    final background = enabled
        ? PayseColors.charcoal
        : PayseColors.surfaceMuted;
    final foreground = enabled
        ? PayseColors.onCharcoal
        : PayseColors.textSecondary;
    Widget arrow(IconData icon) => Icon(
      icon,
      size: 20,
      color: enabled ? PayseColors.moonYellow : PayseColors.textSecondary,
    );
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      onTap: onPressed,
      child: Material(
        color: background,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            height: PayseSize.primaryBandHeight,
            child: Padding(
              padding: contentPadding,
              child: Row(
                children: [
                  if (back) ...[
                    arrow(Icons.chevron_left),
                    const SizedBox(width: PayseSpace.x4),
                  ],
                  Expanded(
                    child: Text(
                      label,
                      textAlign: back ? TextAlign.right : TextAlign.left,
                      style: PayseTypography.button.copyWith(color: foreground),
                    ),
                  ),
                  if (!back) arrow(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
