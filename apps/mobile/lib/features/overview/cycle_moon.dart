import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';
import 'home_skeleton.dart';

/// 2026-10-26: 홈 달의 밝은 면 비율(design.md §6 '홈 달'). 정상 주기 10% + 82% × 진행률, 입금 대기 100%.
/// 진행률은 계산 패키지 값을 그대로 받으며 이 함수는 표시 비율만 정한다. 주기를 모르면 null이다.
double? moonLitFraction({required double? progress, required bool awaiting}) {
  if (awaiting) return 1;
  if (progress == null) return null;
  return 0.10 + 0.82 * progress.clamp(0, 1);
}

/// 2026-10-26: 차콜 원 위에 밝은 면 [lit](0~1, 면적 비율)을 그린 달. [lit]가 null이면 위상 없는 점선 원이다.
class CycleMoon extends StatelessWidget {
  /// 2026-10-26: 밝은 면 비율 [lit]과 지름 [size]로 만든다.
  const CycleMoon({super.key, required this.lit, this.size = 39});

  final double? lit;
  final double size;

  /// 2026-10-26: 달 또는 점선 원을 반환한다. 접근성 트리에는 넣지 않는다.
  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _MoonPainter(lit)),
      ),
    );
  }
}

/// 2026-10-26: 로딩 중 큰 달 자리의 회색 원형 로딩 틀.
/// 2026-10-28: [SkeletonShimmer] 안이면 빛이 지나간다.
class MoonSkeleton extends StatelessWidget {
  /// 2026-10-26: 지름 [size]로 만든다.
  const MoonSkeleton({super.key, this.size = 39});

  final double size;

  /// 2026-10-26: 회색 원을 반환한다.
  @override
  Widget build(BuildContext context) => SkeletonBone.circle(size: size);
}

/// 2026-10-26: 새로고침 로딩 표시의 28px 달. 1.6초마다 초승달에서 보름까지 차오른 뒤 옅어지며 다시 시작한다.
/// 월급 주기와 무관하며, 동작 줄이기 설정이면 반달로 멈춘다.
class LoadingMoon extends StatefulWidget {
  /// 2026-10-26: 지름 [size]로 만든다.
  const LoadingMoon({super.key, this.size = 28});

  final double size;

  /// 2026-10-26: 애니메이션 상태 객체를 반환한다.
  @override
  State<LoadingMoon> createState() => _LoadingMoonState();
}

/// 2026-10-26: 반복 애니메이션을 소유한다.
class _LoadingMoonState extends State<LoadingMoon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  /// 2026-10-26: 동작 줄이기 설정에 따라 반복을 시작하거나 멈춘다.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  /// 2026-10-26: 애니메이션을 해제한다.
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 2026-10-26: 현재 위상의 달을 반환한다.
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return CycleMoon(lit: 0.5, size: widget.size);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final u = _controller.value;
        final double lit;
        final double opacity;
        if (u < 0.85) {
          lit = 0.08 + 0.92 * Curves.easeInOut.transform(u / 0.85);
          opacity = 1;
        } else {
          lit = 1;
          opacity = 1 - (u - 0.85) / 0.15;
        }
        return SizedBox.square(
          dimension: widget.size,
          child: CustomPaint(painter: _MoonPainter(lit, litOpacity: opacity)),
        );
      },
    );
  }
}

/// 2026-10-26: 달 그림. 밝은 면은 왼쪽 반원과 같은 높이의 타원 경계선으로 그려 면적 비율이 [lit]와 같다.
class _MoonPainter extends CustomPainter {
  /// 2026-10-26: 밝은 면 비율 [lit](null이면 점선 원)과 밝은 면 불투명도 [litOpacity]로 만든다.
  const _MoonPainter(this.lit, {this.litOpacity = 1});

  final double? lit;
  final double litOpacity;

  /// 2026-10-26: [canvas]에 달을 그린다.
  @override
  void paint(Canvas canvas, Size size) {
    final r = size.width / 2 - (lit == null ? 1 : 0);
    final c = Offset(size.width / 2, size.height / 2);
    final p = lit;
    if (p == null) {
      _dashedCircle(canvas, c, r);
      return;
    }
    canvas.drawCircle(c, r, Paint()..color = PayseColors.charcoal);
    final light = Paint()
      ..color = PayseColors.moonYellow.withValues(alpha: litOpacity);
    if (p >= 0.995) {
      canvas.drawCircle(c, r, light);
      return;
    }
    if (p <= 0.005) return;
    final top = Offset(c.dx, c.dy - r);
    final bottom = Offset(c.dx, c.dy + r);
    final rx = math.max(0.01, r * (1 - 2 * p).abs());
    final path = Path()
      ..moveTo(top.dx, top.dy)
      ..arcToPoint(bottom, radius: Radius.circular(r), clockwise: false)
      ..arcToPoint(top, radius: Radius.elliptical(rx, r), clockwise: p < 0.5)
      ..close();
    canvas.drawPath(path, light);
  }

  /// 2026-10-26: 위상 없는 자리 표시(1px 점선 원)를 그린다.
  void _dashedCircle(Canvas canvas, Offset c, double r) {
    final paint = Paint()
      ..color = const Color(0xFFB8BCC3)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    const dashes = 24;
    const sweep = 2 * math.pi / dashes;
    final rect = Rect.fromCircle(center: c, radius: r);
    for (var i = 0; i < dashes; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.55, false, paint);
    }
  }

  /// 2026-10-26: 비율·불투명도가 바뀌면 다시 그린다.
  @override
  bool shouldRepaint(_MoonPainter oldDelegate) =>
      oldDelegate.lit != lit || oldDelegate.litOpacity != litOpacity;
}
