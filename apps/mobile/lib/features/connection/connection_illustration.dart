import 'dart:math';

import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';

/// 2026-10-23: 특정 기관이 아닌 통장 앞면·윗면·어두운 면과 카드 면(design.md §5 ConnectionIllustration).
const Color _bookFace = Color(0xFF5B7FB8);
const Color _bookTopFace = Color(0xFF7C9AC8);
const Color _bookDark = Color(0xFF3E5F94);
const Color _cardFace = Color(0xFF2F3237);

/// 2026-10-23: 연결 그림이 나타내는 상태.
enum ConnectionIllustrationState {
  /// 금융사를 찾는 중. 통장과 카드가 천천히 위아래로 움직인다.
  searching,

  /// 다 찾음. 체크 표시가 나타난다.
  found,

  /// 인터넷 연결 문제로 불러오지 못함. 회색 그림 + 오류색 표시.
  offline,

  /// 서비스 일시 불가로 받지 못함. 회색 그림 + 경고색 표시.
  unavailable,
}

/// 2026-10-23: 금융사 연결 진입 로딩·조회 실패 화면의 통장·카드 그림(design.md §5 ConnectionIllustration, 200×150).
/// 연결 화면에서만 쓰므로 공통 위젯이 아닌 연결 기능에 둔다.
/// 실제 로고가 아닌 플랫 그림이며 접근성 트리에서 제외한다. 기기의 움직임 줄이기 설정이 켜져 있으면 움직이지 않는다.
class ConnectionIllustration extends StatefulWidget {
  /// 2026-10-23: 그림 상태 [state]로 만든다.
  const ConnectionIllustration({super.key, required this.state});

  final ConnectionIllustrationState state;

  /// 2026-10-23: 움직임 상태 객체를 반환한다.
  @override
  State<ConnectionIllustration> createState() => _ConnectionIllustrationState();
}

/// 2026-10-23: 떠 있는 움직임(2.4초 반복)과 체크 표시 등장(0.45초)을 보관한다.
class _ConnectionIllustrationState extends State<ConnectionIllustration>
    with TickerProviderStateMixin {
  late final AnimationController _float = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );
  late final AnimationController _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 450),
  );

  /// 2026-10-23: 상태와 움직임 줄이기 설정에 맞춰 움직임을 시작·정지한다.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(null);
  }

  /// 2026-10-23: 상태가 바뀌면 움직임을 다시 맞춘다.
  @override
  void didUpdateWidget(covariant ConnectionIllustration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _sync(oldWidget.state);
  }

  /// 2026-10-23: 찾는 중이면 떠 있는 움직임을 반복하고, 다 찾음으로 바뀌면 체크 표시를 띄운다.
  /// 움직임 줄이기가 켜져 있으면 움직임 없이 마지막 모습을 보인다. [previous]는 이전 상태다.
  void _sync(ConnectionIllustrationState? previous) {
    final still = MediaQuery.disableAnimationsOf(context);
    if (widget.state == ConnectionIllustrationState.searching && !still) {
      if (!_float.isAnimating) _float.repeat();
    } else {
      _float.stop();
      _float.value = 0;
    }
    if (widget.state != ConnectionIllustrationState.found) {
      _pop.value = 0;
    } else if (still) {
      _pop.value = 1;
    } else if (previous != ConnectionIllustrationState.found) {
      _pop.forward(from: 0);
    }
  }

  /// 2026-10-23: 움직임 컨트롤러를 폐기한다.
  @override
  void dispose() {
    _float.dispose();
    _pop.dispose();
    super.dispose();
  }

  /// 2026-10-23: 그림을 반환한다.
  @override
  Widget build(BuildContext context) {
    final muted =
        widget.state == ConnectionIllustrationState.offline ||
        widget.state == ConnectionIllustrationState.unavailable;
    return ExcludeSemantics(
      child: SizedBox(
        width: 200,
        height: 150,
        child: AnimatedBuilder(
          animation: Listenable.merge([_float, _pop]),
          builder: (context, _) {
            final t = _float.value * 2 * pi;
            return Stack(
              clipBehavior: Clip.none,
              children: [
                _box(36, 132, 128, 12, PayseColors.surfaceMuted, radius: 6),
                Transform.translate(
                  offset: Offset(0, -4 + 4 * cos(t)),
                  child: Stack(children: _book(muted)),
                ),
                Transform.translate(
                  offset: Offset(0, -2 - 4 * cos(t + 0.8)),
                  child: Transform.rotate(
                    angle: -8 * pi / 180,
                    origin: const Offset(40, 12),
                    child: Stack(children: _card(muted)),
                  ),
                ),
                ?_badge(),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 2026-10-23: 통장 그림 조각을 반환한다. [muted]면 회색이다.
  List<Widget> _book(bool muted) => [
    _box(
      46,
      34,
      78,
      96,
      muted ? PayseColors.dividerRow : InstitutionTones.bookLeaf,
    ),
    _box(40, 28, 78, 96, muted ? PayseColors.dividerSection : _bookFace),
    _box(40, 28, 78, 22, muted ? PayseColors.border : _bookTopFace),
    _box(
      54,
      70,
      40,
      12,
      muted ? InstitutionTones.bookLeaf : InstitutionTones.bookLabel,
      radius: 3,
    ),
    if (!muted) ...[
      _box(54, 92, 50, 4, Colors.white.withValues(alpha: 0.55), radius: 2),
      _box(54, 102, 34, 4, Colors.white.withValues(alpha: 0.55), radius: 2),
    ],
  ];

  /// 2026-10-23: 카드 그림 조각을 반환한다. [muted]면 회색이다.
  List<Widget> _card(bool muted) => [
    _box(104, 64, 72, 46, muted ? PayseColors.scheduled : _cardFace, radius: 7),
    _box(
      104,
      74,
      72,
      9,
      muted ? PayseColors.borderStrong : InstitutionTones.cardStripe,
      radius: 0,
    ),
    if (!muted) _box(114, 90, 14, 11, InstitutionTones.cardChip, radius: 2),
  ];

  /// 2026-10-23: 오른쪽 위 상태 표시를 반환한다. 찾는 중이면 없다.
  Widget? _badge() {
    final (Color fill, Color? ring, Widget mark) = switch (widget.state) {
      ConnectionIllustrationState.searching => (
        Colors.transparent,
        null,
        const SizedBox.shrink(),
      ),
      ConnectionIllustrationState.found => (
        PayseColors.charcoal,
        null,
        const Icon(
          Icons.check_rounded,
          size: 26,
          color: PayseColors.moonYellow,
        ),
      ),
      ConnectionIllustrationState.offline => (
        PayseColors.errorContainer,
        PayseColors.errorBorder,
        const Icon(Icons.wifi_off_rounded, size: 22, color: PayseColors.error),
      ),
      ConnectionIllustrationState.unavailable => (
        PayseColors.warningContainer,
        PayseColors.warningBorder,
        const Icon(
          Icons.schedule_rounded,
          size: 22,
          color: PayseColors.warning,
        ),
      ),
    };
    if (widget.state == ConnectionIllustrationState.searching) return null;
    final badge = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: ring == null ? null : Border.all(color: ring, width: 1.5),
      ),
      alignment: Alignment.center,
      child: mark,
    );
    return Positioned(
      left: 130,
      top: 16,
      child: widget.state == ConnectionIllustrationState.found
          ? ScaleTransition(
              scale: CurvedAnimation(parent: _pop, curve: Curves.easeOutBack),
              child: badge,
            )
          : badge,
    );
  }

  /// 2026-10-23: 왼쪽 위 ([x], [y])에 [w]×[h] 크기, 색 [color], 반경 [radius]의 면을 반환한다.
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

/// 2026-10-23: 진입 로딩 단계 줄의 '은행'·'카드사' 묶음 표시(40×30). 특정 기관 색이 아닌 그림 색을 쓴다.
/// 장식이므로 접근성 트리에서 제외한다.
class ConnectionGroupMark extends StatelessWidget {
  /// 2026-10-23: 카드사 묶음이면 [card]가 true다.
  const ConnectionGroupMark({super.key, required this.card});

  final bool card;

  /// 2026-10-23: 통장(뒷장·앞표지·이름표)이나 카드(면·자기띠·칩)를 반환한다.
  @override
  Widget build(BuildContext context) {
    Widget box(double x, double y, double w, double h, Color c, double r) =>
        Positioned(
          left: x,
          top: y,
          child: Container(
            width: w,
            height: h,
            decoration: BoxDecoration(
              color: c,
              borderRadius: BorderRadius.circular(r),
            ),
          ),
        );
    return ExcludeSemantics(
      child: SizedBox(
        width: 40,
        height: 30,
        child: Stack(
          children: card
              ? [
                  box(4, 5, 32, 21, _cardFace, 3),
                  box(4, 10, 32, 4, InstitutionTones.cardStripe, 0),
                  box(8, 17, 7, 5, InstitutionTones.cardChip, 1),
                ]
              : [
                  box(9, 4, 22, 24, InstitutionTones.bookLeaf, 3),
                  box(6, 2, 22, 24, _bookFace, 3),
                  box(6, 2, 22, 6, _bookDark, 3),
                  box(10, 12, 12, 4, InstitutionTones.bookLabel, 1),
                ],
        ),
      ),
    );
  }
}
