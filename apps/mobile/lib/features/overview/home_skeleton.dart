import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';

/// 2026-10-28: 홈 로딩 틀의 빛 지나감(design.md §6). 안의 [SkeletonBone]들이 이 영역 좌표로 같은 띠를 나눠 그려
/// 옅은 빛이 왼쪽에서 오른쪽으로 한 번에 지나간다. 동작 줄이기 설정이면 움직이지 않는다.
class SkeletonShimmer extends StatefulWidget {
  /// 2026-10-28: 로딩 틀을 담은 [child]로 만든다.
  const SkeletonShimmer({super.key, required this.child});

  final Widget child;

  /// 2026-10-28: 빛이 한 번 지나가는 시간.
  static const Duration period = Duration(milliseconds: 1500);

  /// 2026-10-28: 애니메이션 상태 객체를 반환한다.
  @override
  State<SkeletonShimmer> createState() => _SkeletonShimmerState();
}

/// 2026-10-28: 반복 애니메이션과 영역 좌표를 소유한다.
class _SkeletonShimmerState extends State<SkeletonShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: SkeletonShimmer.period,
  );

  /// 2026-10-28: 동작 줄이기 설정에 맞춰 반복을 켜거나 끈다.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  /// 2026-10-28: 애니메이션을 정리한다.
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 2026-10-28: 자식에 애니메이션 범위를 내려준다.
  @override
  Widget build(BuildContext context) {
    return _ShimmerScope(
      animation: _controller,
      moving: !MediaQuery.disableAnimationsOf(context),
      area: this,
      child: widget.child,
    );
  }

  /// 2026-10-28: 이 영역의 그림 상자. 아직 배치 전이면 null이다.
  RenderBox? get box {
    final object = context.findRenderObject();
    return object is RenderBox && object.hasSize ? object : null;
  }
}

/// 2026-10-28: [SkeletonShimmer] 아래로 애니메이션·영역을 전달한다.
class _ShimmerScope extends InheritedWidget {
  /// 2026-10-28: 진행 [animation], 움직임 여부 [moving], 영역 [area]로 만든다.
  const _ShimmerScope({
    required this.animation,
    required this.moving,
    required this.area,
    required super.child,
  });

  final Animation<double> animation;
  final bool moving;
  final _SkeletonShimmerState area;

  /// 2026-10-28: 움직임 여부가 바뀌면 다시 그린다.
  @override
  bool updateShouldNotify(_ShimmerScope oldWidget) =>
      moving != oldWidget.moving;
}

/// 2026-10-28: 회색 로딩 틀 한 조각. 글자 틀은 원본과 같은 글자 모양·견본 문구로 크기를 정해 로딩 전후에
/// 자리가 움직이지 않게 하고, 줄 높이 안 글자 부분만 칠한다.
class SkeletonBone extends StatelessWidget {
  /// 2026-10-28: 폭 [width](null이면 가능한 만큼)·높이 [height]·반경 [radius]의 상자 틀.
  const SkeletonBone.box({
    super.key,
    this.width,
    required double this.height,
    this.radius = 4,
  }) : text = null,
       style = null;

  /// 2026-10-28: 지름 [size]의 원 틀.
  const SkeletonBone.circle({super.key, required double size})
    : width = size,
      height = size,
      radius = size / 2,
      text = null,
      style = null;

  /// 2026-10-28: 원본 글자 모양 [style]로 견본 [text]를 한 줄로 놓았을 때와 같은 크기의 글자 틀.
  const SkeletonBone.text(
    InlineSpan this.text, {
    super.key,
    required TextStyle this.style,
    this.radius = 4,
  }) : width = null,
       height = null;

  final double? width;
  final double? height;
  final double radius;
  final InlineSpan? text;
  final TextStyle? style;

  /// 2026-10-28: 글자 줄 높이 중 칠하는 비율(위아래 여백을 남겨 글자 크기만큼 보이게 함).
  static const double glyphShare = 0.8;

  /// 2026-10-28: 틀을 반환한다. 접근성 트리에는 넣지 않는다.
  @override
  Widget build(BuildContext context) {
    final bone = _Fill(radius: radius);
    final span = text;
    final textStyle = style;
    if (span == null || textStyle == null) {
      return ExcludeSemantics(
        child: SizedBox(width: width, height: height, child: bone),
      );
    }
    final lineHeight = textStyle.height ?? 1.2;
    return ExcludeSemantics(
      child: Stack(
        children: [
          Text.rich(
            span,
            maxLines: 1,
            softWrap: false,
            style: textStyle.copyWith(color: Colors.transparent),
          ),
          Positioned.fill(
            child: Center(
              child: FractionallySizedBox(
                widthFactor: 1,
                heightFactor: (glyphShare / lineHeight).clamp(0, 1),
                child: bone,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-10-28: 틀 바탕. [SkeletonShimmer] 안이고 움직일 수 있으면 영역 좌표의 빛 띠를 겹쳐 그린다.
class _Fill extends StatelessWidget {
  /// 2026-10-28: 반경 [radius]로 만든다.
  const _Fill({required this.radius});

  final double radius;

  /// 2026-10-28: 회색 바탕 또는 빛이 지나가는 바탕을 반환한다.
  @override
  Widget build(BuildContext context) {
    final plain = DecoratedBox(
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
    final scope = context.dependOnInheritedWidgetOfExactType<_ShimmerScope>();
    if (scope == null || !scope.moving) return plain;
    return AnimatedBuilder(
      animation: scope.animation,
      child: plain,
      builder: (context, child) {
        final area = scope.area.box;
        final self = context.findRenderObject();
        if (area == null || self is! RenderBox || !self.hasSize) return child!;
        final origin = self.localToGlobal(Offset.zero, ancestor: area);
        final t = scope.animation.value;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (_) => LinearGradient(
            colors: const [
              PayseColors.surfaceMuted,
              PayseColors.skeletonHighlight,
              PayseColors.surfaceMuted,
            ],
            stops: const [0.35, 0.5, 0.65],
            begin: const Alignment(-1, -0.3),
            end: const Alignment(1, 0.3),
            transform: _Slide(t * 2 - 1),
          ).createShader(Offset(-origin.dx, -origin.dy) & area.size),
          child: child,
        );
      },
    );
  }
}

/// 2026-10-28: 빛 띠를 영역 폭의 [share]배만큼 가로로 옮긴다.
class _Slide extends GradientTransform {
  /// 2026-10-28: 이동 비율 [share]로 만든다.
  const _Slide(this.share);

  final double share;

  /// 2026-10-28: 가로 이동 행렬을 반환한다.
  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * share, 0, 0);
}
