import 'dart:math';

import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';

/// 2026-11-04: 통장 앞면·윗면(진입 로딩 그림과 같은 색, design.md §5 ConnectionIllustration).
const Color _bookFace = Color(0xFF5B7FB8);
const Color _bookTopFace = Color(0xFF7C9AC8);

/// 2026-11-04: 분석 대기 그림이 나타내는 장면. 기다리는 세 장면은 진행 단계가 아니라 앱 시계로 바꾸는 연출이다.
enum AnalysisArt {
  /// 거래 정리. 거래표 줄이 차례로 채워진다.
  sorting,

  /// 반복 찾기. 돋보기가 줄을 훑고 2·4번째 점이 옐로다.
  finding,

  /// 첫 계산 준비. 그림이 천천히 떠 있다.
  preparing,

  /// 끝·반복 후보 있음. 차콜 원 + 옐로 체크.
  done,

  /// 끝·반복 후보 없음. 체크는 같고 옐로 점이 없다.
  empty,

  /// 끝·내용 분석을 마치지 못함. 경고색 원 + 시계, 옐로 점 없음.
  unfinished,
}

/// 2026-11-04: 첫 계산 전 분석 대기 화면의 통장·거래표 그림(200×150). 연결 흐름에서만 쓴다.
/// 접근성 트리에서 제외하며 기기의 움직임 줄이기 설정이 켜져 있으면 움직이지 않고 마지막 모습을 보인다.
class AnalysisIllustration extends StatefulWidget {
  /// 2026-11-04: 장면 [art]로 만든다.
  const AnalysisIllustration({super.key, required this.art});

  final AnalysisArt art;

  /// 2026-11-04: 움직임 상태 객체를 반환한다.
  @override
  State<AnalysisIllustration> createState() => _AnalysisIllustrationState();
}

/// 2026-11-04: 떠 있음·줄 채움(2.4초 반복), 돋보기 훑기(2.8초 왕복), 끝 표시 등장(0.45초)을 보관한다.
class _AnalysisIllustrationState extends State<AnalysisIllustration>
    with TickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  bool get _waiting => switch (widget.art) {
    AnalysisArt.sorting || AnalysisArt.finding || AnalysisArt.preparing => true,
    _ => false,
  };

  /// 2026-11-04: 장면과 움직임 줄이기 설정에 맞춰 움직임을 시작·정지한다.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(null);
  }

  /// 2026-11-04: 장면이 바뀌면 움직임을 다시 맞춘다.
  @override
  void didUpdateWidget(covariant AnalysisIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.art != widget.art) _sync(oldWidget.art);
  }

  /// 2026-11-04: 기다리는 장면이면 반복 움직임을, 끝 장면이면 표시 등장을 맞춘다. [previous]는 이전 장면이다.
  void _sync(AnalysisArt? previous) {
    final still = MediaQuery.disableAnimationsOf(context);
    if (_waiting && !still) {
      if (!_loop.isAnimating) _loop.repeat();
    } else {
      _loop.stop();
      _loop.value = 0;
    }
    if (widget.art == AnalysisArt.finding && !still) {
      if (!_scan.isAnimating) _scan.repeat(reverse: true);
    } else {
      _scan.stop();
      _scan.value = 0;
    }
    if (_waiting) {
      _pop.value = 0;
    } else if (still) {
      _pop.value = 1;
    } else if (previous != widget.art) {
      _pop.forward(from: 0);
    }
  }

  /// 2026-11-04: 움직임 컨트롤러를 폐기한다.
  @override
  void dispose() {
    _loop.dispose();
    _scan.dispose();
    _pop.dispose();
    super.dispose();
  }

  /// 2026-11-04: 그림을 반환한다.
  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox(
        width: 200,
        height: 150,
        child: AnimatedBuilder(
          animation: Listenable.merge([_loop, _scan, _pop]),
          builder: (context, _) {
            final t = _loop.value;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                _box(36, 132, 128, 12, PayseColors.surfaceMuted, radius: 6),
                Transform.translate(
                  offset: Offset(0, _lift(t + 0.25)),
                  child: Stack(children: _book()),
                ),
                Transform.translate(
                  offset: Offset(0, _lift(t)),
                  child: Stack(children: _sheet(t)),
                ),
                if (widget.art == AnalysisArt.finding) _lens(),
                ?_badge(),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 2026-11-04: 2.4초 주기 [t](0~1, 넘으면 나머지)의 떠오름 높이(0 → −8 → 0dp). 기다리는 장면이 아니면 0이다.
  double _lift(double t) {
    if (!_waiting || !_loop.isAnimating) return 0;
    return -4 * (1 - cos(2 * pi * t));
  }

  /// 2026-11-04: 통장 조각을 반환한다.
  List<Widget> _book() => [
    _box(30, 46, 46, 58, InstitutionTones.bookLeaf, radius: 6),
    _box(24, 40, 46, 58, _bookFace, radius: 6),
    _box(24, 40, 46, 14, _bookTopFace, radius: 6),
    _box(32, 66, 24, 8, InstitutionTones.bookLabel, radius: 2),
  ];

  /// 2026-11-04: 거래표 조각을 반환한다. [t]는 줄 채움 주기 위치다.
  List<Widget> _sheet(double t) {
    final hits = switch (widget.art) {
      AnalysisArt.finding || AnalysisArt.preparing || AnalysisArt.done => true,
      _ => false,
    };
    return [
      _box(64, 24, 90, 108, InstitutionTones.bookLeaf),
      _box(58, 18, 90, 108, PayseColors.surfaceMuted),
      Positioned(
        left: 58,
        top: 18,
        child: Container(
          width: 90,
          height: 20,
          decoration: const BoxDecoration(
            color: _bookTopFace,
            borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
          ),
        ),
      ),
      for (final (i, y) in const [50.0, 68.0, 86.0, 104.0].indexed)
        _row(
          y,
          hits && (i == 1 || i == 3)
              ? PayseColors.moonYellow
              : PayseColors.scheduled,
          widget.art == AnalysisArt.sorting && _loop.isAnimating
              ? _rowFill(t - i * 0.25 / 2.4)
              : (scale: 1, opacity: 1),
        ),
    ];
  }

  /// 2026-11-04: 줄 채움 주기 위치 [t](넘으면 나머지)의 가로 채움·불투명도. 처음 25%에 왼쪽부터 채우고
  /// 85% 뒤 흐려진다.
  static ({double scale, double opacity}) _rowFill(double t) {
    final p = t - t.floorToDouble();
    if (p < 0.25) {
      final v = Curves.easeOut.transform(p / 0.25);
      return (scale: v, opacity: v);
    }
    if (p < 0.85) return (scale: 1, opacity: 1);
    return (scale: 1, opacity: 1 - (p - 0.85) / 0.15);
  }

  /// 2026-11-04: [y] 위치의 거래 한 줄(점 [dot] 색, 채움 [fill])을 반환한다.
  Widget _row(double y, Color dot, ({double scale, double opacity}) fill) {
    return Positioned(
      left: 70,
      top: y,
      child: Opacity(
        opacity: fill.opacity,
        child: Transform.scale(
          scaleX: fill.scale,
          scaleY: 1,
          alignment: Alignment.centerLeft,
          child: SizedBox(
            width: 70,
            height: 8,
            child: Stack(
              children: [
                _box(0, 0, 8, 8, dot, radius: 4),
                _box(14, 2, 36, 4, PayseColors.dividerSection, radius: 2),
                _box(56, 2, 14, 4, InstitutionTones.bookLeaf, radius: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 2026-11-04: 줄 위를 오가는 돋보기를 반환한다.
  Widget _lens() {
    final p = Curves.easeInOut.transform(_scan.value);
    return Positioned(
      left: 96 - 26 * p,
      top: 44 + 40 * p,
      child: SizedBox(
        width: 40,
        height: 52,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.35),
                border: Border.all(color: PayseColors.charcoal, width: 4),
              ),
            ),
            Positioned(
              left: 29,
              top: 26,
              child: Transform.rotate(
                angle: -pi / 4,
                alignment: Alignment.topCenter,
                child: Container(
                  width: 6,
                  height: 18,
                  decoration: BoxDecoration(
                    color: PayseColors.charcoal,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 2026-11-04: 끝 장면의 오른쪽 위 표시를 반환한다. 기다리는 장면이면 없다.
  Widget? _badge() {
    if (_waiting) return null;
    final unfinished = widget.art == AnalysisArt.unfinished;
    return Positioned(
      left: 130,
      top: 12,
      child: ScaleTransition(
        scale: CurvedAnimation(parent: _pop, curve: Curves.easeOutBack),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: unfinished
                ? PayseColors.warningContainer
                : PayseColors.charcoal,
            shape: BoxShape.circle,
            border: unfinished
                ? Border.all(color: PayseColors.warningBorder, width: 1.5)
                : null,
          ),
          alignment: Alignment.center,
          child: unfinished
              ? const Icon(
                  Icons.schedule_rounded,
                  size: 22,
                  color: PayseColors.warning,
                )
              : const Icon(
                  Icons.check_rounded,
                  size: 26,
                  color: PayseColors.moonYellow,
                ),
        ),
      ),
    );
  }

  /// 2026-11-04: 왼쪽 위 ([x], [y])에 [w]×[h] 크기, 색 [color], 반경 [radius]의 면을 반환한다.
  static Widget _box(
    double x,
    double y,
    double w,
    double h,
    Color color, {
    double radius = 8,
  }) => Positioned(
    left: x,
    top: y,
    child: Container(
      width: w,
      height: h,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
  );
}

/// 2026-11-04: 분석 결과 줄의 표시 종류(40×30).
enum AnalysisMarkKind {
  /// 거래표(거래 n건 확인).
  sheet,

  /// 돋보기(반복 후보).
  lens,

  /// 남겨둘 돈·예정 지출·쓸 수 있는 돈 3색 막대(첫 계산).
  calculation,
}

/// 2026-11-04: 분석 결과 줄 앞의 작은 그림(40×30). 장식이므로 접근성 트리에서 제외한다.
class AnalysisMark extends StatelessWidget {
  /// 2026-11-04: 표시 종류 [kind]로 만든다.
  const AnalysisMark({super.key, required this.kind});

  final AnalysisMarkKind kind;

  /// 2026-11-04: 종류에 맞는 그림을 반환한다.
  @override
  Widget build(BuildContext context) {
    Widget box(
      double x,
      double y,
      double w,
      double h,
      Color c,
      BorderRadius r,
    ) => Positioned(
      left: x,
      top: y,
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(color: c, borderRadius: r),
      ),
    );
    BorderRadius all(double r) => BorderRadius.circular(r);
    final children = switch (kind) {
      AnalysisMarkKind.sheet => [
        box(10, 3, 22, 25, InstitutionTones.bookLeaf, all(3)),
        box(7, 1, 22, 25, PayseColors.surfaceMuted, all(3)),
        box(7, 1, 22, 6, _bookTopFace, all(3)),
        box(10, 11, 4, 4, PayseColors.scheduled, all(2)),
        box(16, 12, 10, 2, PayseColors.dividerSection, all(1)),
        box(10, 18, 4, 4, PayseColors.scheduled, all(2)),
        box(16, 19, 10, 2, PayseColors.dividerSection, all(1)),
      ],
      AnalysisMarkKind.lens => [
        Positioned(
          left: 8,
          top: 2,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: PayseColors.charcoal, width: 3),
            ),
          ),
        ),
        box(14, 8, 8, 8, PayseColors.moonYellow, all(4)),
        Positioned(
          left: 25,
          top: 19,
          child: Transform.rotate(
            angle: -pi / 4,
            alignment: Alignment.topCenter,
            child: Container(
              width: 4,
              height: 11,
              decoration: BoxDecoration(
                color: PayseColors.charcoal,
                borderRadius: all(2),
              ),
            ),
          ),
        ),
      ],
      AnalysisMarkKind.calculation => [
        box(
          4,
          12,
          10,
          6,
          PayseColors.reserve,
          const BorderRadius.horizontal(left: Radius.circular(3)),
        ),
        box(17, 12, 8, 6, PayseColors.scheduled, BorderRadius.zero),
        box(
          28,
          12,
          8,
          6,
          PayseColors.available,
          const BorderRadius.horizontal(right: Radius.circular(3)),
        ),
      ],
    };
    return ExcludeSemantics(
      child: SizedBox(
        width: 40,
        height: 30,
        child: Stack(clipBehavior: Clip.none, children: children),
      ),
    );
  }
}
