import 'package:flutter/material.dart';

import '../../data/coachmark_record_store.dart';
import '../../shared/design/payse_tokens.dart';

/// 2026-10-28: 02-1a 1단계 문구 종류. U가 있으면 [computed], 지난 회차 월급 입금 근거가 없어 U가 없으면
/// [receiptAbsent], 그 밖의 이유로 U가 없으면 [otherInsufficient]다.
enum CoachmarkVariant { computed, receiptAbsent, otherInsufficient }

/// 2026-10-28: 02-1a 홈 코치마크(#28 5단계, 캔버스 Coach1~3·Coach1Insuff 확정). 홈 위에 charcoal 50% 덮개를 씌우고
/// 강조 영역은 실제 홈을 드러낸 채 1.5px moonYellow 테두리만 그린다. 설명은 '계산 내역 보기' 위 8dp에 아래 끝을 고정한
/// charcoal 안내 면이다. 강조 위치는 [amountRect]·[detailRect]·[planRect]가 돌려주는 실제 위젯 위치(전역 좌표)로 그린다.
class HomeCoachmark extends StatefulWidget {
  /// 2026-10-28: 1단계 문구 [variant], 대상 위치 함수 [amountRect]·[detailRect]·[planRect], 닫을 때 [onDone]으로 만든다.
  const HomeCoachmark({
    super.key,
    required this.variant,
    required this.amountRect,
    required this.detailRect,
    required this.planRect,
    required this.onDone,
  });

  final CoachmarkVariant variant;
  final Rect? Function() amountRect;
  final Rect? Function() detailRect;
  final Rect? Function() planRect;
  final ValueChanged<CoachmarkRecord> onDone;

  /// 2026-10-28: 덮개 색(charcoal 50%).
  static const Color scrim = Color(0x80242629);

  /// 2026-10-28: 화면 상태 객체를 반환한다.
  @override
  State<HomeCoachmark> createState() => _HomeCoachmarkState();
}

/// 2026-10-28: 단계와 마지막으로 잰 대상 위치를 보관한다. 위치가 바뀐 프레임에서만 다시 그린다.
class _HomeCoachmarkState extends State<HomeCoachmark> {
  final GlobalKey _layer = GlobalKey();
  final GlobalKey _panel = GlobalKey();
  int _step = 0;
  Rect? _hole;
  Rect? _detail;
  double? _panelTop;

  /// 2026-10-28: 단계별 강조 반경. 계산 내역 보기 띠는 화면 폭 전체라 0이다.
  static const List<double> _radius = [12, 0, 12];

  /// 2026-10-28: 단계별 제목·설명.
  (String, String) _copy() => switch (_step) {
    0 => switch (widget.variant) {
      CoachmarkVariant.computed => (
        '지금 쓸 수 있는 돈이에요',
        '계좌 잔액에서 모아둘 돈과 예정 지출을 빼고 계산해요.',
      ),
      CoachmarkVariant.receiptAbsent => (
        '월급 입금을 확인하면 계산해요',
        '입금이 확인되면 계좌 잔액에서 모아둘 돈과 예정 지출을 빼고 계산해요.',
      ),
      CoachmarkVariant.otherInsufficient => (
        '필요한 정보가 확인되면 계산해요',
        '정보가 확인되면 계좌 잔액에서 모아둘 돈과 예정 지출을 빼고 계산해요.',
      ),
    },
    1 => ('어떻게 계산했는지 확인해 보세요', '계좌별 잔액과 계산에 반영한 지출을 확인할 수 있어요.'),
    _ => ('계획은 여기서 관리해요', '예정 지출과 모아둘 돈을 확인하고 수정할 수 있어요.'),
  };

  /// 2026-10-28: 이 단계의 강조 대상 전역 위치를 반환한다. 금액 영역은 좌우·위아래 8dp 넓힌다.
  Rect? _target() => switch (_step) {
    0 => widget.amountRect()?.inflate(PayseSpace.x2),
    1 => widget.detailRect(),
    _ => widget.planRect(),
  };

  /// 2026-10-28: 그린 뒤 대상 위치를 다시 재고, 이 층 기준 좌표로 바뀌었으면 다시 그린다.
  void _measure(Duration _) {
    if (!mounted) return;
    final box = _layer.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    Rect? local(Rect? r) => r?.shift(-origin);
    final hole = local(_target());
    final detail = local(widget.detailRect());
    final panel = _panel.currentContext?.findRenderObject() as RenderBox?;
    final panelTop = panel == null || !panel.hasSize
        ? null
        : panel.localToGlobal(Offset.zero).dy - origin.dy;
    if (hole != _hole || detail != _detail || panelTop != _panelTop) {
      setState(() {
        _hole = hole;
        _detail = detail;
        _panelTop = panelTop;
      });
    }
  }

  /// 2026-10-28: 다음 단계로 간다. 마지막 단계면 완료로 닫는다.
  void _next() {
    if (_step == 2) {
      widget.onDone(CoachmarkRecord.completed);
      return;
    }
    setState(() {
      _step++;
      _hole = null;
    });
  }

  /// 2026-10-28: 건너뛰기·뒤로 가기로 닫는다.
  void _skip() => widget.onDone(CoachmarkRecord.skipped);

  /// 2026-10-28: 덮개·강조·연결선과 안내 면을 반환한다. 덮개는 아래 홈의 터치와 읽기를 막는다. 탭 화면 밖 층이라
  /// 글자 기본 모양을 받도록 투명 Material로 감싼다.
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback(_measure);
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 200);
    final (title, body) = _copy();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _skip();
      },
      child: LayoutBuilder(
        key: _layer,
        builder: (context, constraints) {
          final size = constraints.biggest;
          final detail = _detail;
          final panelBottom = detail == null
              ? PayseSpace.x2
              : size.height - detail.top + PayseSpace.x2;
          return BlockSemantics(
            child: Material(
              type: MaterialType.transparency,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {},
                      child: CustomPaint(
                        key: const ValueKey('coachmark-scrim'),
                        painter: CoachmarkPainter(
                          hole: _hole,
                          radius: _radius[_step],
                          connectTo: _step == 0 ? _panelTop : null,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: PayseSpace.x4,
                    right: PayseSpace.x4,
                    bottom: panelBottom,
                    child: AnimatedSwitcher(
                      key: _panel,
                      duration: duration,
                      child: _Panel(
                        key: ValueKey('coachmark-step-${_step + 1}'),
                        step: _step,
                        title: title,
                        body: body,
                        scale: scale,
                        onNext: _next,
                        onSkip: _step == 2 ? null : _skip,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 2026-10-28: 코치마크 안내 면. charcoal, 반경 16, 최소 높이 180·안쪽 20dp에 글자 배율 [scale]을 곱한다.
/// 제목 18/26 700 → 6dp → 설명 14/21 → (최소 16dp, 남는 높이) → 아래 줄 '건너뛰기'([onSkip]이 없으면 빈칸) · 'n / 3' · 흰 버튼.
class _Panel extends StatelessWidget {
  /// 2026-10-28: 단계 [step], 제목 [title], 설명 [body], 글자 배율 [scale], 다음 [onNext], 건너뛰기 [onSkip]으로 만든다.
  const _Panel({
    super.key,
    required this.step,
    required this.title,
    required this.body,
    required this.scale,
    required this.onNext,
    required this.onSkip,
  });

  final int step;
  final String title;
  final String body;
  final double scale;
  final VoidCallback onNext;
  final VoidCallback? onSkip;

  /// 2026-10-28: 안내 면을 반환한다. 화면 읽기 프로그램에는 '사용법 n / 3' 대화 상자로 알린다.
  @override
  Widget build(BuildContext context) {
    final skip = onSkip;
    return Semantics(
      key: const ValueKey('coachmark-panel'),
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: '사용법 ${step + 1} / 3',
      child: Container(
        constraints: BoxConstraints(minHeight: 180 * scale),
        padding: EdgeInsets.all(20 * scale),
        decoration: BoxDecoration(
          color: PayseColors.charcoal,
          borderRadius: BorderRadius.circular(PayseRadius.lg),
        ),
        child: IntrinsicHeight(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 18,
                    height: 26 / 18,
                    fontWeight: FontWeight.w700,
                    color: PayseColors.onCharcoal,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                body,
                style: const TextStyle(
                  fontSize: 14,
                  height: 21 / 14,
                  color: Color(0xD6FFFFFF),
                ),
              ),
              SizedBox(height: 16 * scale),
              const Spacer(),
              _actions(context, skip),
            ],
          ),
        ),
      ),
    );
  }

  static const TextStyle _skipStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle _countStyle = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: Color(0xB3FFFFFF),
  );
  static const TextStyle _nextStyle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
  );

  /// 2026-10-28: 아래 줄(건너뛰기 · n / 3 · 다음)을 반환한다. 안내 면 안쪽 폭에 한 줄로 들어가지 않으면(좁은 화면·큰 글자)
  /// 건너뛰기를 위 줄 왼쪽에, 'n / 3'과 버튼을 아래 줄 오른쪽에 둔다.
  Widget _actions(BuildContext context, VoidCallback? skip) {
    final scaler = MediaQuery.textScalerOf(context);
    double width(String text, TextStyle style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textScaler: scaler,
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final w = painter.width;
      painter.dispose();
      return w;
    }

    final count = '${step + 1} / 3';
    final label = step == 2 ? '시작하기' : '다음';
    final inner =
        MediaQuery.sizeOf(context).width - PayseSpace.x4 * 2 - 20 * scale * 2;
    final skipWidth = skip == null ? 0.0 : width('건너뛰기', _skipStyle);
    final needed =
        (skip == null ? 0 : (skipWidth < 48 ? 48 : skipWidth) + 12) +
        width(count, _countStyle) +
        14 +
        width(label, _nextStyle) +
        40;
    final skipButton = skip == null
        ? null
        : TextButton(
            key: const ValueKey('coachmark-skip'),
            onPressed: skip,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, PayseSize.touchMin),
              padding: EdgeInsets.zero,
              foregroundColor: const Color(0xC7FFFFFF),
              textStyle: _skipStyle,
            ),
            child: const Text('건너뛰기'),
          );
    final progress = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(count, semanticsLabel: '${step + 1}단계 중 3단계', style: _countStyle),
        const SizedBox(width: 14),
        FilledButton(
          key: const ValueKey('coachmark-next'),
          onPressed: onNext,
          style: FilledButton.styleFrom(
            minimumSize: const Size(0, PayseSize.touchMin),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            backgroundColor: PayseColors.background,
            foregroundColor: PayseColors.charcoal,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PayseRadius.sm),
            ),
            textStyle: _nextStyle,
          ),
          child: Text(label),
        ),
      ],
    );
    if (needed <= inner) {
      return Row(children: [?skipButton, const Spacer(), progress]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (skipButton != null)
          Align(alignment: Alignment.centerLeft, child: skipButton),
        Align(alignment: Alignment.centerRight, child: progress),
      ],
    );
  }
}

/// 2026-10-28: (테스트에서 강조 위치를 확인하려고 공개한다) 덮개에 강조 구멍 [hole](반경 [radius])을 뚫고 1.5px moonYellow 테두리를 그린다. [connectTo]가 있으면
/// 구멍 아래 가운데에서 그 높이(안내 면 위)까지 1.5px 수직선을 긋되, 둘이 붙거나 겹치면 긋지 않는다.
class CoachmarkPainter extends CustomPainter {
  /// 2026-10-28: 구멍 [hole], 반경 [radius], 연결선 끝 높이 [connectTo]로 만든다.
  const CoachmarkPainter({
    required this.hole,
    required this.radius,
    required this.connectTo,
  });

  final Rect? hole;
  final double radius;
  final double? connectTo;

  /// 2026-10-28: 덮개·테두리·연결선을 그린다. 구멍을 아직 재지 않았으면 덮개만 그린다.
  @override
  void paint(Canvas canvas, Size size) {
    final full = Path()..addRect(Offset.zero & size);
    final hole = this.hole;
    if (hole == null) {
      canvas.drawPath(full, Paint()..color = HomeCoachmark.scrim);
      return;
    }
    final rrect = RRect.fromRectAndRadius(hole, Radius.circular(radius));
    canvas.drawPath(
      Path.combine(PathOperation.difference, full, Path()..addRRect(rrect)),
      Paint()..color = HomeCoachmark.scrim,
    );
    final line = Paint()
      ..color = PayseColors.moonYellow
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawRRect(rrect, line);
    final end = connectTo;
    if (end != null && end - hole.bottom > PayseSpace.x2) {
      canvas.drawLine(
        Offset(hole.center.dx, hole.bottom),
        Offset(hole.center.dx, end),
        line,
      );
    }
  }

  /// 2026-10-28: 구멍·반경·연결선이 바뀌었으면 다시 그린다.
  @override
  bool shouldRepaint(CoachmarkPainter old) =>
      old.hole != hole || old.radius != radius || old.connectTo != connectTo;
}
