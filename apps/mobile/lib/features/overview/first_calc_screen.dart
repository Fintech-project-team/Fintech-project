import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../../shared/design/primary_button.dart';
import 'calculation_detail_screen.dart';
import 'composition_bar.dart';
import 'cycle_moon.dart';
import 'finance_line_icon.dart';
import 'home_calculation.dart';
import 'slide_switch.dart';

/// 2026-10-27: 01-3 첫 계산 설명(1/4 계좌 잔액 → 2/4 모아둘 돈 → 3/4 예정 지출 → 4/4 결과).
/// 홈과 같은 계산 결과 [calculation]을 그대로 보이며 금액을 다시 계산하지 않는다. 배정·부분 출금 관계는 설명하지 않는다.
/// 2026-10-28: 영수증을 단계 사이에 유지하고 바뀌는 부분만 움직인다. 4/4 뒤에는 시작 화면을 보인다([outro]).
class FirstCalcFlow extends StatefulWidget {
  /// 2026-10-27: U가 있는 계산 결과 [calculation], 4/4 '홈으로' [onExplained], 중간 '홈으로 가기' [onSkipped]로 만든다.
  /// 2026-10-28: [outro]가 true면 4/4 다음에 시작 화면을 보이고 그 '시작하기'가 [onExplained]다(홈에서 다시 보기는 false).
  /// [onBackAtFirst]는 1/4에서 시스템 뒤로 가기를 눌렀을 때 부른다. null이면 1/4에 머문다(앱을 벗어나지 않음).
  const FirstCalcFlow({
    super.key,
    required this.calculation,
    required this.onExplained,
    required this.onSkipped,
    this.outro = true,
    this.onBackAtFirst,
  });

  final HomeCalculationReady calculation;
  final VoidCallback onExplained;
  final VoidCallback onSkipped;
  final bool outro;
  final VoidCallback? onBackAtFirst;

  static const int steps = 4;

  /// 2026-10-28: 단계 전환 움직임 시간.
  static const Duration motion = Duration(milliseconds: 360);

  /// 2026-10-27: 현재 단계 상태 객체를 반환한다.
  @override
  State<FirstCalcFlow> createState() => _FirstCalcFlowState();
}

/// 2026-10-28: 움직임 줄이기 설정이면 0, 아니면 [duration]을 반환한다.
Duration _motion(
  BuildContext context, [
  Duration duration = FirstCalcFlow.motion,
]) => MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

/// 2026-10-27: 현재 단계(0~3)를 보관한다. 시스템 뒤로 가기는 이전 단계로 돌아간다.
/// 2026-10-28: 시작 화면 표시 여부도 보관한다. 시작 화면에서 뒤로 가면 4/4다. 1/4에서는 앱을 벗어나지 않고
/// [FirstCalcFlow.onBackAtFirst]에 맡긴다.
class _FirstCalcFlowState extends State<FirstCalcFlow> {
  int _step = 0;
  bool _start = false;

  /// 2026-10-27: 단계 화면을 반환한다.
  /// 2026-10-28: 머리 문구만 단계별로 바꿔 끼우고 영수증·안내는 같은 자리에서 움직인다.
  @override
  Widget build(BuildContext context) {
    final result = widget.calculation.result;
    final names = SnapshotNames(widget.calculation.snapshot);
    final last = _step == FirstCalcFlow.steps - 1;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_start) {
          setState(() => _start = false);
        } else if (_step > 0) {
          setState(() => _step--);
        } else {
          widget.onBackAtFirst?.call();
        }
      },
      child: Scaffold(
        body: SafeArea(
          child: slideSwitch(
            context,
            _start
                ? _StartScreen(
                    key: const ValueKey('first-calc-start'),
                    onStart: widget.onExplained,
                  )
                : Column(
                    key: const ValueKey('first-calc-steps'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _TopBar(
                        step: _step,
                        onSkip: last ? null : widget.onSkipped,
                      ),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.only(bottom: PayseSpace.x6),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _StepSwitcher(
                                child: KeyedSubtree(
                                  key: ValueKey('first-calc-step-${_step + 1}'),
                                  child: _heading(result),
                                ),
                              ),
                              _Reveal(
                                visible: last,
                                child: _ResultBar(result: result),
                              ),
                              _Reveal(
                                visible: last && _awaitingTotal(result) > 0,
                                child: _AwaitingBand(
                                  totalKrw: _awaitingTotal(result),
                                ),
                              ),
                              _receipt(result, names),
                              _Reveal(
                                visible:
                                    _step == 2 &&
                                    _awaiting(result) &&
                                    _held(result).isNotEmpty,
                                child: _heldGroup(result, names),
                              ),
                              AnimatedSwitcher(
                                duration: _motion(context),
                                child: KeyedSubtree(
                                  key: ValueKey('first-calc-note-$_step'),
                                  child: _note(result),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      PrimaryButton(
                        key: const ValueKey('first-calc-next'),
                        label: last && !widget.outro ? '홈으로' : '다음',
                        onPressed: () => last
                            ? widget.outro
                                  ? setState(() => _start = true)
                                  : widget.onExplained()
                            : setState(() => _step++),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// 2026-10-27: 다음 월급일 'M/D'. 주기를 모르면 null이다.
  static String? _nextPayDay(calc.CurrentAmountResult result) {
    final end = result.salaryCycle?.periodEnd;
    return end == null ? null : md(end);
  }

  /// 2026-10-27: 이번 결과가 월급 입금 확인 전 기준이면 true.
  static bool _awaiting(calc.CurrentAmountResult result) =>
      result.salaryCycle?.state == calc.SalaryCycleState.awaitingDeposit;

  /// 2026-10-28: 입금 확인 전 보류 지출 합계. 입금 대기가 아니면 0이다.
  static int _awaitingTotal(calc.CurrentAmountResult result) {
    if (!_awaiting(result)) return 0;
    final total =
        result.placementTotals?[calc.ObligationPlacement.awaitingSalary];
    return total?.totalKrw ?? 0;
  }

  /// 2026-10-28: 입금 확인 전 보류 지출.
  static List<calc.ObligationLine> _held(calc.CurrentAmountResult result) =>
      _lines(result, calc.ObligationPlacement.awaitingSalary);

  /// 2026-10-27: 배치가 [placement]인 예정 지출을 예정일 순으로 반환한다.
  static List<calc.ObligationLine> _lines(
    calc.CurrentAmountResult result,
    calc.ObligationPlacement placement,
  ) => [
    for (final line in result.obligationLines ?? const <calc.ObligationLine>[])
      if (line.placement == placement) line,
  ]..sort((a, b) => a.dueDate.compareTo(b.dueDate));

  /// 2026-10-28: 예정 지출 하위 항목.
  static _Item _obligationItem(SnapshotNames names, calc.ObligationLine line) =>
      _Item(
        name: names.obligationLabel(line.obligationId),
        secondary: '${md(line.dueDate)} 예정',
        amount: formatKrw(line.remainingKrw),
      );

  /// 2026-10-28: 단계별 머리. 1/4 잔액, 2/4 모아둘 돈(0원·전부 배정 구분), 3/4 예정 지출(입금 대기 구분), 4/4 결과.
  Widget _heading(calc.CurrentAmountResult result) {
    final awaiting = _awaiting(result);
    final payDay = _nextPayDay(result);
    final asOf = widget.calculation.snapshot.asOf;
    switch (_step) {
      case 0:
        final count = result.accountLines?.length ?? 0;
        return _Heading(
          eyebrow: '다음 월급일까지 쓸 수 있는 돈을 계산해 볼게요',
          title: '고른 계좌 $count개에\n${formatKrw(result.b!)}이 있어요',
          asOf: asOf,
        );
      case 1:
        final rEff = result.rEff!;
        return _Heading(
          eyebrow: '모아둘 돈을 빼요',
          title: rEff > 0
              ? '${formatKrw(rEff)}은\n쓰지 않고 남겨둘게요'
              : '이번 계산에서 따로 남겨둘\n금액은 0원이에요',
        );
      case 2:
        final e = result.e!;
        return _Heading(
          eyebrow: awaiting
              ? '예정 지출'
              : payDay == null
              ? '다음 월급일 전에 나갈 돈을 빼요'
              : '다음 월급일($payDay) 전에 나갈 돈을 빼요',
          title: awaiting
              ? '월급 입금 확인 후\n계산에 반영할 지출이에요'
              : e > 0
              ? '${formatKrw(e)}이\n나갈 예정이에요'
              : '이번 계산에서 뺄\n예정 지출은 없어요',
        );
      default:
        return _Heading(
          eyebrow: '계산을 마쳤어요',
          title: awaiting
              ? '월급 입금 전 기준으로\n쓸 수 있는 돈이에요'
              : payDay == null
              ? '다음 월급일까지\n쓸 수 있는 돈이에요'
              : '다음 월급일($payDay)까지\n쓸 수 있는 돈이에요',
          asOf: asOf,
        );
    }
  }

  /// 2026-10-28: 단계 사이에 유지되는 영수증. 계좌 잔액은 늘 보이고, 모아둘 돈은 2/4부터, 예정 지출은 3/4부터 나타난다.
  /// 현재 단계 행만 진하게 하위 내역을 펼치고 4/4에서는 모두 진하게 접은 채 결과를 보인다.
  Widget _receipt(calc.CurrentAmountResult result, SnapshotNames names) {
    final awaiting = _awaiting(result);
    final accounts = result.accountLines ?? const <calc.AccountLine>[];
    final reserves = result.reserveLines ?? const <calc.ReserveLine>[];
    final current = _lines(result, calc.ObligationPlacement.inCurrentPeriod);
    return _Receipt(
      step: _step,
      rows: [
        _ReceiptRow(
          title: '계좌 잔액',
          count: '${accounts.length}개',
          amount: formatKrw(result.b!),
          items: [
            for (final line in accounts)
              _Item(
                name: names.accountName(line.accountId),
                inline: names.maskedTail(line.accountId),
                amount: formatKrw(line.balanceKrw),
              ),
          ],
        ),
        _ReceiptRow(
          title: '모아둘 돈',
          chip: PayseColors.reserve,
          amount: _deduction(result.rEff!),
          items: [
            for (final line in reserves)
              _Item(
                name: names.reserveLabel(line.reserveId),
                secondary: names.accountShort(line.accountId),
                amount: formatKrw(line.effectiveKrw ?? line.amountKrw),
              ),
          ],
        ),
        _ReceiptRow(
          title: '예정 지출',
          chip: PayseColors.scheduled,
          label: awaiting ? '입금 확인 대기' : null,
          count: awaiting ? null : '${current.length}건',
          amount: _deduction(result.e!),
          items: [for (final line in current) _obligationItem(names, line)],
        ),
      ],
      result: result.u!,
    );
  }

  /// 2026-10-28: 3/4 입금 확인 전 보류 지출 묶음(영수증 밖, − 없음).
  Widget _heldGroup(calc.CurrentAmountResult result, SnapshotNames names) {
    final held = _held(result);
    final total =
        result.placementTotals?[calc.ObligationPlacement.awaitingSalary];
    if (held.isEmpty || total == null) return const SizedBox.shrink();
    return _HeldGroup(
      count: total.count,
      total: formatKrw(total.totalKrw),
      items: [for (final line in held) _obligationItem(names, line)],
    );
  }

  /// 2026-10-28: 단계별 영수증 아래 안내.
  Widget _note(calc.CurrentAmountResult result) {
    switch (_step) {
      case 0:
        return const _Note('금융사에서 받은 잔액 그대로예요.');
      case 1:
        final r = result.r ?? 0;
        if (result.rEff == 0 && r > 0) {
          return _Note(
            '모아둘 돈 ${formatKrw(r)}은 모두 예정 지출에 쓰기로 해서, '
            '예정 지출에서 한 번만 빼고 여기서는 따로 빼지 않아요.',
            key: const ValueKey('first-calc-reserve-used'),
          );
        }
        return const SizedBox(width: double.infinity);
      case 2:
        if (_awaiting(result) && _held(result).isNotEmpty) {
          return const _Note(
            '지금은 이 지출을 계산에서 빼지 않아요. 월급 입금이 확인되면 남은 지출을 반영해 다시 계산해요.',
            key: ValueKey('first-calc-held-note'),
          );
        }
        return const _Note("자세한 내용은 홈의 '계산 내역'에서 볼 수 있어요.");
      default:
        return const _Note("홈의 '계산 내역'에서 언제든 다시 볼 수 있어요.");
    }
  }
}

/// 2026-10-27: 차감 금액 표기. 0원이 아니면 앞에 −를 붙인다.
String _deduction(int amountKrw) =>
    amountKrw == 0 ? formatKrw(0) : formatKrw(-amountKrw);

/// 2026-10-28: 머리 문구 전환. 이전 문구는 왼쪽으로 밀리며 사라지고 새 문구는 제자리에서 서서히 나타난다.
class _StepSwitcher extends StatelessWidget {
  /// 2026-10-28: 단계별 키가 붙은 [child]로 만든다.
  const _StepSwitcher({required this.child});

  final Widget child;

  /// 2026-10-28: 전환 상자를 반환한다.
  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _motion(context),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topLeft,
        children: [...previous, ?current],
      ),
      transitionBuilder: (widget, animation) => SwitchMotion(
        animation: animation,
        incomingFrom: Offset.zero,
        outgoingTo: const Offset(-0.35, 0),
        child: widget,
      ),
      child: child,
    );
  }
}

/// 2026-10-28: [visible]이면 높이를 늘리며 서서히 나타나고, 아니면 접히며 사라지는 자리.
class _Reveal extends StatelessWidget {
  /// 2026-10-28: 표시 여부 [visible]와 내용 [child]로 만든다.
  const _Reveal({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  /// 2026-10-28: 펼침·접힘 상자를 반환한다.
  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _motion(context),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (widget, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: Alignment.topCenter,
        child: FadeTransition(opacity: animation, child: widget),
      ),
      child: visible
          ? KeyedSubtree(key: const ValueKey('shown'), child: child)
          : const SizedBox(key: ValueKey('hidden'), width: double.infinity),
    );
  }
}

/// 2026-10-28: 4/4 금액 구성 바. 처음 보일 때 구간을 왼쪽부터 차례로 늘리고 범례를 차례로 나타낸다.
class _ResultBar extends StatefulWidget {
  /// 2026-10-28: 계산 결과 [result]로 만든다.
  const _ResultBar({required this.result});

  final calc.CurrentAmountResult result;

  /// 2026-10-28: 움직임 상태 객체를 반환한다.
  @override
  State<_ResultBar> createState() => _ResultBarState();
}

/// 2026-10-28: 바 등장 움직임을 소유한다.
class _ResultBarState extends State<_ResultBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2700),
  );

  /// 2026-10-28: 화면에 붙으면 한 번 재생한다. 움직임 줄이기 설정이면 마지막 모습으로 둔다.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _reveal.value = 1;
    } else if (_reveal.isDismissed) {
      _reveal.forward();
    }
  }

  /// 2026-10-28: 움직임을 해제한다.
  @override
  void dispose() {
    _reveal.dispose();
    super.dispose();
  }

  /// 2026-10-28: 바를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PayseSpace.screenHorizontal,
      ),
      child: CompositionBar(result: widget.result, reveal: _reveal),
    );
  }
}

/// 2026-10-27: 단계 표시(현재 단계만 길게)와 오른쪽 '홈으로 가기'. 4/4에서는 [onSkip]이 null이라 버튼이 없다.
/// 2026-10-28: 단계가 바뀌면 이전 막대는 줄고 현재 막대는 늘어나며, 색도 함께 바뀐다.
class _TopBar extends StatelessWidget {
  /// 2026-10-27: 현재 단계 [step](0부터)과 건너뛰기 [onSkip]으로 만든다.
  const _TopBar({required this.step, required this.onSkip});

  final int step;
  final VoidCallback? onSkip;

  /// 2026-10-27: 머리 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final skip = onSkip;
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          PayseSpace.screenHorizontal,
          0,
          PayseSpace.x3,
          0,
        ),
        child: Row(
          children: [
            Semantics(
              label: '${FirstCalcFlow.steps}단계 중 ${step + 1}단계',
              child: ExcludeSemantics(
                child: Row(
                  children: [
                    for (var i = 0; i < FirstCalcFlow.steps; i++)
                      AnimatedContainer(
                        duration: _motion(context),
                        curve: Curves.easeInOutCubic,
                        width: i == step ? 20 : 8,
                        height: 4,
                        margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(
                          color: i <= step
                              ? PayseColors.charcoal
                              : PayseColors.dividerSection,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            if (skip != null)
              TextButton(
                key: const ValueKey('first-calc-skip'),
                onPressed: skip,
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, PayseSize.touchMin),
                  foregroundColor: PayseColors.textSecondary,
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                child: const Text('홈으로 가기'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-27: 단계 머리. 보조 제목(14/600) → 제목(24/700) → 선택 기준 시각.
class _Heading extends StatelessWidget {
  /// 2026-10-27: 보조 제목 [eyebrow], 제목 [title], 기준 시각 [asOf]로 만든다.
  const _Heading({required this.eyebrow, required this.title, this.asOf});

  final String eyebrow;
  final String title;
  final String? asOf;

  /// 2026-10-27: 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    final basis = asOf;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x4,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: const TextStyle(
              fontSize: 14,
              height: 20 / 14,
              fontWeight: FontWeight.w600,
              color: PayseColors.textSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Semantics(
            header: true,
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 24,
                height: 1.42,
                fontWeight: FontWeight.w700,
                color: PayseColors.textPrimary,
                fontFeatures: PayseTypography.tabular,
              ),
            ),
          ),
          if (basis != null) ...[
            const SizedBox(height: 6),
            Text(
              '${financialAsOfLabel(basis)} 금융정보 기준',
              style: DetailTypography.secondary,
            ),
          ],
        ],
      ),
    );
  }
}

/// 2026-10-27: 영수증 한 행. 이름(+색 칩·상태 라벨·건수) … 금액, 아래에 하위 항목.
class _ReceiptRow {
  /// 2026-10-27: 이름 [title], 색 칩 [chip], 상태 라벨 [label], 건수 [count], 금액 [amount], 하위 항목 [items]로 만든다.
  const _ReceiptRow({
    required this.title,
    required this.amount,
    this.chip,
    this.label,
    this.count,
    this.items = const [],
  });

  final String title;
  final String amount;
  final Color? chip;
  final String? label;
  final String? count;
  final List<_Item> items;
}

/// 2026-10-27: 하위 항목 한 줄. 이름(+같은 줄 보조 글자) · 보조 줄 … 금액.
class _Item {
  /// 2026-10-27: 이름 [name], 같은 줄 보조 글자 [inline], 보조 줄 [secondary], 금액 [amount]로 만든다.
  const _Item({
    required this.name,
    required this.amount,
    this.inline,
    this.secondary,
  });

  final String name;
  final String amount;
  final String? inline;
  final String? secondary;
}

/// 2026-10-27: 01-3 영수증. 1.5dp 차콜 위선, 행 최소 56dp, 결과가 있으면 이중선 아래 '쓸 수 있는 돈'.
/// 2026-10-28: 단계 [step]에 따라 행 [rows]를 차례로 나타내고, 현재 행만 진하게 하위 내역을 펼친다.
/// 4/4([step] 3)에서는 모든 행을 진하게 접고 결과 [result]를 나타낸다.
class _Receipt extends StatelessWidget {
  /// 2026-10-28: 단계 [step], 행 [rows], 결과 [result]로 만든다. 펼치는 화살표가 없는 목록이라 금액 오른쪽에
  /// 화살표 자리를 비워 두지 않고 하위 내역 금액도 오른쪽 끝에 맞춘다.
  const _Receipt({
    required this.step,
    required this.rows,
    required this.result,
  });

  final int step;
  final List<_ReceiptRow> rows;
  final int result;

  /// 2026-10-27: 영수증을 반환한다.
  @override
  Widget build(BuildContext context) {
    final u = result;
    final duration = _motion(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x6,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Divider(
            height: 1.5,
            thickness: 1.5,
            color: PayseColors.charcoal,
          ),
          for (var i = 0; i < rows.length; i++)
            _Reveal(
              visible: i <= step,
              child: _row(
                rows[i],
                index: i,
                current: i == step,
                dim: step < rows.length && i != step,
                duration: duration,
              ),
            ),
          _Reveal(
            visible: step >= rows.length,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: PayseSpace.x2),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: PayseColors.charcoal,
                ),
                const SizedBox(height: 3),
                const Divider(
                  height: 1,
                  thickness: 1,
                  color: PayseColors.charcoal,
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      const Expanded(
                        child: ColorChipLabel(
                          label: '쓸 수 있는 돈',
                          color: PayseColors.available,
                          style: DetailTypography.row,
                        ),
                      ),
                      const SizedBox(width: PayseSpace.x3),
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerRight,
                          child: Text(
                            formatKrw(u),
                            key: const ValueKey('first-calc-result'),
                            semanticsLabel: spokenKrw(u),
                            maxLines: 1,
                            style: DetailTypography.result.copyWith(
                              color: u < 0 ? PayseColors.error : null,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (u < 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '모아둘 돈과 예정 지출을 모두 확보하려면\n${formatKrw(-u)}이 더 필요해요.',
                      textAlign: TextAlign.right,
                      style: DetailTypography.secondary,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 2026-10-27: 행 [row]와 하위 항목을 반환한다.
  /// 2026-10-28: 첫 행이 아니면 위에 행 구분선을 둔다. 현재 행([current])만 하위 내역을 펼치고, 지난 행([dim])은 흐리게 한다.
  Widget _row(
    _ReceiptRow row, {
    required int index,
    required bool current,
    required bool dim,
    required Duration duration,
  }) {
    return Column(
      key: ValueKey('first-calc-row-$index'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (index > 0)
          const Divider(height: 1, thickness: 1, color: PayseColors.dividerRow),
        AnimatedOpacity(
          opacity: dim ? 0.45 : 1,
          duration: duration,
          child: MergeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 56),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 2,
                        children: [
                          ColorChipLabel(
                            label: row.title,
                            color: row.chip,
                            style: DetailTypography.row,
                          ),
                          if (row.count != null)
                            Text(
                              '· ${row.count}',
                              style: DetailTypography.secondary.copyWith(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          if (row.label != null) _StatusLabel(row.label!),
                        ],
                      ),
                    ),
                    const SizedBox(width: PayseSpace.x3),
                    Text(row.amount, style: DetailTypography.row),
                  ],
                ),
              ),
            ),
          ),
        ),
        _Reveal(
          visible: current && row.items.isNotEmpty,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 0, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < row.items.length; i++) ...[
                  if (i > 0) const SizedBox(height: PayseSpace.x3),
                  _itemRow(row.items[i]),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 2026-10-27: 하위 항목 한 줄을 반환한다.
  static Widget _itemRow(_Item item) {
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text.rich(
                  TextSpan(
                    text: item.name,
                    children: [
                      if (item.inline != null)
                        TextSpan(
                          text: ' ${item.inline}',
                          style: DetailTypography.secondary,
                        ),
                    ],
                  ),
                  style: DetailTypography.body,
                ),
                if (item.secondary != null)
                  Text(item.secondary!, style: DetailTypography.secondary),
              ],
            ),
          ),
          const SizedBox(width: PayseSpace.x3),
          Text(item.amount, style: DetailTypography.body),
        ],
      ),
    );
  }
}

/// 2026-10-27: 중립 상태 라벨(design.md §5). surfaceMuted 바탕·높이 22·13/500.
class _StatusLabel extends StatelessWidget {
  /// 2026-10-27: 라벨 글자 [text]로 만든다.
  const _StatusLabel(this.text);

  final String text;

  /// 2026-10-27: 라벨을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: PayseColors.textSecondary,
        ),
      ),
    );
  }
}

/// 2026-10-27: 4/4 입금 확인 전 안내 띠(02-2 입금 대기 띠와 같은 바탕·경계). 보류 지출 합계는 지금 빼지 않았음을 알린다.
class _AwaitingBand extends StatelessWidget {
  /// 2026-10-27: 보류 지출 합계 [totalKrw](계산 결과)로 만든다.
  const _AwaitingBand({required this.totalKrw});

  final int totalKrw;

  /// 2026-10-27: 띠를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: PayseSpace.x5),
      child: Semantics(
        liveRegion: true,
        child: DecoratedBox(
          key: const ValueKey('first-calc-awaiting-notice'),
          decoration: const BoxDecoration(
            color: PayseColors.awaitingNoticeSurface,
            border: Border.symmetric(
              horizontal: BorderSide(color: PayseColors.awaitingNoticeBorder),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PayseSpace.screenHorizontal,
              vertical: 14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '아직 월급 입금이 확인되지 않았어요',
                  style: TextStyle(
                    fontSize: 15,
                    height: 22 / 15,
                    fontWeight: FontWeight.w700,
                    color: PayseColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '입금 확인 후 반영할 지출 ${formatKrw(totalKrw)}은 지금 계산에서 빼지 않아요. '
                  '월급 입금이 확인되면 남은 지출을 반영해 다시 계산해요.',
                  style: const TextStyle(
                    fontSize: 13,
                    height: 19 / 13,
                    color: PayseColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 2026-10-27: 입금 확인 전 보류 지출 묶음. 영수증(차감) 밖에 두고 금액에 −를 붙이지 않는다.
class _HeldGroup extends StatelessWidget {
  /// 2026-10-27: 건수 [count], 합계 [total], 항목 [items]로 만든다.
  const _HeldGroup({
    required this.count,
    required this.total,
    required this.items,
  });

  final int count;
  final String total;
  final List<_Item> items;

  /// 2026-10-27: 묶음 제목·합계와 항목을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      key: const ValueKey('first-calc-held'),
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x6,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MergeSemantics(
            child: Row(
              children: [
                Expanded(
                  child: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 2,
                    children: [
                      Text(
                        '입금 확인 후 반영할 지출',
                        style: DetailTypography.row.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '· $count건',
                        style: DetailTypography.secondary.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: PayseSpace.x3),
                Text(
                  total,
                  key: const ValueKey('first-calc-held-total'),
                  style: DetailTypography.body,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, PayseSpace.x3, 0, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const SizedBox(height: PayseSpace.x3),
                  _Receipt._itemRow(items[i]),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-10-27: 영수증 아래 보조 문장(13/19, textSecondary).
class _Note extends StatelessWidget {
  /// 2026-10-27: 문장 [text]로 만든다.
  const _Note(this.text, {super.key});

  final String text;

  /// 2026-10-27: 문장을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x5,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          height: 19 / 13,
          color: PayseColors.textSecondary,
        ),
      ),
    );
  }
}

/// 2026-10-28: 4/4 다음 시작 화면. 가운데 달이 그믐에서 보름으로 차오른 뒤 안내가 서서히 나타나고,
/// 달 위쪽 호를 따라 금융 아이콘(지갑·카드·동전·달력)이 달 뒤에서 차례로 튀어나와 제자리 둘레를 천천히 돈다.
/// '홈으로 가기'를 눌러야 홈으로 가며 자동으로 넘어가지 않는다. 움직임 줄이기 설정이면 마지막 모습만 보인다.
class _StartScreen extends StatefulWidget {
  /// 2026-10-28: 홈으로 가기 [onStart]로 만든다.
  const _StartScreen({super.key, required this.onStart});

  final VoidCallback onStart;

  /// 2026-10-28: 움직임 상태 객체를 반환한다.
  @override
  State<_StartScreen> createState() => _StartScreenState();
}

/// 2026-10-28: 달·안내·아이콘 등장 움직임과 아이콘 맴돌기를 소유한다.
class _StartScreenState extends State<_StartScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2800),
  );
  late final AnimationController _orbit = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  static const List<(FinanceIconKind, double)> _icons = [
    (FinanceIconKind.salary, -155),
    (FinanceIconKind.card, -115),
    (FinanceIconKind.reserve, -65),
    (FinanceIconKind.scheduled, -25),
  ];
  static const double _ring = 100;
  static const double _chip = 44;
  static const double _drift = 5;
  static const double _moon = 112;

  /// 2026-10-28: 아이콘·달을 담는 상자. 달 중심은 가로 가운데, 세로는 위쪽 호가 들어갈 만큼 아래에 둔다.
  static const double _width = (_ring + _chip / 2 + _drift) * 2;
  static const double _centerY = _ring + _chip / 2 + _drift;
  static const double _height = _centerY + _moon / 2;

  /// 2026-10-28: 화면에 붙으면 등장을 한 번 재생하고, 끝나면 아이콘 맴돌기를 반복한다.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _intro.value = 1;
      _orbit.stop();
    } else if (_intro.isDismissed) {
      _intro.forward().whenComplete(() {
        if (mounted) _orbit.repeat();
      });
    }
  }

  /// 2026-10-28: 움직임을 해제한다.
  @override
  void dispose() {
    _intro.dispose();
    _orbit.dispose();
    super.dispose();
  }

  /// 2026-10-28: [index]번째 아이콘의 튀어나옴(0→1, 살짝 넘쳤다 돌아옴).
  Animation<double> _pop(int index) => CurvedAnimation(
    parent: _intro,
    curve: Interval(
      0.5 + index * 0.07,
      0.72 + index * 0.07,
      curve: Curves.easeOutBack,
    ),
  );

  /// 2026-10-28: 달과 위쪽 호 위의 아이콘을 반환한다. 아이콘은 달 뒤에 그린다.
  Widget _moonWithIcons(Animation<double> moon) {
    return SizedBox(
      width: _width,
      height: _height,
      child: AnimatedBuilder(
        animation: Listenable.merge([_intro, _orbit]),
        builder: (context, _) => Stack(
          children: [
            for (var i = 0; i < _icons.length; i++) _orbitIcon(i),
            Positioned(
              left: (_width - _moon) / 2,
              top: _centerY - _moon / 2,
              child: CycleMoon(lit: 0.04 + 0.96 * moon.value, size: _moon),
            ),
          ],
        ),
      ),
    );
  }

  /// 2026-10-28: [index]번째 아이콘. 달 위쪽 호([_ring] 반지름의 각도)가 기준 자리이며 그 둘레를 작은 원([_drift])으로 돈다.
  Widget _orbitIcon(int index) {
    final (kind, degrees) = _icons[index];
    final angle = degrees * math.pi / 180;
    final phase = 2 * math.pi * (_orbit.value + index / _icons.length);
    final drift = MediaQuery.disableAnimationsOf(context) ? 0.0 : _drift;
    final x = _width / 2 + _ring * math.cos(angle) + drift * math.cos(phase);
    final y = _centerY + _ring * math.sin(angle) + drift * math.sin(phase);
    final pop = _pop(index).value;
    return Positioned(
      left: x - _chip / 2,
      top: y - _chip / 2,
      child: Opacity(
        opacity: pop.clamp(0, 1),
        child: Transform.scale(
          scale: pop.clamp(0, 1.2),
          child: Container(
            width: _chip,
            height: _chip,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: PayseColors.surfaceMuted,
              shape: BoxShape.circle,
            ),
            child: FinanceLineIcon(kind, size: 22),
          ),
        ),
      ),
    );
  }

  /// 2026-10-28: 달·안내·홈으로 가기를 반환한다.
  @override
  Widget build(BuildContext context) {
    final moon = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0, 0.45, curve: Curves.easeInOutCubic),
    );
    final text = CurvedAnimation(
      parent: _intro,
      curve: const Interval(0.35, 0.65, curve: Curves.easeOut),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                horizontal: PayseSpace.screenHorizontal,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ExcludeSemantics(child: _moonWithIcons(moon)),
                  const SizedBox(height: PayseSpace.x6),
                  FadeTransition(
                    opacity: text,
                    child: SlideTransition(
                      position: Tween(
                        begin: const Offset(0, 0.15),
                        end: Offset.zero,
                      ).animate(text),
                      child: const Column(
                        children: [
                          Text(
                            '이제 홈에서 확인하세요',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 24,
                              height: 1.42,
                              fontWeight: FontWeight.w700,
                              color: PayseColors.textPrimary,
                            ),
                          ),
                          SizedBox(height: PayseSpace.x2),
                          Text(
                            '다음 월급일까지 쓸 수 있는 돈을\n홈에서 확인할 수 있어요.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 15,
                              height: 22 / 15,
                              color: PayseColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        PrimaryButton(
          key: const ValueKey('first-calc-start-button'),
          label: '홈으로 가기',
          onPressed: widget.onStart,
        ),
      ],
    );
  }
}
