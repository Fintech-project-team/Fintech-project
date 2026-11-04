import 'package:flutter/widgets.dart';

import 'payse_tokens.dart';

/// 2026-11-04: 글꼴 밑줄 대신 글자 아래에 선을 직접 그은 글자(#212). 글꼴 밑줄은 띄어쓰기에서 높이가 달라져 보여서 쓰지 않는다.
/// 선은 1px이고 글자 상자 안 맨 아래에 그려 글자 높이·배치를 바꾸지 않는다.
class UnderlinedText extends StatelessWidget {
  /// 2026-11-04: 글자 [text], 덧붙일 글자 스타일 [style], 선 색 [lineColor](없으면 글자색), 밑줄 표시 [underline]으로 만든다.
  const UnderlinedText(
    this.text, {
    super.key,
    this.style,
    this.lineColor,
    this.underline = true,
  });

  final String text;
  final TextStyle? style;
  final Color? lineColor;
  final bool underline;

  /// 2026-11-04: 선 두께(dp).
  static const double thickness = 1;

  /// 2026-11-04: 글자와 아래 선을 반환한다.
  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: style);
    if (!underline) return label;
    final color =
        lineColor ??
        style?.color ??
        DefaultTextStyle.of(context).style.color ??
        PayseColors.textPrimary;
    return CustomPaint(
      foregroundPainter: UnderlinePainter(color),
      child: label,
    );
  }
}

/// 2026-11-04: 상자 맨 아래에 [color] 1px 선을 긋는다.
class UnderlinePainter extends CustomPainter {
  /// 2026-11-04: 선 색 [color]로 만든다.
  const UnderlinePainter(this.color);

  final Color color;

  /// 2026-11-04: 선을 그린다.
  @override
  void paint(Canvas canvas, Size size) {
    const t = UnderlinedText.thickness;
    canvas.drawRect(
      Rect.fromLTWH(0, size.height - t, size.width, t),
      Paint()..color = color,
    );
  }

  /// 2026-11-04: 색이 바뀌면 다시 그린다.
  @override
  bool shouldRepaint(UnderlinePainter oldDelegate) =>
      oldDelegate.color != color;
}
