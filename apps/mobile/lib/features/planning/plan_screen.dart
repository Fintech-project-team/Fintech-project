import 'package:flutter/material.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/calculation_input_adapter.dart';
import '../../data/financial_snapshot.dart';
import '../../data/statement_relations.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../overview/accounts_cards_screen.dart' show InnerTab;
import '../overview/calculation_detail_screen.dart'
    show SnapshotNames, StatusLabel, md;
import '../overview/home_calculation.dart';
import '../overview/home_screen.dart' show asOfLabel;
import '../overview/overview_links.dart';
import '../overview/pull_refresh.dart';
import '../overview/transaction_sheets.dart' show showPayseSheet;
import 'card_bill_screen.dart';
import 'plan_period_sheet.dart';
import 'plan_periods.dart';

/// 2026-11-02: 계획 탭의 안쪽 탭.
enum PlanTab { scheduled, reserves }

/// 2026-11-02: 하단 '계획' 탭(29-3, 읽기 전용). 안쪽 탭 '예정 지출 / 남겨둘 돈'. 예정 지출은 위에서 기간(월급 기간 또는 달력 월)을
/// 고르고 그 기간에 예정일이 든 '앞으로 나갈 돈 → 이미 나간 돈(접힘) → 계산에서 뺀 계좌(접힘)'를 보인다. 남겨둘 돈은 현재
/// 설정이다. 금액·기간·위치는 홈 계산 결과를 그대로 쓰고 화면에서 새로 계산하지 않는다. 다른 하단 탭에 다녀와도 안쪽 탭·
/// 기간·펼침·스크롤을 유지한다.
class PlanScreen extends StatefulWidget {
  /// 2026-11-02: 화면 사이 연결 [links](현재 계산·받은 거래·새로고침)로 만든다.
  const PlanScreen({required this.links, super.key});

  final OverviewLinks links;

  /// 2026-11-02: 상태 객체를 반환한다.
  @override
  State<PlanScreen> createState() => _PlanScreenState();
}

/// 2026-11-02: 고른 안쪽 탭·기간·펼친 구역을 가진다.
class _PlanScreenState extends State<PlanScreen> {
  PlanTab _tab = PlanTab.scheduled;
  PlanPeriod? _period;
  bool _doneOpen = false;
  bool _excludedOpen = false;

  /// 2026-11-02: 제목·안쪽 탭·화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              PayseSpace.x6,
              PayseSpace.screenHorizontal,
              0,
            ),
            child: Text(
              '계획',
              style: TextStyle(
                fontSize: 24,
                height: 1.42,
                fontWeight: FontWeight.w700,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: PayseSpace.x3),
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: PayseSpace.screenHorizontal,
            ),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: PayseColors.border)),
            ),
            child: Row(
              children: [
                for (final (i, (t, label)) in const [
                  (PlanTab.scheduled, '예정 지출'),
                  (PlanTab.reserves, '남겨둘 돈'),
                ].indexed) ...[
                  if (i > 0) const SizedBox(width: PayseSpace.x6),
                  InnerTab(
                    key: ValueKey('plan-tab-${t.name}'),
                    label: label,
                    selected: _tab == t,
                    onTap: () => setState(() => _tab = t),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ValueListenableBuilder<OverviewState>(
              valueListenable: widget.links.state,
              builder: (context, state, _) => IndexedStack(
                index: _tab.index,
                children: [_scheduled(state), _reserves(state)],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 2026-11-02: 예정 지출 탭. 계산 결과가 없으면 안내만 보인다.
  Widget _scheduled(OverviewState state) {
    final calculation = state.calculation;
    final lines = calculation is HomeCalculationReady
        ? calculation.result.obligationLines
        : null;
    if (calculation is! HomeCalculationReady || lines == null) {
      return _Message(
        key: const ValueKey('plan-unavailable'),
        text: calculation is HomeCalculationReady
            ? '예정 지출 정보를 받지 못했어요.'
            : '계획을 불러오지 못했어요.',
      );
    }
    final snapshot = calculation.snapshot;
    final result = calculation.result;
    final today = result.context.businessDate;
    final inputs = _inputs(snapshot);
    final salaryList = salaryPeriods(
      cycle: result.salaryCycle,
      salary: inputs?.salary,
      frames: projectionFrames(
        today: today,
        ledger: inputs?.ledger,
        salary: inputs?.salary,
      ),
    );
    final months = calendarMonths(today, [
      for (final l in lines)
        if (planGroup(l) != null) l.dueDate,
    ]);
    final period = _resolve(salaryList, months, today);
    final list = period.kind == PlanPeriodKind.salary
        ? salaryList!.periods
        : months;
    final index = list.indexOf(period);
    final current =
        period.role == SalaryRole.current ||
        (period.kind == PlanPeriodKind.month && period == monthOf(today));
    final groups = linesIn(period, lines);
    final carry = current
        ? carriedOver(period, lines)
        : const <calc.ObligationLine>[];
    final end = labelEnd(salaryList);
    final history = state.history;
    final view = _LineView(
      snapshot: snapshot,
      relations: StatementRelations(
        snapshot,
        transactions: history != null && identical(history.snapshot, snapshot)
            ? history.transactions
            : const [],
      ),
      today: today,
      labelEnd: end,
      onOpenBill: (id) => openCardBill(
        context,
        snapshot: snapshot,
        statementId: id,
        transactions: history != null && identical(history.snapshot, snapshot)
            ? history.transactions
            : const [],
      ),
    );
    final upcoming = groups[PlanGroup.upcoming]!;
    final done = groups[PlanGroup.done]!;
    final excluded = groups[PlanGroup.excluded]!;
    final slot = [...upcoming, ...done, ...excluded].any(view.linked);
    return PullRefreshScrollView(
      scrollKey: const ValueKey('plan-list'),
      onRefresh: widget.links.onRefresh,
      slivers: [
        SliverToBoxAdapter(
          child: _PeriodHeader(
            period: period,
            asOf: asOfLabel(snapshot.asOf),
            onPrevious: index > 0
                ? () => setState(() => _period = list[index - 1])
                : null,
            onNext: index < list.length - 1
                ? () => setState(() => _period = list[index + 1])
                : null,
            onPick: () async {
              final picked = await showPayseSheet<PlanPeriod>(
                context,
                PlanPeriodSheet(
                  salary: salaryList?.periods,
                  months: months,
                  current: period,
                  today: today,
                ),
              );
              if (picked != null && mounted) {
                setState(() => _period = picked);
              }
            },
          ),
        ),
        if (salaryList == null)
          const SliverToBoxAdapter(
            child: _InfoBand(
              key: ValueKey('plan-no-salary'),
              text: '월급 정보를 설정하면 월급 기간별로 볼 수 있어요.',
            ),
          ),
        if (snapshot.obligationsRestricted)
          const SliverToBoxAdapter(
            child: _InfoBand(
              key: ValueKey('plan-obligations-restricted'),
              text: '연결하지 않은 계좌의 예정 지출은 보이지 않아요.',
            ),
          ),
        if (carry.isNotEmpty)
          SliverToBoxAdapter(
            child: _CarryBand(
              count: carry.length,
              onTap: () => showPayseSheet<void>(
                context,
                _CarrySheet(view: view, lines: carry),
              ),
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            PayseSpace.screenHorizontal,
            0,
            PayseSpace.screenHorizontal,
            PayseSpace.x8,
          ),
          sliver: SliverList.list(
            children: [
              if (upcoming.isEmpty && done.isEmpty && excluded.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 72),
                  child: Text(
                    snapshot.obligationsRestricted
                        ? '이 기간에 보여 드릴 수 있는 예정 지출이 없어요'
                        : '이 기간에 예정된 지출이 없어요',
                    key: const ValueKey('plan-empty'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 15,
                      color: PayseColors.textSecondary,
                    ),
                  ),
                )
              else ...[
                _SectionTitle(title: '앞으로 나갈 돈', count: upcoming.length),
                if (upcoming.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: PayseSpace.x4),
                    child: Text(
                      '이 기간에 남은 예정 지출이 없어요',
                      style: PayseTypography.caption,
                    ),
                  ),
                for (final l in upcoming)
                  view.row(l, PlanGroup.upcoming, slot: slot),
                if (done.isNotEmpty) ...[
                  _Fold(
                    key: const ValueKey('plan-fold-done'),
                    title: '이미 나간 돈',
                    count: done.length,
                    open: _doneOpen,
                    onTap: () => setState(() => _doneOpen = !_doneOpen),
                  ),
                  if (_doneOpen)
                    for (final l in done)
                      view.row(l, PlanGroup.done, slot: slot),
                ],
                if (excluded.isNotEmpty) ...[
                  _Fold(
                    key: const ValueKey('plan-fold-excluded'),
                    title: '계산에서 뺀 계좌',
                    count: excluded.length,
                    open: _excludedOpen,
                    onTap: () => setState(() => _excludedOpen = !_excludedOpen),
                  ),
                  if (_excludedOpen)
                    for (final l in excluded)
                      view.row(l, PlanGroup.excluded, slot: slot),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 2026-11-02: 고른 기간이 지금 목록에 있으면 그 기간, 없으면(처음·새로고침 뒤 사라짐) 기본 기간이다. 기본은 현재 월급 기간,
  /// 월급 기간을 정할 수 없으면 이번 달이다.
  PlanPeriod _resolve(
    SalaryPeriods? salary,
    List<PlanPeriod> months,
    calc.BusinessDate today,
  ) {
    final picked = _period;
    if (picked != null) {
      final list = picked.kind == PlanPeriodKind.salary
          ? salary?.periods ?? const <PlanPeriod>[]
          : months;
      for (final p in list) {
        if (p == picked) return p;
      }
    }
    if (salary != null) return salary.periods[salary.currentIndex];
    return monthOf(today);
  }

  /// 2026-11-02: 홈 계산과 같은 계산 입력(장부·월급). 만들 수 없으면 null이다.
  static CalculationInputs? _inputs(FinancialSnapshot snapshot) {
    try {
      return calculationInputsFromSnapshot(snapshot);
    } on Exception {
      return null;
    }
  }

  /// 2026-11-02: 남겨둘 돈 탭(현재 설정, 기간 선택 없음).
  Widget _reserves(OverviewState state) {
    final snapshot = state.calculation.snapshot;
    final reserves = [
      for (final r in snapshot.reserves ?? const <Reserve>[])
        if (r.cancelledAt == null) r,
    ];
    final names = SnapshotNames(snapshot);
    final allocations = snapshot.allocations;
    final allocationsRestricted = snapshot.isRestricted(
      'response',
      null,
      'allocations',
    );
    return PullRefreshScrollView(
      scrollKey: const ValueKey('plan-reserve-list'),
      onRefresh: widget.links.onRefresh,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(
            PayseSpace.screenHorizontal,
            PayseSpace.x3,
            PayseSpace.screenHorizontal,
            PayseSpace.x8,
          ),
          sliver: SliverList.list(
            children: [
              Text(asOfLabel(snapshot.asOf), style: PayseTypography.caption),
              if (snapshot.reserves == null)
                const _Message(text: '남겨둘 돈 정보를 받지 못했어요.')
              else ...[
                _SectionTitle(title: '남겨둘 돈', count: reserves.length),
                if (snapshot.reservesRestricted)
                  const Padding(
                    padding: EdgeInsets.only(top: PayseSpace.x3),
                    child: Text(
                      '연결하지 않은 계좌의 남겨둘 돈은 보이지 않아요.',
                      key: ValueKey('plan-reserve-restricted'),
                      style: PayseTypography.caption,
                    ),
                  ),
                if (reserves.isEmpty && !snapshot.reservesRestricted)
                  const Padding(
                    padding: EdgeInsets.only(top: 72),
                    child: Text(
                      '남겨둘 돈이 없어요',
                      key: ValueKey('plan-reserve-empty'),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 15,
                        color: PayseColors.textSecondary,
                      ),
                    ),
                  ),
                if (allocationsRestricted)
                  const Padding(
                    padding: EdgeInsets.only(top: PayseSpace.x3),
                    child: Text(
                      '연결하지 않은 계좌의 예정 지출과의 연결은 보이지 않을 수 있어요.',
                      key: ValueKey('plan-allocations-restricted'),
                      style: PayseTypography.caption,
                    ),
                  ),
                for (final r in reserves)
                  _ReserveBlock(
                    key: ValueKey('plan-reserve-${r.reserveId}'),
                    reserve: r,
                    names: names,
                    allocations: allocations == null
                        ? null
                        : [
                            for (final a in allocations)
                              if (a.reserveId == r.reserveId &&
                                  unreleasedKrw(a) > 0)
                                a,
                          ],
                    restricted: allocationsRestricted,
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 2026-11-02: 예정 지출 한 줄을 그리는 데 필요한 공통 값과 줄 생성.
class _LineView {
  /// 2026-11-02: [snapshot], 관계 조회 [relations], 기준일 [today], 날짜 라벨 범위 끝 [labelEnd], 청구 상세 열기 [onOpenBill]로
  /// 만든다.
  _LineView({
    required this.snapshot,
    required this.relations,
    required this.today,
    required this.labelEnd,
    required this.onOpenBill,
  }) : names = SnapshotNames(snapshot),
       _obligations = {
         for (final o in snapshot.obligations ?? const <Obligation>[])
           o.obligationId: o,
       };

  final FinancialSnapshot snapshot;
  final StatementRelations relations;
  final calc.BusinessDate today;
  final calc.BusinessDate? labelEnd;
  final ValueChanged<String> onOpenBill;
  final SnapshotNames names;
  final Map<String, Obligation> _obligations;

  /// 2026-11-02: [line]이 공개된 청구를 대표하면 그 청구 ID, 아니면 null이다.
  String? statementOf(calc.ObligationLine line) {
    final o = _obligations[line.obligationId];
    if (o == null) return null;
    final s = relations.statementOf(o);
    return s is LinkedStatement ? s.statement.statementId : null;
  }

  /// 2026-11-02: [line]을 누르면 청구 상세로 가면 true다.
  bool linked(calc.ObligationLine line) => statementOf(line) != null;

  /// 2026-11-02: [group] 구역의 줄. [slot]이면 화살표가 없어도 금액 오른쪽에 화살표 자리를 둔다.
  Widget row(calc.ObligationLine line, PlanGroup group, {required bool slot}) {
    final o = _obligations[line.obligationId];
    final due = md(line.dueDate);
    final account = o == null ? '' : names.accountShort(o.withdrawalAccountId);
    final partial = line.settledKrw > 0 && line.remainingKrw > 0;
    final withdrawals = [
      for (final x in relations.validSettlements(line.obligationId))
        relations.transaction(x.transactionId)?.withdrawalDate,
    ];
    final statement = statementOf(line);
    final (amount, caption, sub, detail) = switch (group) {
      PlanGroup.done => (
        line.settledKrw,
        null,
        ['$due 예정', ?names.settlementCaption(line.obligationId)].join(' · '),
        null,
      ),
      _ when partial => (
        line.remainingKrw,
        '남은 금액',
        '$due 예정 · $account',
        '예정 ${formatKrw(line.amountKrw)} · '
            '${withdrawalNote(withdrawals, line.settledKrw)}',
      ),
      _ => (line.remainingKrw, null, '$due 예정 · $account', null),
    };
    return _PlanRow(
      key: ValueKey('plan-row-${line.obligationId}'),
      name: o?.label ?? '예정 지출',
      label: group == PlanGroup.upcoming
          ? planDueLabel(line, today, labelEnd)
          : null,
      sub: sub,
      detail: detail,
      amount: formatKrw(amount),
      amountCaption: caption,
      onTap: statement == null ? null : () => onOpenBill(statement),
      slot: slot,
    );
  }
}

/// 2026-11-02: 배정에서 아직 해제되지 않은 금액(배정 총액 − 해제 누계, 계약상 해제 누계는 배정 총액 이하).
int unreleasedKrw(Allocation a) => a.amountKrw - a.releasedKrw;

/// 2026-11-02: 예정 지출 한 줄. 첫 줄 이름(말줄임)+회색 날짜 라벨, 둘째 줄 예정일·계좌, 필요하면 셋째 줄(예정·출금), 오른쪽 금액과
/// 보조 문구, 청구 상세로 가면 화살표. 같은 목록에 화살표가 하나라도 있으면([slot]) 화살표 자리를 둬 금액 끝선을 맞춘다.
class _PlanRow extends StatelessWidget {
  /// 2026-11-02: 이름 [name], 날짜 라벨 [label], 둘째 줄 [sub], 셋째 줄 [detail], 금액 [amount], 금액 아래 [amountCaption],
  /// 누르기 [onTap](없으면 누를 수 없음), 화살표 자리 [slot]으로 만든다.
  const _PlanRow({
    required this.name,
    required this.label,
    required this.sub,
    required this.detail,
    required this.amount,
    required this.amountCaption,
    required this.onTap,
    required this.slot,
    super.key,
  });

  final String name;
  final String? label;
  final String sub;
  final String? detail;
  final String amount;
  final String? amountCaption;
  final VoidCallback? onTap;
  final bool slot;

  /// 2026-11-02: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final content = Container(
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.symmetric(vertical: PayseSpace.x4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 22 / 15,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    if (label case final label?) StatusLabel(text: label),
                  ],
                ),
                const SizedBox(height: 2),
                Text(sub, style: PayseTypography.caption),
                if (detail case final detail?)
                  Text(
                    detail,
                    style: PayseTypography.caption.copyWith(
                      color: PayseColors.textPrimary,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: PayseSpace.x3),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amount,
                style: PayseTypography.ledgerAmount.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (amountCaption case final caption?)
                Text(caption, style: PayseTypography.caption),
            ],
          ),
          if (onTap != null)
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Icon(
                Icons.chevron_right,
                size: 16,
                color: PayseColors.textSecondary,
              ),
            )
          else if (slot)
            const SizedBox(width: 20),
        ],
      ),
    );
    return onTap == null
        ? content
        : Semantics(
            button: true,
            child: InkWell(onTap: onTap, child: content),
          );
  }
}

/// 2026-11-02: 기간 머리('‹ 제목 ▾ ›'와 범위·기준 시각). 끝에서는 화살표가 꺼진다.
class _PeriodHeader extends StatelessWidget {
  /// 2026-11-02: 기간 [period], 기준 시각 문구 [asOf], 앞뒤 이동 [onPrevious]·[onNext](null이면 비활성), 시트 열기 [onPick]으로
  /// 만든다.
  const _PeriodHeader({
    required this.period,
    required this.asOf,
    required this.onPrevious,
    required this.onNext,
    required this.onPick,
  });

  final PlanPeriod period;
  final String asOf;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onPick;

  /// 2026-11-02: 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    final month = period.kind == PlanPeriodKind.month;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PayseSpace.screenHorizontal,
        PayseSpace.x3,
        PayseSpace.screenHorizontal,
        0,
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                key: const ValueKey('plan-prev'),
                tooltip: month ? '이전 달 보기' : '이전 기간 보기',
                color: PayseColors.textPrimary,
                onPressed: onPrevious,
                icon: const Icon(Icons.chevron_left),
              ),
              Flexible(
                child: TextButton(
                  key: const ValueKey('plan-period'),
                  onPressed: onPick,
                  style: TextButton.styleFrom(
                    foregroundColor: PayseColors.textPrimary,
                    minimumSize: const Size(48, PayseSize.touchMin),
                    textStyle: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(child: Text(period.title)),
                      const Icon(Icons.expand_more, size: 18),
                    ],
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('plan-next'),
                tooltip: month ? '다음 달 보기' : '다음 기간 보기',
                color: PayseColors.textPrimary,
                onPressed: onNext,
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Text(
            '${period.caption} · $asOf',
            key: const ValueKey('plan-range'),
            textAlign: TextAlign.center,
            style: PayseTypography.caption,
          ),
        ],
      ),
    );
  }
}

/// 2026-11-02: 구역 제목과 건수.
class _SectionTitle extends StatelessWidget {
  /// 2026-11-02: 제목 [title]과 건수 [count]로 만든다.
  const _SectionTitle({required this.title, required this.count});

  final String title;
  final int count;

  /// 2026-11-02: 제목 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: PayseSpace.section),
      padding: const EdgeInsets.only(bottom: PayseSpace.x2),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerSection)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
          Text('$count건', style: PayseTypography.caption),
        ],
      ),
    );
  }
}

/// 2026-11-02: 접고 펴는 구역 머리(이미 나간 돈·계산에서 뺀 계좌).
class _Fold extends StatelessWidget {
  /// 2026-11-02: 제목 [title], 건수 [count], 펼침 [open], 누르기 [onTap]으로 만든다.
  const _Fold({
    required this.title,
    required this.count,
    required this.open,
    required this.onTap,
    super.key,
  });

  final String title;
  final int count;
  final bool open;
  final VoidCallback onTap;

  /// 2026-11-02: 머리를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      expanded: open,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          margin: const EdgeInsets.only(top: PayseSpace.x5),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: PayseColors.dividerSection),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: PayseColors.textPrimary,
                  ),
                ),
              ),
              Text('$count건', style: PayseTypography.caption),
              Icon(
                open ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: PayseColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-11-02: 아이콘과 한 줄 문구만 있는 회색 안내 띠(월급 정보 없음).
class _InfoBand extends StatelessWidget {
  /// 2026-11-02: 문구 [text]로 만든다.
  const _InfoBand({required this.text, super.key});

  final String text;

  /// 2026-11-02: 띠를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: PayseSpace.x4),
      padding: const EdgeInsets.symmetric(
        horizontal: PayseSpace.screenHorizontal,
        vertical: PayseSpace.x4,
      ),
      color: PayseColors.insufficientNoticeSurface,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.info_outline,
            size: 18,
            color: PayseColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 13,
                height: 19 / 13,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-11-02: '이전 기간에서 남은 지출 n건' 안내. 누르면 해당 항목 전체 시트를 연다. 실제 출금 여부를 단정하지 않는다.
class _CarryBand extends StatelessWidget {
  /// 2026-11-02: 건수 [count]와 누르기 [onTap]으로 만든다.
  const _CarryBand({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  /// 2026-11-02: 안내를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: InkWell(
        key: const ValueKey('plan-carry'),
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(top: PayseSpace.x4),
          padding: const EdgeInsets.symmetric(
            horizontal: PayseSpace.screenHorizontal,
            vertical: PayseSpace.x4,
          ),
          color: PayseColors.insufficientNoticeSurface,
          child: Row(
            children: [
              const Icon(
                Icons.error_outline,
                size: 18,
                color: PayseColors.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '이전 기간에서 남은 지출 $count건',
                      style: const TextStyle(
                        fontSize: 14,
                        height: 20 / 14,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      '받은 정보 기준으로 남은 금액이 있어요.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 19 / 13,
                        color: PayseColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 16,
                color: PayseColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-11-02: 이전 기간에서 남은 지출 전체(예정일순) 시트.
class _CarrySheet extends StatelessWidget {
  /// 2026-11-02: 줄 생성 [view]와 항목 [lines]로 만든다.
  const _CarrySheet({required this.view, required this.lines});

  final _LineView view;
  final List<calc.ObligationLine> lines;

  /// 2026-11-02: 시트를 반환한다.
  @override
  Widget build(BuildContext context) {
    final slot = lines.any(view.linked);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: PayseSpace.x2),
        Center(
          child: Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: PayseColors.dividerSection,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PayseSpace.screenHorizontal,
            PayseSpace.x2,
            PayseSpace.x2,
            0,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: PayseSpace.x2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '이전 기간에서 남은 지출 ${lines.length}건',
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: PayseColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        '받은 정보 기준으로 남은 금액이 있는 예정 지출이에요.',
                        style: PayseTypography.caption,
                      ),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: '닫기',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, size: 22),
              ),
            ],
          ),
        ),
        Flexible(
          child: ListView(
            key: const ValueKey('plan-carry-list'),
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(
              PayseSpace.screenHorizontal,
              PayseSpace.x4,
              PayseSpace.screenHorizontal,
              34,
            ),
            children: [
              const Divider(height: 1, color: PayseColors.dividerSection),
              for (final l in lines)
                view.row(l, PlanGroup.upcoming, slot: slot),
            ],
          ),
        ),
      ],
    );
  }
}

/// 2026-11-02: 남겨둘 돈 한 묶음(이름·보호 계좌·설정액과 직접 연결한 예정 지출). 실제 적립액을 만들지 않는다.
class _ReserveBlock extends StatelessWidget {
  /// 2026-11-02: 남겨둘 돈 [reserve], 이름 조회 [names], 미해제 배정 [allocations]로 만든다.
  /// 2026-11-03: [allocations]가 null이면 배정 정보를 받지 못한 것이고, [restricted]면 응답의 배정 일부가 접근 제한으로
  /// 생략됐다(어느 남겨둘 돈의 것인지는 알 수 없어 연결이 없다고 단정하지 않는다).
  const _ReserveBlock({
    required this.reserve,
    required this.names,
    required this.allocations,
    required this.restricted,
    super.key,
  });

  final Reserve reserve;
  final SnapshotNames names;
  final List<Allocation>? allocations;
  final bool restricted;

  /// 2026-11-02: 묶음을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: PayseSpace.x4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      reserve.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        height: 22 / 15,
                        fontWeight: FontWeight.w600,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    Text(
                      names.accountShort(reserve.accountId),
                      style: PayseTypography.caption,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: PayseSpace.x3),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatKrw(reserve.amountKrw),
                    style: PayseTypography.ledgerAmount.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Text('설정액', style: PayseTypography.caption),
                ],
              ),
            ],
          ),
          const SizedBox(height: PayseSpace.x3),
          const Text(
            '연결한 예정 지출',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: PayseColors.textSecondary,
            ),
          ),
          if (allocations == null || allocations!.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                allocations == null
                    ? '연결 정보를 받지 못했어요'
                    : restricted
                    ? '보여 드릴 수 있는 연결이 없어요'
                    : '연결한 예정 지출이 없어요',
                key: ValueKey('plan-reserve-links-${reserve.reserveId}'),
                style: PayseTypography.caption,
              ),
            ),
          for (final a in allocations ?? const <Allocation>[])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${names.obligationLabel(a.obligationId)} · '
                      '${names.obligationDue(a.obligationId)} 예정',
                      style: const TextStyle(
                        fontSize: 15,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    '${formatKrw(unreleasedKrw(a))} 배정',
                    style: const TextStyle(
                      fontSize: 15,
                      color: PayseColors.textPrimary,
                      fontFeatures: PayseTypography.tabular,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 2026-11-02: 가운데 안내 문구.
class _Message extends StatelessWidget {
  /// 2026-11-02: 문구 [text]로 만든다.
  const _Message({required this.text, super.key});

  final String text;

  /// 2026-11-02: 문구를 반환한다.
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 72),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 15, color: PayseColors.textSecondary),
      ),
    );
  }
}
