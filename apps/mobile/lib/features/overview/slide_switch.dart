import 'package:flutter/material.dart';

import '../../shared/design/payse_tokens.dart';

/// 2026-10-28: 화면을 바꿔 끼울 때 앱의 기본 화면 이동(안드로이드 Material 3)과 같은 움직임을 쓴다. 새 화면은 폭의
/// 25% 오른쪽에서 들어오며 서서히 나타나고, 이전 화면은 25% 왼쪽으로 밀리며 빠르게 흐려진다(450ms). 화면 이동이
/// 아니라 바꿔 끼우는 곳(01-2 → 01-3, 4/4 → 시작 화면, 01-3 → 홈)도 앞선 화면들과 같은 느낌이 나게 한다.
/// 움직임 줄이기 설정이면 바로 바뀐다. [child]의 키가 바뀌어야 전환한다.
Widget slideSwitch(BuildContext context, Widget child) => ColoredBox(
  color: PayseColors.background,
  child: AnimatedSwitcher(
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 450),
    layoutBuilder: (current, previous) =>
        Stack(children: [...previous, ?current]),
    transitionBuilder: (widget, animation) => SwitchMotion(
      animation: animation,
      incomingFrom: const Offset(0.25, 0),
      outgoingTo: const Offset(-0.25, 0),
      curve: Curves.easeInOutCubicEmphasized,
      incomingFade: const Interval(0, 0.75),
      outgoingFade: const Interval(0, 0.25),
      child: widget,
    ),
    child: child,
  ),
);

/// 2026-10-28: 전환 상자 안 한 화면의 움직임. 들어오는 중(진행 방향)이면 [incomingFrom]에서 제자리로 오며 [incomingFade]
/// 구간에 나타나고, 나가는 중(역방향)이면 제자리에서 [outgoingTo]로 밀리며 [outgoingFade] 구간에 흐려진다.
/// 같은 키로 다시 들어와도 방향을 그때그때 정한다.
class SwitchMotion extends StatelessWidget {
  /// 2026-10-28: 전환 진행 [animation], 들어올 때 시작 위치 [incomingFrom], 나갈 때 끝 위치 [outgoingTo],
  /// 위치 곡선 [curve], 나타남·흐려짐 구간 [incomingFade]·[outgoingFade]로 만든다.
  const SwitchMotion({
    super.key,
    required this.animation,
    required this.incomingFrom,
    required this.outgoingTo,
    required this.child,
    this.curve = Curves.easeOutCubic,
    this.incomingFade = const Interval(0, 1),
    this.outgoingFade = const Interval(0, 1),
  });

  final Animation<double> animation;
  final Offset incomingFrom;
  final Offset outgoingTo;
  final Curve curve;
  final Curve incomingFade;
  final Curve outgoingFade;
  final Widget child;

  /// 2026-10-28: 현재 방향의 위치·불투명도를 반환한다.
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final outgoing = animation.status == AnimationStatus.reverse;
        final value = animation.value;
        final Offset offset;
        final double opacity;
        if (outgoing) {
          final elapsed = 1 - value;
          offset = Offset.lerp(
            Offset.zero,
            outgoingTo,
            curve.transform(elapsed),
          )!;
          opacity = 1 - outgoingFade.transform(elapsed);
        } else {
          offset = Offset.lerp(
            incomingFrom,
            Offset.zero,
            curve.transform(value),
          )!;
          opacity = incomingFade.transform(value);
        }
        return FractionalTranslation(
          translation: offset,
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: child,
    );
  }
}
