import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';

/// 2026-10-26: 02-2 구성 바 상태(design.md §6 구성 바). 비율을 정확히 설명할 수 있을 때만 바를 그린다.
enum CompositionBarState {
  /// 2026-10-26: U>0. 모아둘 돈→예정 지출→쓸 수 있는 돈.
  positive,

  /// 2026-10-26: U=0. 노란 구간 없이 모아둘 돈·예정 지출.
  zero,

  /// 2026-10-26: U<0이고 B>0. 바 길이는 빼야 할 돈 기준이고 잔액 위치·부족 구간을 표시한다.
  shortfall,

  /// 2026-10-26: B≤0. 바·범례·색 칩 없이 영수증만 보인다.
  noBalance,

  /// 2026-10-26: U를 계산하지 못했다. 바 대신 정보 부족 안내를 보인다.
  insufficient,
}

/// 2026-10-26: 계산 결과 [result]의 구성 바 상태를 반환한다. 부호만 비교하고 금액을 새로 계산하지 않는다.
CompositionBarState compositionBarStateOf(calc.CurrentAmountResult result) {
  final u = result.u;
  if (u == null) return CompositionBarState.insufficient;
  if (result.b! <= 0) return CompositionBarState.noBalance;
  if (u > 0) return CompositionBarState.positive;
  if (u == 0) return CompositionBarState.zero;
  return CompositionBarState.shortfall;
}

/// 2026-10-26: 바·범례가 보이는 상태면 true. 장부 항목의 색 칩도 이때만 붙인다.
bool showsCompositionBar(CompositionBarState state) => switch (state) {
  CompositionBarState.positive ||
  CompositionBarState.zero ||
  CompositionBarState.shortfall => true,
  CompositionBarState.noBalance || CompositionBarState.insufficient => false,
};

/// 2026-10-26: 02-2 금액 구성 바와 범례. 높이 6·간격 3·양 끝 반경 3dp, 테두리·그림자 없음.
/// 구간 길이는 계산 결과의 R−O·E·U를 그대로 비율로 쓰며 0원 구간과 그 범례는 생략한다.
class CompositionBar extends StatelessWidget {
  /// 2026-10-26: U가 있고 B>0인 계산 결과 [result]로 만든다. 홈은 [showLegend]를 false로 넘겨 바만 보인다.
  /// 2026-10-28: [reveal](0→1)을 주면 구간을 왼쪽부터 차례로 늘리고 범례를 차례로 나타낸다(01-3 4/4).
  const CompositionBar({
    super.key,
    required this.result,
    this.showLegend = true,
    this.reveal,
  });

  final calc.CurrentAmountResult result;
  final bool showLegend;
  final Animation<double>? reveal;

  /// 2026-10-26: 상태에 맞는 바·범례를 반환한다. 바를 그리지 않는 상태면 빈 상자다.
  @override
  Widget build(BuildContext context) {
    final state = compositionBarStateOf(result);
    final segments = <(String, Color, int)>[
      ('모아둘 돈', PayseColors.reserve, result.rEff!),
      ('예정 지출', PayseColors.scheduled, result.e!),
      if (state == CompositionBarState.positive)
        ('쓸 수 있는 돈', PayseColors.available, result.u!),
    ].where((s) => s.$3 > 0).toList();
    if (!showsCompositionBar(state) || segments.isEmpty) {
      return const SizedBox.shrink();
    }
    final bar = _SegmentRow(segments: segments, reveal: reveal);
    return Column(
      key: const ValueKey('composition-bar'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (state == CompositionBarState.shortfall)
          _ShortfallBar(
            key: const ValueKey('shortfall-bar'),
            result: result,
            bar: bar,
          )
        else
          Semantics(
            label: '계좌 잔액을 나눈 금액 구성',
            child: Padding(
              padding: const EdgeInsets.only(top: PayseSpace.x6),
              child: bar,
            ),
          ),
        if (showLegend) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: PayseSpace.x4,
            runSpacing: PayseSpace.x1,
            children: [
              for (var i = 0; i < segments.length; i++)
                ExcludeSemantics(
                  child: _Staged(
                    reveal: reveal,
                    interval: _labelInterval(i, segments.length),
                    child: ColorChipLabel(
                      label: segments[i].$1,
                      color: segments[i].$2,
                      style: DetailTypography.secondary,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// 2026-10-26: 6dp 구간 막대. 구간 사이 3dp, 양 끝만 3dp 둥글게.
class _SegmentRow extends StatelessWidget {
  /// 2026-10-26: (이름, 색, 비율로 쓸 금액) 목록 [segments]로 만든다. 금액은 모두 1원 이상이다.
  /// 2026-10-28: [reveal]이 있으면 각 구간이 제 자리 안에서 왼쪽부터 늘어난다.
  const _SegmentRow({required this.segments, this.reveal});

  final List<(String, Color, int)> segments;
  final Animation<double>? reveal;

  /// 2026-10-26: 구간 막대를 반환한다.
  @override
  Widget build(BuildContext context) {
    const radius = Radius.circular(3);
    return SizedBox(
      height: 6,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < segments.length; i++) ...[
            if (i > 0) const SizedBox(width: 3),
            Expanded(
              flex: segments[i].$3,
              child: _Grow(
                reveal: reveal,
                interval: _segmentInterval(i, segments.length),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: segments[i].$2,
                    borderRadius: BorderRadius.horizontal(
                      left: i == 0 ? radius : Radius.zero,
                      right: i == segments.length - 1 ? radius : Radius.zero,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 2026-10-28: [count]개 중 [index]번째 구간이 늘어나는 구간(전체 0~1 중). 구간은 차례로 이어진다.
Interval _segmentInterval(int index, int count) {
  final span = 0.8 / count;
  return Interval(index * span, (index + 1) * span, curve: Curves.easeOutCubic);
}

/// 2026-10-28: [index]번째 범례가 나타나는 구간. 해당 구간이 반쯤 늘어난 뒤 시작한다.
Interval _labelInterval(int index, int count) {
  final span = 0.8 / count;
  final start = index * span + span / 2;
  return Interval(start, (start + 0.2).clamp(0, 1), curve: Curves.easeOut);
}

/// 2026-10-28: [reveal]의 [interval] 동안 [child]를 제 자리 안에서 왼쪽부터 늘린다. [reveal]이 없으면 그대로 둔다.
class _Grow extends StatelessWidget {
  /// 2026-10-28: 진행 [reveal], 구간 [interval], 내용 [child]로 만든다.
  const _Grow({
    required this.reveal,
    required this.interval,
    required this.child,
  });

  final Animation<double>? reveal;
  final Interval interval;
  final Widget child;

  /// 2026-10-28: 늘어나는 내용을 반환한다.
  @override
  Widget build(BuildContext context) {
    final r = reveal;
    if (r == null) return child;
    return AnimatedBuilder(
      animation: r,
      builder: (context, child) => Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: interval.transform(r.value),
          heightFactor: 1,
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 2026-10-28: [reveal]의 [interval] 동안 [child]를 서서히 나타낸다. [reveal]이 없으면 그대로 둔다.
class _Staged extends StatelessWidget {
  /// 2026-10-28: 진행 [reveal], 구간 [interval], 내용 [child]로 만든다.
  const _Staged({
    required this.reveal,
    required this.interval,
    required this.child,
  });

  final Animation<double>? reveal;
  final Interval interval;
  final Widget child;

  /// 2026-10-28: 나타나는 내용을 반환한다.
  @override
  Widget build(BuildContext context) {
    final r = reveal;
    if (r == null) return child;
    return FadeTransition(
      opacity: CurvedAnimation(parent: r, curve: interval),
      child: child,
    );
  }
}

/// 2026-10-26: 음수·잔액 양수 상태(③). 바 전체는 빼야 할 돈, 세로선은 계좌 잔액 위치, 오류색 선은 부족 구간이다.
class _ShortfallBar extends StatelessWidget {
  /// 2026-10-26: 계산 결과 [result]와 구간 막대 [bar]로 만든다.
  const _ShortfallBar({super.key, required this.result, required this.bar});

  final calc.CurrentAmountResult result;
  final Widget bar;

  /// 2026-10-26: 바 위 합계·잔액 표시, 세로선, 부족 구간과 부족액을 반환한다.
  @override
  Widget build(BuildContext context) {
    final b = result.b!;
    final deduction = result.deductionKrw!;
    final shortfall = -result.u!;
    final fraction = b / deduction;
    final strong = DetailTypography.secondary.copyWith(
      fontWeight: FontWeight.w600,
      color: PayseColors.textPrimary,
    );
    return Semantics(
      label:
          '막대 전체는 모아둘 돈과 예정 지출의 합 ${spokenKrw(deduction)}이고, '
          '계좌 잔액 ${spokenKrw(b)} 위치 뒤로 ${spokenKrw(shortfall)}이 부족해요',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: PayseSpace.x5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('모아둘 돈 + 예정 지출 ${formatKrw(deduction)}', style: strong),
              const SizedBox(height: PayseSpace.x1),
              AnchoredLabel(
                fraction: fraction,
                child: Text('계좌 잔액 ${formatKrw(b)}', style: strong),
              ),
              SizedBox(
                height: 18,
                child: Stack(
                  children: [
                    Positioned(left: 0, right: 0, top: 6, child: bar),
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment(fraction * 2 - 1, 0),
                        child: const SizedBox(
                          width: 2,
                          height: 16,
                          child: ColoredBox(color: PayseColors.charcoal),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                children: [
                  Expanded(flex: b, child: const SizedBox.shrink()),
                  Expanded(
                    flex: shortfall,
                    child: const SizedBox(
                      height: 2,
                      child: ColoredBox(color: PayseColors.error),
                    ),
                  ),
                ],
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Text(
                  '${formatKrw(shortfall)} 부족',
                  style: strong.copyWith(color: PayseColors.error),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-26: 가로 위치 [fraction](0~1)에 붙는 표시. ≤10%는 왼쪽 끝, ≥90%는 오른쪽 끝에 맞추고
/// 그 사이는 위치 기준 가운데에 두되 화면 밖으로 나가지 않게 양 끝에서 멈춘다. 높이는 내용 높이다.
class AnchoredLabel extends SingleChildRenderObjectWidget {
  /// 2026-10-26: 위치 [fraction]과 표시 [child]로 만든다. 범위 밖 위치는 0~1로 맞춘다.
  const AnchoredLabel({
    super.key,
    required this.fraction,
    required Widget super.child,
  });

  final double fraction;

  /// 2026-10-26: 배치 객체를 만든다.
  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderAnchoredLabel(fraction.clamp(0, 1).toDouble());

  /// 2026-10-26: 위치가 바뀌면 배치 객체에 알린다.
  @override
  void updateRenderObject(
    BuildContext context,
    RenderAnchoredLabel renderObject,
  ) {
    renderObject.fraction = fraction.clamp(0, 1).toDouble();
  }
}

/// 2026-10-26: [AnchoredLabel]의 배치. 폭은 부모 최대 폭, 높이는 내용 높이다.
class RenderAnchoredLabel extends RenderShiftedBox {
  /// 2026-10-26: 0~1 위치 [_fraction]으로 만든다.
  RenderAnchoredLabel(this._fraction) : super(null);

  double _fraction;

  /// 2026-10-26: 위치를 바꾸고 다시 배치한다.
  set fraction(double value) {
    if (value == _fraction) return;
    _fraction = value;
    markNeedsLayout();
  }

  /// 2026-10-26: 내용을 재고 위치 규칙에 맞는 왼쪽 위치에 둔다.
  @override
  void performLayout() {
    final label = child!;
    label.layout(constraints.loosen(), parentUsesSize: true);
    size = constraints.constrain(Size(constraints.maxWidth, label.size.height));
    final room = size.width - label.size.width < 0
        ? 0.0
        : size.width - label.size.width;
    final double x;
    if (_fraction <= 0.1) {
      x = 0;
    } else if (_fraction >= 0.9) {
      x = room;
    } else {
      x = (_fraction * size.width - label.size.width / 2)
          .clamp(0, room)
          .toDouble();
    }
    (label.parentData! as BoxParentData).offset = Offset(x, 0);
  }
}

/// 2026-10-26: 이름 뒤 6dp에 8×8 색 칩을 붙인 표시. 칩은 접근성 트리에 넣지 않는다.
class ColorChipLabel extends StatelessWidget {
  /// 2026-10-26: 이름 [label], 칩 색 [color](null이면 칩 없음), 글자 [style]로 만든다.
  const ColorChipLabel({
    super.key,
    required this.label,
    required this.color,
    required this.style,
  });

  final String label;
  final Color? color;
  final TextStyle style;

  /// 2026-10-26: 이름과 칩을 한 줄 글자 흐름으로 반환한다.
  @override
  Widget build(BuildContext context) {
    final chip = color;
    return Text.rich(
      TextSpan(
        text: label,
        children: [
          if (chip != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(left: 6),
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 8,
                    height: 8,
                    child: ColoredBox(color: chip),
                  ),
                ),
              ),
            ),
        ],
      ),
      style: style,
    );
  }
}

/// 2026-10-26: 02-2 영수증 글자(design.md §6 02-2 영수증). 기본 16 기준이며 기기 글자 크기 설정을 따른다.
abstract final class DetailTypography {
  static const TextStyle title = TextStyle(
    fontSize: 17,
    height: 1.5,
    fontWeight: FontWeight.w700,
    color: PayseColors.textPrimary,
  );

  static const TextStyle row = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w700,
    color: PayseColors.textPrimary,
    fontFeatures: PayseTypography.tabular,
  );

  static const TextStyle body = TextStyle(
    fontSize: 16,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: PayseColors.textPrimary,
    fontFeatures: PayseTypography.tabular,
  );

  static const TextStyle secondary = TextStyle(
    fontSize: 14,
    height: 1.45,
    fontWeight: FontWeight.w400,
    color: PayseColors.textSecondary,
    fontFeatures: PayseTypography.tabular,
  );

  static const TextStyle timeline = TextStyle(
    fontSize: 13,
    height: 1.5,
    fontWeight: FontWeight.w400,
    color: PayseColors.textSecondary,
  );

  static const TextStyle result = TextStyle(
    fontSize: 24,
    height: 1.3,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.02 * 24,
    color: PayseColors.textPrimary,
    fontFeatures: PayseTypography.tabular,
  );

  static const TextStyle unavailableResult = TextStyle(
    fontSize: 20,
    height: 1.4,
    fontWeight: FontWeight.w700,
    color: PayseColors.textSecondary,
  );
}
