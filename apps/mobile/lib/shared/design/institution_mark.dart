import 'package:flutter/widgets.dart';

import 'payse_tokens.dart';

/// 2026-10-22: 금융사 종류. 은행은 통장, 카드사는 카드 그림으로 그린다.
enum InstitutionKind { bank, card }

/// 2026-10-22: 금융사 표시(40×30). 실제 로고 대신 키 컬러를 낮춘 플랫 그림이며 이름 글자와 함께 쓴다.
/// 장식이므로 접근성 트리에서 제외한다.
class InstitutionMark extends StatelessWidget {
  /// 2026-10-22: 기관 코드 [code]와 종류 [kind]로 만든다. 색은 [InstitutionTones.of]에서 고른다.
  const InstitutionMark({super.key, required this.code, required this.kind});

  final String code;
  final InstitutionKind kind;

  static const Size size = Size(40, 30);

  /// 2026-10-22: 종류에 맞는 그림을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: CustomPaint(
        size: size,
        painter: _InstitutionPainter(InstitutionTones.of(code), kind),
      ),
    );
  }
}

/// 2026-10-22: 40×30 좌표계에서 통장(기울어진 앞표지·짧은 뒷장·휜 밝은 면·이름표)이나 카드를 그린다.
class _InstitutionPainter extends CustomPainter {
  /// 2026-10-22: 색 묶음 [tone]과 종류 [kind]로 만든다.
  const _InstitutionPainter(this.tone, this.kind);

  final InstitutionTone tone;
  final InstitutionKind kind;

  /// 2026-10-22: 크기에 맞춰 좌표계를 늘린 뒤 종류별 그림을 그린다.
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 40, size.height / 30);
    switch (kind) {
      case InstitutionKind.bank:
        _paintBook(canvas);
      case InstitutionKind.card:
        _paintCard(canvas);
    }
    canvas.restore();
  }

  /// 2026-10-22: 선 통장을 그린다. 모서리는 같은 색 둥근 선으로 부드럽게 한다.
  void _paintBook(Canvas canvas) {
    void shape(Path path, Color color, double rounding) {
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = rounding
          ..strokeJoin = StrokeJoin.round,
      );
    }

    shape(
      Path()
        ..moveTo(6.3, 6.5)
        ..lineTo(3.7, 22.6)
        ..quadraticBezierTo(3.6, 23.3, 4.3, 23.3)
        ..lineTo(8.6, 23.3)
        ..close(),
      InstitutionTones.bookLeaf,
      1,
    );
    shape(
      Path()
        ..moveTo(6.5, 6)
        ..lineTo(34.5, 6)
        ..lineTo(38, 27.8)
        ..lineTo(9.6, 27.8)
        ..close(),
      tone.base,
      1.4,
    );
    shape(
      Path()
        ..moveTo(6.5, 6)
        ..lineTo(34.5, 6)
        ..lineTo(35.8, 14)
        ..lineTo(16, 14)
        ..cubicTo(11.8, 14, 8.6, 11.8, 7.2, 9.4)
        ..close(),
      tone.light,
      1.4,
    );
    canvas.drawPath(
      Path()
        ..moveTo(23.6, 19.4)
        ..lineTo(34.2, 19.4)
        ..lineTo(35, 24.4)
        ..lineTo(24.4, 24.4)
        ..close(),
      Paint()..color = tone.label,
    );
  }

  /// 2026-10-22: 오른쪽 그늘·자기띠·칩·흰 선 2줄이 있는 카드를 그린다.
  void _paintCard(Canvas canvas) {
    const corner = Radius.circular(4);
    canvas.drawRRect(
      RRect.fromLTRBR(0, 2, 40, 28, corner),
      Paint()..color = tone.dark,
    );
    canvas.drawRRect(
      RRect.fromLTRBAndCorners(
        0,
        2,
        31,
        28,
        topLeft: corner,
        bottomLeft: corner,
      ),
      Paint()..color = tone.base,
    );
    canvas.drawRect(
      const Rect.fromLTWH(0, 7, 40, 5),
      Paint()..color = tone.stripe,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(25, 16, 32, 22, const Radius.circular(1.5)),
      Paint()..color = InstitutionTones.cardChip,
    );
    final line = Paint()..color = const Color(0xD9FFFFFF);
    canvas.drawRRect(
      RRect.fromLTRBR(4, 16, 16, 18, const Radius.circular(1)),
      line,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(4, 21, 12, 23, const Radius.circular(1)),
      line,
    );
  }

  /// 2026-10-22: 색이나 종류가 바뀌었을 때만 다시 그린다.
  @override
  bool shouldRepaint(_InstitutionPainter oldDelegate) =>
      oldDelegate.tone != tone || oldDelegate.kind != kind;
}
