import 'package:flutter/material.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/financial_snapshot.dart';
import '../../data/statement_relations.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart' show institutionName;
import 'composition_bar.dart';
import 'home_calculation.dart';
import 'home_screen.dart' show asOfLabel, insufficientMessage;
import 'overview_links.dart';
import 'overview_pages.dart';

/// 2026-10-26: 02-2 계산 내역(영수증 v4). 홈과 같은 계산 결과 [calculation]만 표시한다.
/// 금액·건수·합계는 계산 결과에서 가져오고, 이름·계좌·날짜는 같은 스냅샷의 원천 값을 그대로 쓴다.
/// 2026-10-31: '계산에 포함한 계좌'(현재 계좌 잔액·남겨둘 돈·예정 지출·참고 내역·쓸 수 있는 돈)와 '계산에 포함하지 않은 계좌'
/// (기본 접힘)로 나눈다(#163). [section]이 있으면 그 항목을 펼친 채 그 위치로 연다. [links]가 있으면 앱 상태가 바뀔 때 새
/// 계산 결과로 다시 그리고, 계좌를 누르면 그 계좌의 입출금을, '계산할 계좌 확인'은 계좌 선택을 연다.
class CalculationDetailScreen extends StatefulWidget {
  /// 2026-10-26: 계산을 마친 홈 결과 [calculation]으로 만든다.
  /// 2026-10-31: 공통 연결 [links]와 펼칠 항목 [section]을 더했다.
  const CalculationDetailScreen({
    super.key,
    required this.calculation,
    this.links,
    this.section,
  });

  final HomeCalculationReady calculation;
  final OverviewLinks? links;
  final CalcSection? section;

  static const String footnote =
      '계획한 지출을 바탕으로 계산한 금액으로, 은행에서 출금할 수 있는 금액과는 다를 수 있어요.';

  /// 2026-10-31: 상태 객체를 반환한다.
  @override
  State<CalculationDetailScreen> createState() =>
      _CalculationDetailScreenState();
}

/// 2026-10-31: 펼쳐 열 항목의 위치 키를 가지고, 처음 그린 뒤 그 항목이 보이게 스크롤한다.
class _CalculationDetailScreenState extends State<CalculationDetailScreen> {
  final GlobalKey _target = GlobalKey(debugLabel: 'detail-section');

  /// 2026-10-31: 펼칠 항목이 있으면 첫 프레임 뒤 그 위치로 옮긴다.
  @override
  void initState() {
    super.initState();
    if (widget.section == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = _target.currentContext;
      if (context != null && context.mounted) {
        Scrollable.ensureVisible(context, alignment: 0.05);
      }
    });
  }

  /// 2026-10-31: 화면을 반환한다. [CalculationDetailScreen.links]가 있으면 지금 계산 결과를 따른다(계산을 마치지 못한
  /// 결과가 오면 연 시점의 결과를 유지한다).
  @override
  Widget build(BuildContext context) {
    final links = widget.links;
    if (links == null) return _page(widget.calculation);
    return ValueListenableBuilder<OverviewState>(
      valueListenable: links.state,
      builder: (context, state, _) => _page(switch (state.calculation) {
        final HomeCalculationReady ready => ready,
        _ => widget.calculation,
      }),
    );
  }

  /// 2026-10-26: 머리·바·영수증·묶음·안내 문장을 세로로 반환한다.
  Widget _page(HomeCalculationReady calculation) {
    final result = calculation.result;
    final snapshot = calculation.snapshot;
    final names = SnapshotNames(snapshot);
    final state = compositionBarStateOf(result);
    final chips = showsCompositionBar(state);
    final awaiting =
        result.salaryCycle?.state == calc.SalaryCycleState.awaitingDeposit;
    final links = widget.links;
    final excluded = [
      for (final a in snapshot.accounts ?? const <Account>[])
        if (!a.included) a,
    ];
    final includedCount =
        result.accountLines?.length ??
        (snapshot.accounts ?? const <Account>[])
            .where((a) => a.included)
            .length;
    return Scaffold(
      backgroundColor: PayseColors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _TopBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: PayseSpace.x8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _padded(_PeriodHeader(result: result), top: PayseSpace.x1),
                    _padded(
                      _ScopeHeading(
                        key: const ValueKey('detail-included-heading'),
                        title: '계산에 포함한 계좌',
                        count: '$includedCount개',
                      ),
                      top: PayseSpace.x6,
                    ),
                    if (state == CompositionBarState.insufficient)
                      _ReceiptNotice.insufficient(
                        message: insufficientMessage(
                          result.insufficient.isEmpty
                              ? null
                              : result.insufficient.first,
                        ),
                      )
                    else
                      _padded(CompositionBar(result: result)),
                    if (awaiting)
                      _ReceiptNotice.awaiting(
                        totalKrw:
                            result
                                .placementTotals?[calc
                                    .ObligationPlacement
                                    .awaitingSalary]
                                ?.totalKrw ??
                            0,
                      ),
                    _padded(
                      _Receipt(
                        result: result,
                        names: names,
                        chips: chips,
                        awaiting: awaiting,
                        section: widget.section,
                        target: _target,
                        onOpenAccount: links == null
                            ? null
                            : (id) => openInstrument(
                                context,
                                links,
                                AccountInstrument(id),
                              ),
                        onSelectAccounts: links?.writer == null
                            ? null
                            : () => changeSelection(context, links!),
                        onShowPlan: switch (links?.onShowPlan) {
                          final show? => (tab) {
                            Navigator.of(context).popUntil((r) => r.isFirst);
                            show(tab);
                          },
                          null => null,
                        },
                      ),
                      top: PayseSpace.x5,
                    ),
                    if (excluded.isNotEmpty)
                      _padded(
                        _ExcludedSection(
                          result: result,
                          names: names,
                          accounts: excluded,
                          onOpenAccount: links == null
                              ? null
                              : (id) => openInstrument(
                                  context,
                                  links,
                                  AccountInstrument(id),
                                ),
                        ),
                        top: PayseSpace.x8,
                      ),
                    _padded(
                      const Text(
                        CalculationDetailScreen.footnote,
                        style: DetailTypography.secondary,
                      ),
                      top: PayseSpace.x6,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 2026-10-26: 화면 좌우 여백 24dp와 위 여백 [top]을 적용한다.
  static Widget _padded(Widget child, {double top = 0}) => Padding(
    padding: EdgeInsets.fromLTRB(
      PayseSpace.screenHorizontal,
      top,
      PayseSpace.screenHorizontal,
      0,
    ),
    child: child,
  );
}

/// 2026-10-31: 대분류 제목('계산에 포함한 계좌 · N개', 17/700).
class _ScopeHeading extends StatelessWidget {
  /// 2026-10-31: 제목 [title]과 개수 [count]로 만든다.
  const _ScopeHeading({super.key, required this.title, required this.count});

  final String title;
  final String count;

  /// 2026-10-31: 제목을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.only(bottom: PayseSpace.x2),
        child: Text.rich(
          TextSpan(
            text: title,
            children: [
              TextSpan(
                text: ' · $count',
                style: DetailTypography.secondary.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          style: const TextStyle(
            fontSize: 17,
            height: 25 / 17,
            fontWeight: FontWeight.w700,
            color: PayseColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// 2026-10-26: 뒤로 가기와 화면 제목.
class _TopBar extends StatelessWidget {
  /// 2026-10-26: 인자 없이 만든다.
  const _TopBar();

  /// 2026-10-26: 높이 56dp 제목 줄을 반환한다. 2026-11-01: 위 12dp를 더해 계좌·카드 탭 제목과 같은 높이에서 시작한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56 + PayseSpace.x3,
      padding: const EdgeInsets.only(top: PayseSpace.x3),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x3),
        child: Row(
          children: [
            IconButton(
              tooltip: '뒤로',
              icon: const Icon(Icons.chevron_left, size: 28),
              color: PayseColors.textPrimary,
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const SizedBox(width: PayseSpace.x1),
            Semantics(
              header: true,
              child: const Text('계산 내역', style: DetailTypography.title),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-26: 계산 기간·기준일·시간축·금융정보 기준 시각.
/// 2026-11-01: 같은 날짜가 여러 줄에 반복돼 정리했다(혜연 요청). 제목은 기간 'M/D – M/D'(17/700), 그 아래 한 줄에
/// '다음 월급일 M/D · M월 D일 HH:mm 기준', 그 아래 시간축. 입금 확인 전에는 제목 옆 '지난 계산 기간' 라벨과 둘째 줄
/// '월급 입금 확인 전'(월급일 당일이면 '오늘 월급일 · 월급 입금 확인 전'), 기간을 모르면 '계산 기간을 정하지 못했어요'다.
class _PeriodHeader extends StatelessWidget {
  /// 2026-10-26: 계산 결과 [result]로 만든다.
  const _PeriodHeader({required this.result});

  final calc.CurrentAmountResult result;

  /// 2026-10-26: 기간 상태에 맞는 머리를 반환한다. 기간을 모르면 시간축을 그리지 않는다.
  @override
  Widget build(BuildContext context) {
    final today = result.context.businessDate;
    final cycle = result.salaryCycle;
    final state = cycle?.state;
    final known =
        state == calc.SalaryCycleState.normal ||
        state == calc.SalaryCycleState.awaitingDeposit;
    final asOf = asOfLabel(result.context.asOf);
    final String title;
    final String sub;
    String? label;
    if (!known) {
      title = '계산 기간을 정하지 못했어요';
      sub = asOf;
    } else {
      final start = cycle!.periodStart;
      final end = cycle.periodEnd!;
      final last = md(end.addDays(-1));
      title = start == null ? '~ $last' : '${md(start)} – $last';
      if (state == calc.SalaryCycleState.normal) {
        sub = '다음 월급일 ${md(end)} · $asOf';
      } else {
        label = '지난 계산 기간';
        sub = cycle.previousPayDate!.date == today
            ? '오늘 월급일 · 월급 입금 확인 전 · $asOf'
            : '월급 입금 확인 전 · $asOf';
      }
    }
    final start = known ? cycle!.periodStart : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          key: const ValueKey('detail-period-title'),
          TextSpan(
            text: title,
            children: [
              if (label != null)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: const EdgeInsets.only(left: PayseSpace.x2),
                    child: StatusLabel(text: label),
                  ),
                ),
            ],
          ),
          style: const TextStyle(
            fontSize: 17,
            height: 25 / 17,
            fontWeight: FontWeight.w700,
            color: PayseColors.textPrimary,
            fontFeatures: PayseTypography.tabular,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          sub,
          key: const ValueKey('detail-period-sub'),
          style: DetailTypography.secondary,
        ),
        if (start != null)
          _Timeline(start: start, end: cycle!.periodEnd!, today: today),
      ],
    );
  }
}

/// 2026-10-26: 구간 시작~월급일 시간축과 기준일 점. 날짜 위치만 그리며 금액과 무관하다.
class _Timeline extends StatelessWidget {
  /// 2026-10-26: 구간 시작 [start], 월급일 [end], 기준일 [today]로 만든다.
  const _Timeline({
    required this.start,
    required this.end,
    required this.today,
  });

  final calc.BusinessDate start;
  final calc.BusinessDate end;
  final calc.BusinessDate today;

  /// 2026-10-26: 기준일의 구간 내 위치(0~1). 기준일이 월급일을 지났으면 끝(1)에 둔다.
  double get fraction {
    final total = daysBetween(start, end);
    if (total <= 0) return 1;
    return (daysBetween(start, today) / total).clamp(0, 1).toDouble();
  }

  /// 2026-10-26: 'M/D 기준' 표시, 선·점, 양 끝 날짜를 반환한다.
  @override
  Widget build(BuildContext context) {
    final f = fraction;
    return Semantics(
      label:
          '계산 기간 ${start.month}월 ${start.day}일부터 월급일 ${end.month}월 ${end.day}일 중 '
          '${today.month}월 ${today.day}일 기준 위치',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: PayseSpace.x3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnchoredLabel(
                key: const ValueKey('timeline-label'),
                fraction: f,
                child: Text(
                  '${md(today)} 기준',
                  style: DetailTypography.timeline.copyWith(
                    fontWeight: FontWeight.w600,
                    color: PayseColors.textPrimary,
                  ),
                ),
              ),
              const SizedBox(height: PayseSpace.x1),
              SizedBox(
                height: 8,
                child: LayoutBuilder(
                  builder: (context, box) {
                    final x = f * box.maxWidth;
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Positioned(
                          left: 0,
                          right: 0,
                          top: 3,
                          height: 2,
                          child: ColoredBox(color: PayseColors.dividerRow),
                        ),
                        Positioned(
                          left: 0,
                          width: x,
                          top: 3,
                          height: 2,
                          child: const ColoredBox(color: PayseColors.scheduled),
                        ),
                        Positioned(
                          left: (x - 4).clamp(0, box.maxWidth - 8).toDouble(),
                          top: 0,
                          width: 8,
                          height: 8,
                          child: const DecoratedBox(
                            decoration: BoxDecoration(
                              color: PayseColors.charcoal,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(md(start), style: DetailTypography.timeline),
                  const SizedBox(width: PayseSpace.x2),
                  Expanded(
                    child: Text(
                      '${md(end)} 월급일',
                      textAlign: TextAlign.right,
                      style: DetailTypography.timeline,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 2026-10-26: 02-2 안내 띠. 반경 없이 화면 폭 전체, 위아래 1px 경계, 아이콘 없음.
class _ReceiptNotice extends StatelessWidget {
  /// 2026-10-26: 정보 부족 사유 [message]를 바 대신 보이는 띠로 만든다.
  const _ReceiptNotice.insufficient({required String message})
    : title = null,
      body = message,
      surface = PayseColors.insufficientNoticeSurface,
      line = PayseColors.borderStrong,
      noticeKey = const ValueKey('detail-insufficient-notice');

  /// 2026-10-26: 입금 확인 후 반영할 지출 합계 [totalKrw](계산 결과)로 입금 대기 띠를 만든다.
  _ReceiptNotice.awaiting({required int totalKrw})
    : title = '아직 월급 입금이 확인되지 않았어요',
      body =
          '아래 지출 ${formatKrw(totalKrw)}은 현재 금액에 포함하지 않았어요. '
          '입금이 확인되면 다음 월급일까지의 지출과 함께 계산해요.',
      surface = PayseColors.awaitingNoticeSurface,
      line = PayseColors.awaitingNoticeBorder,
      noticeKey = const ValueKey('detail-awaiting-notice');

  final String? title;
  final String body;
  final Color surface;
  final Color line;
  final Key noticeKey;

  /// 2026-10-26: 바·범례 바로 아래 20dp에 띠를 반환한다.
  @override
  Widget build(BuildContext context) {
    final heading = title;
    return Padding(
      key: noticeKey,
      padding: const EdgeInsets.only(top: PayseSpace.x5),
      child: Semantics(
        liveRegion: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: surface,
            border: Border.symmetric(horizontal: BorderSide(color: line)),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: PayseSpace.screenHorizontal,
              vertical: heading == null ? PayseSpace.x3 : 14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (heading != null)
                  Text(
                    heading,
                    style: const TextStyle(
                      fontSize: 15,
                      height: 22 / 15,
                      fontWeight: FontWeight.w700,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                Text(
                  body,
                  style: heading == null
                      ? DetailTypography.secondary.copyWith(
                          color: PayseColors.textPrimary,
                        )
                      : PayseTypography.caption,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 2026-10-26: 영수증 본문(계좌 잔액 → 남겨둘 돈 → 예정 지출 → 이중선 → 쓸 수 있는 돈).
/// 2026-10-31: 예정 지출 다음에 입금 확인 후 반영할 지출과 참고 내역(출금 완료·다음 기간 지출, 기본 접힘)을 두고 그 아래에
/// 쓸 수 있는 돈을 둔다. [section] 항목은 펼친 채 시작하고 위치 키 [target]을 붙인다.
class _Receipt extends StatelessWidget {
  /// 2026-10-26: 계산 결과 [result], 이름 조회 [names], 색 칩 표시 여부 [chips], 입금 대기 여부 [awaiting]로 만든다.
  /// 2026-10-31: 펼칠 항목 [section]·위치 키 [target], 계좌 열기 [onOpenAccount], 계좌 선택 열기 [onSelectAccounts]를 더했다.
  const _Receipt({
    required this.result,
    required this.names,
    required this.chips,
    required this.awaiting,
    required this.section,
    required this.target,
    required this.onOpenAccount,
    required this.onSelectAccounts,
    required this.onShowPlan,
  });

  final calc.CurrentAmountResult result;
  final SnapshotNames names;
  final bool chips;
  final bool awaiting;
  final CalcSection? section;
  final GlobalKey target;
  final ValueChanged<String>? onOpenAccount;
  final VoidCallback? onSelectAccounts;

  /// 2026-11-03: 계산 내역을 닫고 계획 탭의 안쪽 탭을 연다(남겨둘 돈·예정 지출 관리 줄). 없으면 줄을 두지 않는다.
  final ValueChanged<PlanTab>? onShowPlan;

  /// 2026-10-31: [s]가 펼칠 항목이면 위치 키를 반환한다.
  Key? _keyOf(CalcSection s) => section == s ? target : null;

  /// 2026-10-26: 영수증 행을 반환한다. 모르는 값은 '계산 불가'로 표시하고 0원으로 바꾸지 않는다.
  @override
  Widget build(BuildContext context) {
    final today = result.context.businessDate;
    final scheduled = [
      for (final line
          in result.obligationLines ?? const <calc.ObligationLine>[])
        if (line.placement == calc.ObligationPlacement.inCurrentPeriod) line,
    ]..sort(_byDue);
    final scheduledCount =
        result
            .placementTotals?[calc.ObligationPlacement.inCurrentPeriod]
            ?.count ??
        0;
    final u = result.u;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1.5, thickness: 1.5, color: PayseColors.charcoal),
        KeyedSubtree(key: _keyOf(CalcSection.balance), child: _accountRow()),
        KeyedSubtree(
          key: _keyOf(CalcSection.reserve),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _reserveRow(),
          ),
        ),
        _ExpandableRow(
          key: const ValueKey('receipt-scheduled'),
          anchor: _keyOf(CalcSection.scheduled),
          initiallyOpen: section == CalcSection.scheduled,
          title: '예정 지출',
          chip: chips ? PayseColors.scheduled : null,
          label: awaiting ? '입금 확인 대기' : null,
          count: awaiting || result.e == null ? null : '$scheduledCount건',
          amount: _deduction(result.e),
          children: [
            for (final line in scheduled)
              _ScheduledItem(
                line: line,
                today: today,
                names: names,
                reserveLines: result.reserveLines,
              ),
            if (onShowPlan case final show?)
              _LinkButton(
                key: const ValueKey('receipt-manage-scheduled'),
                label: '예정 지출 관리',
                onTap: () => show(PlanTab.scheduled),
              ),
          ],
        ),
        _AwaitingGroup(result: result, names: names),
        _ReferenceBlock(result: result, names: names),
        const SizedBox(height: PayseSpace.x5),
        const Divider(height: 1, thickness: 1, color: PayseColors.charcoal),
        const SizedBox(height: 3),
        const Divider(height: 1, thickness: 1, color: PayseColors.charcoal),
        Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: ColorChipLabel(
                  label: '쓸 수 있는 돈',
                  color: chips ? PayseColors.available : null,
                  style: DetailTypography.row,
                ),
              ),
              const SizedBox(width: PayseSpace.x3),
              _AmountText(
                key: const ValueKey('receipt-result'),
                text: u == null ? '계산할 수 없어요' : formatKrw(u),
                semantics: u == null ? '계산할 수 없어요' : spokenKrw(u),
                style: u == null
                    ? DetailTypography.unavailableResult
                    : DetailTypography.result.copyWith(
                        color: u < 0 ? PayseColors.error : null,
                      ),
                maxFraction: 0.7,
              ),
            ],
          ),
        ),
        if (u != null && u < 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '남겨둘 돈과 예정 지출을 모두 확보하려면\n${formatKrw(-u)}이 더 필요해요.',
              textAlign: TextAlign.right,
              style: DetailTypography.secondary,
            ),
          ),
      ],
    );
  }

  /// 2026-10-26: 계좌 잔액 B 행. 펼치면 포함 계좌별 잔액과 월급 계좌 라벨을 보인다.
  /// 2026-10-31: 이름을 '현재 계좌 잔액'으로 바꾸고, 계좌 줄을 누르면 그 계좌의 입출금을 열며 끝에 '계산할 계좌 확인'을 둔다.
  /// 계좌 줄은 첫 줄 계좌 이름 … 잔액 ›, 둘째 줄 '기관 ····끝 4자리 · 월급 계좌'다(#163 후속).
  Widget _accountRow() {
    final lines = result.accountLines;
    final b = result.b;
    final open = onOpenAccount;
    return _ExpandableRow(
      key: const ValueKey('receipt-accounts'),
      initiallyOpen: section == CalcSection.balance,
      title: '현재 계좌 잔액',
      count: lines == null ? null : '${lines.length}개',
      amount: b == null ? null : formatKrw(b),
      children: [
        for (final line in lines ?? const <calc.AccountLine>[])
          _Tappable(
            key: ValueKey('receipt-account-${line.accountId}'),
            onTap: open == null ? null : () => open(line.accountId),
            child: _ItemRow(
              name: names.accountTitle(line.accountId),
              secondary: [
                names.accountShort(line.accountId),
                if (names.isSalaryAccount(line.accountId)) '월급 계좌',
              ].join(' · '),
              amount: formatKrw(line.balanceKrw),
              chevron: open == null ? null : Icons.chevron_right,
            ),
          ),
        if (onSelectAccounts != null)
          _LinkButton(
            key: const ValueKey('receipt-select-accounts'),
            label: '계산할 계좌 고르기',
            onTap: onSelectAccounts!,
          ),
      ],
    );
  }

  /// 2026-10-26: 남겨둘 돈 R−O 행. O가 있으면 배정 설명과 보호액별 내역을, O를 모르면 설정액만 보인다.
  /// 2026-10-31: 펼친 내용 맨 위에 '이체하지 않고 계좌에 남겨둬요'를 한 번만 둔다.
  List<Widget> _reserveRow() {
    final lines = result.reserveLines;
    final known = lines != null && lines.every((l) => l.overlaps != null);
    final rEff = result.rEff;
    final summary = known
        ? [
            for (final l in lines)
              if (l.overlaps!.isNotEmpty) _overlapSummary(l),
          ].join(' ')
        : '';
    final row = _ExpandableRow(
      key: const ValueKey('receipt-reserves'),
      initiallyOpen: section == CalcSection.reserve,
      title: '남겨둘 돈',
      chip: chips ? PayseColors.reserve : null,
      amount: _deduction(rEff),
      subtitle: summary.isEmpty ? null : summary,
      divider: lines == null || known,
      children: [
        if (known && lines.isNotEmpty) ...[
          const Text(_reserveMeaning, style: DetailTypography.secondary),
          for (final l in lines) _ReserveDetail(line: l, names: names),
        ],
        if (onShowPlan case final show?)
          _LinkButton(
            key: const ValueKey('receipt-manage-reserves'),
            label: '남겨둘 돈 관리',
            onTap: () => show(PlanTab.reserves),
          ),
      ],
    );
    if (lines == null || known || lines.isEmpty) return [row];
    return [
      row,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 26, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final l in lines)
              _Nested(
                gap: PayseSpace.x1,
                children: [
                  _ItemRow(
                    name: names.reserveLabel(l.reserveId),
                    secondary: '설정한 금액',
                    amount: formatKrw(l.amountKrw),
                  ),
                  const Text(
                    '예정 지출에 사용할 금액을 확인할 수 없어요.',
                    style: DetailTypography.secondary,
                  ),
                ],
              ),
          ],
        ),
      ),
      const Divider(height: 1, thickness: 1, color: PayseColors.dividerRow),
    ];
  }

  /// 2026-10-26: '○○ N원 중 N원은 예정 지출에 쓸 예정이에요.' 문장. 원천 이름에 조사를 붙이지 않고
  /// 어느 지출인지는 펼침 내역에 둔다. 금액은 계산 결과 값이다.
  /// 2026-11-03: 분류명 대신 실제 용도를 쓴다. 겹친 예정 지출이 1건이면 '… 중 N원은 수리비에 쓸 금액이에요.', 여러 건이면
  /// 예정일이 가장 이른 이름 뒤 '외 n건에'. 조사는 받침과 무관한 '에'로 고정한다(이름이 영문·숫자로 끝나도 맞음).
  String _overlapSummary(calc.ReserveLine line) {
    final due = {
      for (final l in result.obligationLines ?? const <calc.ObligationLine>[])
        l.obligationId: l.dueDate,
    };
    final used =
        [
          for (final o in line.overlaps!)
            if (o.unreleasedKrw > 0) o.obligationId,
        ]..sort(
          (a, b) => switch ((due[a], due[b])) {
            (final x?, final y?) => x.compareTo(y),
            _ => 0,
          },
        );
    final target = used.isEmpty
        ? '예정 지출'
        : used.length == 1
        ? names.obligationLabel(used.single)
        : '${names.obligationLabel(used.first)} 외 ${used.length - 1}건';
    return '${names.reserveLabel(line.reserveId)} ${formatKrw(line.amountKrw)} 중 '
        '${formatKrw(line.usedKrw!)}은 $target에 쓸 금액이에요.';
  }
}

/// 2026-10-31: 남겨둘 돈의 뜻. 실제 이체나 별도 입금이 아니다.
const String _reserveMeaning = '이체하지 않고 계좌에 남겨둬요.';

/// 2026-10-31: 누를 수 있는 줄 감싸기. [onTap]이 없으면 그대로 둔다.
class _Tappable extends StatelessWidget {
  /// 2026-10-31: 내용 [child]와 누르기 [onTap]으로 만든다.
  const _Tappable({super.key, required this.child, required this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  /// 2026-10-31: 줄을 반환한다(터치 최소 48dp).
  @override
  Widget build(BuildContext context) {
    final tap = onTap;
    if (tap == null) return child;
    return Semantics(
      button: true,
      child: InkWell(
        onTap: tap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: PayseSize.touchMin),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      ),
    );
  }
}

/// 2026-10-31: 밑줄 글자 버튼('계산할 계좌 확인 ›', 터치 48dp).
class _LinkButton extends StatelessWidget {
  /// 2026-10-31: 문구 [label]과 누르기 [onTap]으로 만든다.
  const _LinkButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  /// 2026-10-31: 버튼을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          minimumSize: const Size(44, PayseSize.touchMin),
          padding: EdgeInsets.zero,
          foregroundColor: PayseColors.textPrimary,
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                decoration: TextDecoration.underline,
                decorationColor: PayseColors.borderStrong,
              ),
            ),
            const Icon(Icons.chevron_right, size: 18),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-26: 차감 금액 표기. 0원이 아니면 앞에 −를 붙이고, 값이 없으면 null(계산 불가)이다.
String? _deduction(int? amountKrw) => amountKrw == null
    ? null
    : amountKrw == 0
    ? formatKrw(0)
    : formatKrw(-amountKrw);

/// 2026-10-26: 예정일 순, 같으면 의무 ID 순.
int _byDue(calc.ObligationLine a, calc.ObligationLine b) {
  final byDate = a.dueDate.compareTo(b.dueDate);
  return byDate != 0 ? byDate : a.obligationId.compareTo(b.obligationId);
}

/// 2026-10-26: 보호액 한 건의 펼침 내역. 배정이 없으면 이름(원천 그대로)·계좌·금액 한 줄,
/// 있으면 설정 금액·예정 지출에 쓸 금액·계속 남겨둘 금액이다. 원천 이름을 문장에 끼워 넣지 않는다.
class _ReserveDetail extends StatelessWidget {
  /// 2026-10-26: 계산 결과의 보호액 근거 [line]과 이름 조회 [names]로 만든다.
  const _ReserveDetail({required this.line, required this.names});

  final calc.ReserveLine line;
  final SnapshotNames names;

  /// 2026-10-26: 보호액 내역을 반환한다.
  @override
  Widget build(BuildContext context) {
    final label = names.reserveLabel(line.reserveId);
    final account = names.accountShort(line.accountId);
    final overlaps = line.overlaps!;
    if (overlaps.isEmpty) {
      return _ItemRow(
        name: label,
        inlineSecondary: account,
        amount: formatKrw(line.amountKrw),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text.rich(
          TextSpan(
            text: label,
            children: [
              TextSpan(text: ' $account', style: DetailTypography.secondary),
            ],
          ),
          style: DetailTypography.body.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: PayseSpace.x3),
        _Nested(
          children: [
            _ItemRow(name: '설정한 금액', amount: formatKrw(line.amountKrw)),
            for (final o in overlaps)
              _ItemRow(
                name: names.obligationLabel(o.obligationId),
                secondary:
                    '예정 지출에 쓸 금액 · 예정일 ${names.obligationDue(o.obligationId)}',
                amount: formatKrw(-o.unreleasedKrw),
              ),
            const Divider(
              height: 1,
              thickness: 1,
              color: PayseColors.dividerSection,
            ),
            _ItemRow(
              name: '계속 남겨둘 금액',
              amount: formatKrw(line.effectiveKrw!),
              strong: true,
            ),
          ],
        ),
      ],
    );
  }
}

/// 2026-10-26: 현재 구간 예정 지출 한 건.
/// 2026-10-31: 남은 금액을 대표 금액으로 두고, 일부 납부한 항목은 그 아래에 처음 금액·납부한 금액을 함께 보인다(남은 금액을
/// 다시 쓰지 않음). 출금 계좌를 보조 줄에 둔다.
class _ScheduledItem extends StatelessWidget {
  /// 2026-10-26: 의무 근거 [line], 기준일 [today], 이름 조회 [names], 보호액 근거 [reserveLines]로 만든다.
  const _ScheduledItem({
    required this.line,
    required this.today,
    required this.names,
    required this.reserveLines,
  });

  final calc.ObligationLine line;
  final calc.BusinessDate today;
  final SnapshotNames names;
  final List<calc.ReserveLine>? reserveLines;

  /// 2026-10-26: 항목 한 줄(일부 납부면 처음 금액·납부한 금액 포함)을 반환한다.
  @override
  Widget build(BuildContext context) {
    final due = line.dueDate;
    final overdue = due.isBefore(today);
    final funding = [
      for (final r in reserveLines ?? const <calc.ReserveLine>[])
        if ((r.overlaps ?? const <calc.ReserveOverlap>[]).any(
          (o) => o.obligationId == line.obligationId,
        ))
          '${names.reserveLabel(r.reserveId)}에서 사용 예정',
    ];
    final account = names.obligationAccount(line.obligationId);
    final partial = line.settledKrw > 0;
    final name = names.obligationLabel(line.obligationId);
    final item = _ItemRow(
      name: name,
      label: partial ? '일부 출금' : dueLabel(due, today),
      secondary: [
        partial && overdue ? '예정일 ${md(due)} 지남' : '예정일 ${md(due)}',
        if (account.isNotEmpty) account,
        ...funding,
      ].join(' · '),
      amount: formatKrw(line.remainingKrw),
    );
    if (!partial) return item;
    return Column(
      key: ValueKey('scheduled-partial-${line.obligationId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        item,
        const SizedBox(height: PayseSpace.x2),
        _Nested(
          gap: PayseSpace.x2,
          children: [
            _ItemRow(name: '처음 금액', amount: formatKrw(line.amountKrw)),
            _ItemRow(
              name: '납부한 금액',
              secondary: names.settlementCaption(line.obligationId),
              amount: formatKrw(line.settledKrw),
            ),
          ],
        ),
      ],
    );
  }
}

/// 2026-10-26: 입금 확인 후 반영할 지출. 0건이면 그리지 않는다.
class _AwaitingGroup extends StatelessWidget {
  /// 2026-10-31: 계산 결과 [result]와 이름 조회 [names]로 만든다.
  const _AwaitingGroup({required this.result, required this.names});

  final calc.CurrentAmountResult result;
  final SnapshotNames names;

  /// 2026-10-31: 묶음을 반환한다.
  @override
  Widget build(BuildContext context) {
    final total =
        result.placementTotals?[calc.ObligationPlacement.awaitingSalary];
    if (total == null) return const SizedBox.shrink();
    final today = result.context.businessDate;
    return _ExpandableRow(
      key: const ValueKey('group-awaiting'),
      title: '입금 확인 후 반영할 지출',
      count: '${total.count}건',
      amount: formatKrw(total.totalKrw),
      weight: FontWeight.w600,
      children: [
        for (final l in _at(result, calc.ObligationPlacement.awaitingSalary))
          _ItemRow(
            name: names.obligationLabel(l.obligationId),
            label: l.dueDate == today ? '오늘' : '예정일 지남',
            secondary: '예정일 ${md(l.dueDate)}',
            amount: formatKrw(l.remainingKrw),
          ),
      ],
    );
  }
}

/// 2026-10-31: 결과 [result]에서 위치 [p]의 의무를 예정일 순으로 반환한다.
List<calc.ObligationLine> _at(
  calc.CurrentAmountResult result,
  calc.ObligationPlacement p,
) => [
  for (final l in result.obligationLines ?? const <calc.ObligationLine>[])
    if (l.placement == p) l,
]..sort(_byDue);

/// 2026-10-31: 참고 내역(#163). '쓸 수 있는 돈' 위, 포함 계좌 묶음 안의 옅은 바탕 접힘 영역이며 따로 빼지 않는 금액이다.
/// 출금 완료(전액 납부가 확인돼 현재 잔액에 반영된 계산 포함 계좌의 예정 지출)와 다음 기간 지출(다음 월급일부터)을 각자
/// 묶고, 두 묶음을 합친 금액을 만들지 않는다. 출금 완료는 화면에서 더하지 않도록 건수만 보인다. 둘 다 없으면 그리지 않는다.
class _ReferenceBlock extends StatefulWidget {
  /// 2026-10-31: 계산 결과 [result]와 이름 조회 [names]로 만든다.
  const _ReferenceBlock({required this.result, required this.names});

  final calc.CurrentAmountResult result;
  final SnapshotNames names;

  /// 2026-10-31: 상태 객체를 반환한다.
  @override
  State<_ReferenceBlock> createState() => _ReferenceBlockState();
}

/// 2026-10-31: 펼침 상태(기본 접힘).
class _ReferenceBlockState extends State<_ReferenceBlock> {
  bool _open = false;

  /// 2026-10-31: 참고 내역을 반환한다.
  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final names = widget.names;
    final paid = [
      for (final l in _at(result, calc.ObligationPlacement.settled))
        if (names.isIncludedObligation(l.obligationId)) l,
    ];
    final nextTotal =
        result.placementTotals?[calc.ObligationPlacement.outsidePeriod];
    if (paid.isEmpty && nextTotal == null) return const SizedBox.shrink();
    final end = result.salaryCycle?.periodEnd;
    return Container(
      key: const ValueKey('detail-reference'),
      margin: const EdgeInsets.only(top: PayseSpace.x4),
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            button: true,
            expanded: _open,
            child: InkWell(
              key: const ValueKey('detail-reference-toggle'),
              onTap: () => setState(() => _open = !_open),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 56),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 18,
                      color: PayseColors.textPrimary,
                    ),
                    const SizedBox(width: PayseSpace.x2),
                    const Text(
                      '참고 내역',
                      style: TextStyle(
                        fontSize: 15,
                        height: 22 / 15,
                        fontWeight: FontWeight.w700,
                        color: PayseColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: PayseSpace.x2),
                    const Expanded(
                      child: Text(
                        '따로 빼지 않아요',
                        style: DetailTypography.secondary,
                      ),
                    ),
                    Icon(
                      _open ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: PayseColors.textPrimary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_open) ...[
            if (paid.isNotEmpty)
              _ExpandableRow(
                key: const ValueKey('group-settled'),
                title: '출금 완료',
                count: '${paid.length}건',
                amount: null,
                hideAmount: true,
                subtitle: '계좌에서 이미 빠져나갔어요',
                weight: FontWeight.w600,
                divider: nextTotal != null,
                children: [
                  for (final l in paid)
                    _ItemRow(
                      name: names.obligationLabel(l.obligationId),
                      secondary: names.settlementCaption(l.obligationId),
                      amount: formatKrw(l.settledKrw),
                    ),
                ],
              ),
            if (nextTotal != null)
              _ExpandableRow(
                key: const ValueKey('group-next'),
                title: '다음 기간 지출',
                count: '${nextTotal.count}건',
                amount: formatKrw(nextTotal.totalKrw),
                subtitle: end == null ? null : '${md(end)}부터',
                weight: FontWeight.w600,
                divider: false,
                children: [
                  for (final l in _at(
                    result,
                    calc.ObligationPlacement.outsidePeriod,
                  ))
                    _ItemRow(
                      name: names.obligationLabel(l.obligationId),
                      secondary: [
                        '예정일 ${md(l.dueDate)}',
                        if (names.obligationAccount(l.obligationId) case final a
                            when a.isNotEmpty)
                          a,
                      ].join(' · '),
                      amount: formatKrw(l.remainingKrw),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

/// 2026-10-31: '계산에 포함하지 않은 계좌' 대분류(기본 접힘). 각 계좌의 현재 잔액(원천 값, 화면에서 더하지 않음) → 그 계좌의
/// 입출금, 제외 계좌 지출. 위 계산에 섞지 않는다.
class _ExcludedSection extends StatefulWidget {
  /// 2026-10-31: 계산 결과 [result], 이름 조회 [names], 제외 계좌 [accounts], 계좌 열기 [onOpenAccount]로 만든다.
  const _ExcludedSection({
    required this.result,
    required this.names,
    required this.accounts,
    required this.onOpenAccount,
  });

  final calc.CurrentAmountResult result;
  final SnapshotNames names;
  final List<Account> accounts;
  final ValueChanged<String>? onOpenAccount;

  /// 2026-10-31: 상태 객체를 반환한다.
  @override
  State<_ExcludedSection> createState() => _ExcludedSectionState();
}

/// 2026-10-31: 펼침 상태(기본 접힘).
class _ExcludedSectionState extends State<_ExcludedSection> {
  bool _open = false;

  /// 2026-10-31: 대분류를 반환한다.
  @override
  Widget build(BuildContext context) {
    final names = widget.names;
    final open = widget.onOpenAccount;
    final excluded = widget
        .result
        .placementTotals?[calc.ObligationPlacement.excludedAccount];
    return Column(
      key: const ValueKey('detail-excluded'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 1, thickness: 1, color: PayseColors.borderStrong),
        Semantics(
          button: true,
          expanded: _open,
          child: InkWell(
            key: const ValueKey('detail-excluded-toggle'),
            onTap: () => setState(() => _open = !_open),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Row(
                children: [
                  Expanded(
                    child: _ScopeHeading(
                      title: '계산에 포함하지 않은 계좌',
                      count: '${widget.accounts.length}개',
                    ),
                  ),
                  Icon(
                    _open ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                    color: PayseColors.textPrimary,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_open) ...[
          for (final a in widget.accounts)
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: PayseColors.dividerRow),
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: PayseSpace.x2),
              child: _Tappable(
                key: ValueKey('excluded-account-${a.accountId}'),
                onTap: open == null ? null : () => open(a.accountId),
                child: _ItemRow(
                  name: names.accountTitle(a.accountId),
                  secondary: names.accountShort(a.accountId),
                  amount: a.balanceKrw == null
                      ? '잔액 미확인'
                      : formatKrw(a.balanceKrw!),
                  chevron: open == null ? null : Icons.chevron_right,
                ),
              ),
            ),
          if (excluded != null)
            _ExpandableRow(
              key: const ValueKey('group-excluded'),
              title: '제외 계좌 지출',
              count: '${excluded.count}건',
              amount: formatKrw(excluded.totalKrw),
              subtitle: '쓸 수 있는 돈을 계산할 때 빼지 않았어요.',
              weight: FontWeight.w600,
              children: [
                for (final l in _at(
                  widget.result,
                  calc.ObligationPlacement.excludedAccount,
                ))
                  _ItemRow(
                    name: names.obligationLabel(l.obligationId),
                    secondary:
                        '예정일 ${md(l.dueDate)} · ${names.obligationAccount(l.obligationId)}',
                    amount: formatKrw(l.remainingKrw),
                  ),
              ],
            ),
        ],
      ],
    );
  }
}

/// 2026-10-26: 영수증·묶음의 한 행. [children]이 있으면 눌러서 펼치고 접는다(최소 높이 56dp).
class _ExpandableRow extends StatefulWidget {
  /// 2026-10-26: 제목 [title], 색 칩 [chip], 상태 라벨 [label], 건수 [count], 금액 [amount](null이면 '계산 불가'),
  /// 보조 문장 [subtitle], 제목 굵기 [weight], 펼침 내용 [children],
  /// 아래 구분선 [divider]로 만든다.
  /// 2026-10-31: 처음 펼침 [initiallyOpen], 머리에 붙일 위치 키 [anchor], 금액 칸 비우기 [hideAmount]를 더했다.
  const _ExpandableRow({
    super.key,
    this.initiallyOpen = false,
    this.anchor,
    this.hideAmount = false,
    required this.title,
    this.chip,
    this.label,
    this.count,
    required this.amount,
    this.subtitle,
    this.weight = FontWeight.w700,
    this.children = const [],
    this.divider = true,
  });

  final String title;
  final Color? chip;
  final String? label;
  final String? count;
  final String? amount;
  final String? subtitle;
  final FontWeight weight;
  final List<Widget> children;
  final bool divider;
  final bool initiallyOpen;
  final Key? anchor;
  final bool hideAmount;

  /// 2026-10-26: 펼침 상태 객체를 반환한다.
  @override
  State<_ExpandableRow> createState() => _ExpandableRowState();
}

/// 2026-10-26: 행의 펼침 상태(처음에는 접힘).
class _ExpandableRowState extends State<_ExpandableRow> {
  late bool _open = widget.initiallyOpen;

  /// 2026-10-26: 행과 펼친 내용을 반환한다.
  @override
  Widget build(BuildContext context) {
    final w = widget;
    final expandable = w.children.isNotEmpty;
    final open = expandable && _open;
    final style = DetailTypography.row.copyWith(fontWeight: w.weight);
    final amount = w.amount;
    final head = ConstrainedBox(
      key: w.anchor,
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      text: w.title,
                      children: [
                        if (w.chip != null)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: SizedBox(
                                width: 8,
                                height: 8,
                                child: ColoredBox(color: w.chip!),
                              ),
                            ),
                          ),
                        if (w.count != null)
                          TextSpan(
                            text: ' · ${w.count}',
                            style: DetailTypography.secondary.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        if (w.label != null)
                          WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: StatusLabel(text: w.label!),
                            ),
                          ),
                      ],
                    ),
                    style: style,
                  ),
                ),
                const SizedBox(width: PayseSpace.x2),
                if (!w.hideAmount)
                  _AmountText(
                    text: amount ?? '계산 불가',
                    semantics: amount ?? '계산 불가',
                    style: amount == null
                        ? style.copyWith(color: PayseColors.textSecondary)
                        : style,
                  ),
                const SizedBox(width: PayseSpace.x2),
                SizedBox(
                  width: 18,
                  child: expandable
                      ? Icon(
                          open ? Icons.expand_less : Icons.expand_more,
                          size: 18,
                          color: PayseColors.textPrimary,
                        )
                      : null,
                ),
              ],
            ),
            if (w.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, right: 26),
                child: Text(w.subtitle!, style: DetailTypography.secondary),
              ),
          ],
        ),
      ),
    );
    const line = Divider(
      height: 1,
      thickness: 1,
      color: PayseColors.dividerRow,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (expandable)
          Semantics(
            button: true,
            expanded: open,
            child: InkWell(
              onTap: () => setState(() => _open = !_open),
              child: head,
            ),
          )
        else
          head,
        if (open) ...[
          line,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 26, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < w.children.length; i++) ...[
                  if (i > 0) const SizedBox(height: PayseSpace.x3),
                  w.children[i],
                ],
              ],
            ),
          ),
        ],
        if (w.divider) line,
      ],
    );
  }
}

/// 2026-10-26: 펼친 내용 안의 한 줄. 이름(+계좌 끝자리·상태 라벨)과 보조 줄 … 금액. 금액은 잘리지 않는다.
class _ItemRow extends StatelessWidget {
  /// 2026-10-26: 이름 [name], 이름 뒤 보조 글자 [inlineSecondary], 상태 라벨 [label], 보조 줄 [secondary],
  /// 금액 [amount], 굵게 [strong], 오른쪽 화살표 [chevron]으로 만든다.
  const _ItemRow({
    required this.name,
    this.inlineSecondary,
    this.label,
    this.secondary,
    required this.amount,
    this.strong = false,
    this.chevron,
  });

  final String name;
  final String? inlineSecondary;
  final String? label;
  final String? secondary;
  final String amount;
  final bool strong;
  final IconData? chevron;

  /// 2026-10-26: 한 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final style = strong
        ? DetailTypography.body.copyWith(fontWeight: FontWeight.w700)
        : DetailTypography.body;
    return Row(
      crossAxisAlignment: chevron == Icons.chevron_right
          ? CrossAxisAlignment.center
          : CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  text: name,
                  children: [
                    if (inlineSecondary != null)
                      TextSpan(
                        text: ' $inlineSecondary',
                        style: DetailTypography.secondary,
                      ),
                    if (label != null)
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: StatusLabel(text: label!),
                        ),
                      ),
                  ],
                ),
                style: style,
              ),
              if (secondary != null)
                Text(secondary!, style: DetailTypography.secondary),
            ],
          ),
        ),
        const SizedBox(width: PayseSpace.x3),
        _AmountText(text: amount, semantics: amount, style: style),
        if (chevron != null) ...[
          const SizedBox(width: PayseSpace.x2),
          Icon(chevron, size: 18, color: PayseColors.textPrimary),
        ],
      ],
    );
  }
}

/// 2026-10-26: 왼쪽 2dp 선과 12dp 들여쓰기로 묶은 하위 내역.
class _Nested extends StatelessWidget {
  /// 2026-10-26: 하위 줄 [children]과 줄 간격 [gap]으로 만든다.
  const _Nested({required this.children, this.gap = 10});

  final List<Widget> children;
  final double gap;

  /// 2026-10-26: 들여쓴 묶음을 반환한다.
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        border: Border(
          left: BorderSide(color: PayseColors.dividerRow, width: 2),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.only(left: PayseSpace.x3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) SizedBox(height: gap),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// 2026-10-26: 한 줄 금액. 행 폭의 [maxFraction]을 넘으면 줄바꿈·말줄임 없이 비율 축소한다.
class _AmountText extends StatelessWidget {
  /// 2026-10-26: 표시 [text], 읽기 문장 [semantics], 글자 [style], 최대 폭 비율 [maxFraction]으로 만든다.
  const _AmountText({
    super.key,
    required this.text,
    required this.semantics,
    required this.style,
    this.maxFraction = 0.6,
  });

  final String text;
  final String semantics;
  final TextStyle style;
  final double maxFraction;

  /// 2026-10-26: 축소 가능한 금액을 반환한다.
  @override
  Widget build(BuildContext context) {
    final width =
        MediaQuery.sizeOf(context).width - PayseSpace.screenHorizontal * 2;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: width * maxFraction),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerRight,
        child: Text(
          text,
          maxLines: 1,
          softWrap: false,
          semanticsLabel: semantics,
          style: style,
        ),
      ),
    );
  }
}

/// 2026-10-26: 중립 상태 라벨(design.md §5). surfaceMuted 바탕, 높이 22·좌우 8·반경 8, 13/500 textSecondary.
class StatusLabel extends StatelessWidget {
  /// 2026-10-26: 라벨 글자 [text]로 만든다.
  const StatusLabel({super.key, required this.text});

  final String text;

  /// 2026-10-26: 누를 수 없는 라벨을 반환한다.
  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: PayseColors.surfaceMuted,
        borderRadius: BorderRadius.circular(PayseRadius.sm),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: PayseSpace.x2),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            height: 22 / 13,
            fontWeight: FontWeight.w500,
            color: PayseColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 2026-10-26: 스냅샷의 이름·계좌·날짜 원천 값 조회. 금액을 계산하지 않는다.
class SnapshotNames {
  /// 2026-10-26: 계산에 쓴 스냅샷 [snapshot]으로 만든다.
  SnapshotNames(this.snapshot)
    : _accounts = {
        for (final a in snapshot.accounts ?? <Account>[]) a.accountId: a,
      },
      _obligations = {
        for (final o in snapshot.obligations ?? <Obligation>[])
          o.obligationId: o,
      },
      _reserves = {
        for (final r in snapshot.reserves ?? <Reserve>[]) r.reserveId: r,
      },
      _relations = StatementRelations(snapshot);

  final FinancialSnapshot snapshot;
  final Map<String, Account> _accounts;
  final Map<String, Obligation> _obligations;
  final Map<String, Reserve> _reserves;
  final StatementRelations _relations;

  /// 2026-10-26: 계좌 이름(별명이 있으면 별명, 없으면 '기관 상품명').
  String accountName(String accountId) {
    final a = _accounts[accountId]!;
    return a.nickname ??
        '${institutionName(snapshot, a.institutionCode)} ${a.productName}';
  }

  /// 2026-10-31: 기관을 둘째 줄에 따로 쓰는 계좌 줄의 이름(별명이 있으면 별명, 없으면 상품명).
  String accountTitle(String accountId) {
    final a = _accounts[accountId]!;
    return a.nickname ?? a.productName;
  }

  /// 2026-10-26: 계좌 번호 끝 4자리 표기('····0001').
  String maskedTail(String accountId) {
    final masked = _accounts[accountId]!.maskedNumber;
    return '····${masked.length <= 4 ? masked : masked.substring(masked.length - 4)}';
  }

  /// 2026-10-26: 기관 이름과 끝 4자리('국민은행 ····0001').
  String accountShort(String accountId) {
    final a = _accounts[accountId];
    if (a == null) return '';
    return '${institutionName(snapshot, a.institutionCode)} ${maskedTail(accountId)}';
  }

  /// 2026-10-26: 월급 설정 계좌면 true.
  bool isSalaryAccount(String accountId) =>
      snapshot.settings?.salary.salaryAccountId == accountId;

  /// 2026-10-26: 보호액 이름.
  String reserveLabel(String reserveId) =>
      _reserves[reserveId]?.label ?? '남겨둘 돈';

  /// 2026-10-26: 의무 이름.
  String obligationLabel(String obligationId) =>
      _obligations[obligationId]?.label ?? '예정 지출';

  /// 2026-10-26: 의무 예정일 'M/D'.
  String obligationDue(String obligationId) {
    final due = _obligations[obligationId]?.dueDate;
    return due == null ? '' : mdText(due);
  }

  /// 2026-10-26: 의무 출금 계좌 표기.
  String obligationAccount(String obligationId) {
    final o = _obligations[obligationId];
    return o == null ? '' : accountShort(o.withdrawalAccountId);
  }

  /// 2026-10-26: 의무 출금 계좌가 계산 포함 계좌면 true(계산 패키지의 정산 합계와 같은 기준).
  bool isIncludedObligation(String obligationId) {
    final o = _obligations[obligationId];
    return o != null && (_accounts[o.withdrawalAccountId]?.included ?? false);
  }

  /// 2026-10-26: 의무의 유효 정산 거래에서 확인되는 실제 출금일과 출금 계좌('10/16 출금 · 국민은행 ····0001').
  /// 원천 거래의 withdrawalDate·accountId만 쓰고 예정일·의무 계좌·기장일로 채우지 않는다. 둘 다 모르면 null이다.
  String? settlementCaption(String obligationId) {
    final dates = <String>[];
    final accounts = <String>[];
    for (final tx in _relations.settledTransactions(obligationId)) {
      final date = tx.withdrawalDate;
      if (date != null && !dates.contains(mdText(date))) {
        dates.add(mdText(date));
      }
      final account = tx.accountId;
      if (account != null && !accounts.contains(account)) {
        accounts.add(account);
      }
    }
    final parts = [
      if (dates.isNotEmpty) '${dates.join(', ')} 출금',
      for (final a in accounts) accountShort(a),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// 2026-10-26: 업무 날짜 [date]를 'M/D'로 쓴다.
String md(calc.BusinessDate date) => '${date.month}/${date.day}';

/// 2026-10-26: 'YYYY-MM-DD'(시각이 붙어도 앞 10자) 문자열 [text]를 'M/D'로 쓴다.
String mdText(String text) {
  final parts = text.substring(0, 10).split('-');
  return '${int.parse(parts[1])}/${int.parse(parts[2])}';
}

/// 2026-10-26: [from]에서 [to]까지의 날짜 수(음수 가능).
int daysBetween(calc.BusinessDate from, calc.BusinessDate to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;

/// 2026-10-26: 현재 구간 예정 지출의 날짜 라벨. 기준일 전이면 'D-n', 당일 '오늘', 지났으면 '예정일 지남'.
String dueLabel(calc.BusinessDate due, calc.BusinessDate today) {
  final days = daysBetween(today, due);
  if (days > 0) return 'D-$days';
  if (days == 0) return '오늘';
  return '예정일 지남';
}

/// 2026-10-26: 기준 시각 [asOf](오프셋 포함)를 서울 시각 'M/D HH:mm'으로 쓴다.
String financialAsOfLabel(String asOf) {
  final seoul = DateTime.parse(asOf).toUtc().add(const Duration(hours: 9));
  final hh = seoul.hour.toString().padLeft(2, '0');
  final mm = seoul.minute.toString().padLeft(2, '0');
  return '${seoul.month}/${seoul.day} $hh:$mm';
}
