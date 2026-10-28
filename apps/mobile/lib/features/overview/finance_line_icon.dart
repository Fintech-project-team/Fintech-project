import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';

/// 2026-10-27: 01-2 묶음 머리 아이콘 종류.
/// 2026-10-28: 01-3 시작 화면도 같은 아이콘을 쓴다.
enum FinanceIconKind { salary, card, reserve, scheduled }

/// 2026-10-28: 차콜 선 금융 아이콘. 접근성 트리에서 제외한다.
class FinanceLineIcon extends StatelessWidget {
  /// 2026-10-28: 종류 [kind]와 한 변 [size]로 만든다.
  const FinanceLineIcon(this.kind, {super.key, this.size = 20});

  final FinanceIconKind kind;
  final double size;

  /// 2026-10-28: 아이콘을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: _FinanceIconPainter(kind),
      ),
    );
  }
}

/// 2026-10-27: 01-2 묶음 머리 선 아이콘(24 격자 기준, 선 1.75, 둥근 끝). 지갑·카드·쌓인 동전·달력.
/// 2026-10-28: 01-3 시작 화면도 쓰도록 01-2 화면에서 옮겼다.
class _FinanceIconPainter extends CustomPainter {
  /// 2026-10-27: 아이콘 종류 [kind]로 만든다.
  const _FinanceIconPainter(this.kind);

  final FinanceIconKind kind;

  /// 2026-10-27: 24 격자 좌표를 [size]에 맞춰 그린다.
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24;
    canvas.scale(scale);
    final p = Paint()
      ..color = PayseColors.charcoal
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.75
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    RRect box(double l, double t, double w, double h, double r) =>
        RRect.fromLTRBR(l, t, l + w, t + h, Radius.circular(r));
    switch (kind) {
      case FinanceIconKind.salary:
        canvas.drawRRect(box(3, 5, 18, 15, 2), p);
        canvas.drawLine(const Offset(3, 8), const Offset(19, 8), p);
        canvas.drawLine(const Offset(5, 3), const Offset(17, 3), p);
        canvas.drawRRect(box(15, 11, 6, 4, 1), p);
      case FinanceIconKind.card:
        canvas.drawRRect(box(2.5, 5, 19, 14, 2), p);
        canvas.drawLine(const Offset(2.5, 10), const Offset(21.5, 10), p);
        canvas.drawLine(const Offset(6.5, 15), const Offset(10.5, 15), p);
      case FinanceIconKind.reserve:
        canvas.drawOval(Rect.fromLTRB(5, 3, 19, 9), p);
        canvas.drawLine(const Offset(5, 6), const Offset(5, 18), p);
        canvas.drawLine(const Offset(19, 6), const Offset(19, 18), p);
        canvas.drawArc(Rect.fromLTRB(5, 9, 19, 15), 0, 3.14159, false, p);
        canvas.drawArc(Rect.fromLTRB(5, 15, 19, 21), 0, 3.14159, false, p);
      case FinanceIconKind.scheduled:
        canvas.drawRRect(box(3, 4.5, 18, 16, 2), p);
        canvas.drawLine(const Offset(8, 2.5), const Offset(8, 6.5), p);
        canvas.drawLine(const Offset(16, 2.5), const Offset(16, 6.5), p);
        canvas.drawLine(const Offset(3, 10), const Offset(21, 10), p);
        canvas.drawLine(const Offset(8, 14), const Offset(11, 14), p);
    }
  }

  /// 2026-10-27: 종류가 바뀔 때만 다시 그린다.
  @override
  bool shouldRepaint(covariant _FinanceIconPainter old) => old.kind != kind;
}
