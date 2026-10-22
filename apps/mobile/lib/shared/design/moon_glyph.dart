import 'package:flutter/material.dart';

import 'payse_tokens.dart';

/// 2026-10-20: 월급 주기 줄 옆의 달 기호. 데이터와 연결하지 않은 고정 모양이며 의미를 전달하지 않는다.
class MoonGlyph extends StatelessWidget {
  /// 2026-10-20: [size]는 한 변 길이(dp), 기본 26dp(확정 홈 시안).
  const MoonGlyph({super.key, this.size = 26});

  final double size;

  /// 2026-10-20: 접근성 트리에서 제외한 고정 달 그림을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: Size.square(size),
        painter: const _MoonPainter(),
      ),
    );
  }
}

/// 2026-10-20: 차콜 원 위에 왼쪽 그믐 형태의 옐로 밝은 면(고정 비율 0.2)을 그린다.
class _MoonPainter extends CustomPainter {
  /// 2026-10-20: 상태 없는 화가를 만든다.
  const _MoonPainter();

  static const double _litFraction = 0.2;

  /// 2026-10-20: [canvas]의 [size] 영역에 달을 그린다. 반환값 없음.
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2 * (11 / 12);
    final c = Offset(size.width / 2, size.height / 2);
    canvas.drawCircle(c, r, Paint()..color = PayseColors.charcoal);

    final k = (1 - 2 * _litFraction).abs() * r;
    final top = Offset(c.dx, c.dy - r);
    final bottom = Offset(c.dx, c.dy + r);
    final lit = Path()
      ..moveTo(top.dx, top.dy)
      ..arcToPoint(bottom, radius: Radius.circular(r), clockwise: false)
      ..arcToPoint(top, radius: Radius.elliptical(k, r), clockwise: true)
      ..close();
    canvas.drawPath(lit, Paint()..color = PayseColors.moonYellow);
  }

  /// 2026-10-20: 고정 모양이라 다시 그릴 필요가 없다. [oldDelegate]는 비교하지 않는다.
  @override
  bool shouldRepaint(covariant _MoonPainter oldDelegate) => false;
}
