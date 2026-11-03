import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart';
import 'calculation_detail_screen.dart' show md;
import 'home_calculation.dart';
import 'home_screen.dart' show asOfLabel;
import 'overview_links.dart';
import 'overview_pages.dart';
import 'period_flow.dart';
import 'pull_refresh.dart';
import 'tab_header.dart';
import 'transaction_feed.dart';
import 'transaction_query.dart';
import 'transaction_rules.dart';
import 'transaction_sheets.dart';
import 'transactions_screen.dart';

/// 2026-10-31: 이번 기간 내역(#163). 계산에 포함한 계좌와 그 계좌에서 대금이 나가는 카드의 실제 거래를, 기존 계산 결과의 월급
/// 주기 동안 날짜 최신순으로 보인다. 근거 있는 내 계좌 이체는 한 줄로 묶는다. 예정 지출을 섞지 않고, 거래마다 쓸 수 있는 돈
/// 변화를 계산하지 않는다. 급여 확인 상태·계산 결과를 이 화면에서 판정하지 않는다.
class PeriodFlowScreen extends StatefulWidget {
  /// 2026-10-31: 현재 계산 [calculation], 함께 쓰는 거래 수집 [feed], 공통 연결 [links], 전체 거래로 가기 [onShowAll]로 만든다.
  const PeriodFlowScreen({
    required this.calculation,
    required this.feed,
    required this.links,
    required this.onShowAll,
    super.key,
  });

  final HomeCalculation calculation;
  final TransactionFeed feed;
  final OverviewLinks links;
  final VoidCallback onShowAll;

  /// 2026-10-31: 상태 객체를 반환한다.
  @override
  State<PeriodFlowScreen> createState() => _PeriodFlowScreenState();
}

/// 2026-10-31: 거래 종류 선택과 스크롤을 가진다(다른 하단 탭에 다녀와도 유지).
class _PeriodFlowScreenState extends State<PeriodFlowScreen> {
  FlowKind _kind = FlowKind.all;
  final ScrollController _scroll = ScrollController();

  /// 2026-10-31: 수집 상태 변경을 듣는다.
  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_changed);
  }

  /// 2026-10-31: 수집 상태 객체가 바뀌면 새 객체를 듣는다.
  @override
  void didUpdateWidget(covariant PeriodFlowScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.feed != widget.feed) {
      oldWidget.feed.removeListener(_changed);
      widget.feed.addListener(_changed);
    }
  }

  /// 2026-10-31: 수집 상태 변경을 화면에 반영한다.
  void _changed() => setState(() {});

  /// 2026-10-31: 듣기를 멈추고 스크롤을 폐기한다.
  @override
  void dispose() {
    widget.feed.removeListener(_changed);
    _scroll.dispose();
    super.dispose();
  }

  FinancialSnapshot get _snap => widget.calculation.snapshot;

  /// 2026-10-31: 거래 종류 시트를 연다.
  Future<void> _pickKind() async {
    final picked = await showPayseSheet<FlowKind>(
      context,
      InfoSheet(
        title: '거래 종류 선택',
        children: [
          for (final k in FlowKind.values)
            ChoiceRow(
              key: ValueKey('flow-kind-${k.name}'),
              title: k.label,
              caption: '',
              selected: k == _kind,
              onTap: () => Navigator.of(context).pop(k),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _kind = picked);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// 2026-10-31: '계좌·카드별 보기' 시트(조회 대상 확인과 개별 조회 진입을 하나로 합침, #163 후속). 계좌 묶음·카드 묶음
  /// (카드는 출금 계좌 함께), 출금 계좌를 확인할 수 없는 카드는 따로 두고 세지 않는다. 누르면 이 화면의 기간으로 개별 조회를
  /// 연다. 아래 '계산할 계좌 바꾸기'만 계산 설정을 바꾸는 저장 화면으로 간다.
  void _showScope(FlowScope scope, FlowPeriod period) {
    final links = widget.links;
    showPayseSheet<void>(
      context,
      Builder(
        builder: (sheet) => InfoSheet(
          title: '계좌·카드별 보기',
          footer: links.writer == null
              ? null
              : SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    key: const ValueKey('flow-change-selection'),
                    onPressed: () {
                      Navigator.of(sheet).pop();
                      changeSelection(context, links);
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: PayseColors.textPrimary,
                      side: const BorderSide(color: PayseColors.borderStrong),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(PayseRadius.sm),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    child: const Text('계산할 계좌 바꾸기'),
                  ),
                ),
          children: [
            GroupCaption('계좌 ${scope.accounts.length}개'),
            for (final a in scope.accounts)
              ChoiceRow(
                key: ValueKey('flow-scope-${a.accountId}'),
                title: accountTitle(a),
                caption: accountTail(_snap, a),
                onTap: () =>
                    _open(sheet, AccountInstrument(a.accountId), period),
              ),
            GroupCaption(
              '카드 ${scope.cards.length}개',
              note: '대금이 나가는 계좌를 따라 포함돼요',
            ),
            for (final c in scope.cards)
              ChoiceRow(
                key: ValueKey('flow-scope-${c.cardId}'),
                title: c.productName,
                caption: instrumentCaption(_snap, CardInstrument(c.cardId)),
                onTap: () => _open(sheet, CardInstrument(c.cardId), period),
              ),
            if (scope.unknownCards.isNotEmpty) ...[
              const SizedBox(height: PayseSpace.x5),
              const Text(
                '포함 여부를 확인할 수 없는 카드',
                key: ValueKey('flow-scope-unknown'),
                style: TextStyle(
                  fontSize: 14,
                  height: 20 / 14,
                  fontWeight: FontWeight.w700,
                  color: PayseColors.textPrimary,
                ),
              ),
              for (final c in scope.unknownCards)
                ChoiceRow(
                  key: ValueKey('flow-scope-unknown-${c.cardId}'),
                  title: c.productName,
                  caption: '····${lastFour(c.maskedNumber)} · 출금 계좌 미확인',
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// 2026-10-31: 시트 [sheet]를 닫고 대상 [instrument]의 조회를 연다. 기간을 알면 그 월급 주기 경계를 그대로 넘기고, 모르면
  /// 개별 조회 기본(이번 달)이다. 바꾸기 범위는 이번 기간 대상이다.
  void _open(BuildContext sheet, Instrument instrument, FlowPeriod period) {
    Navigator.of(sheet).pop();
    openInstrument(
      context,
      widget.links,
      instrument,
      scope: InstrumentScope.period,
      period: switch (period) {
        FlowPeriodKnown(:final start, :final end, :final previous) =>
          PeriodSelection.cycle(
            start: start.toString(),
            end: end.addDays(-1).toString(),
            label: previous ? '지난 계산 기간' : '이번 월급 주기',
          ),
        FlowPeriodUnknown() => null,
      },
    );
  }

  /// 2026-10-31: 한 줄 [item]을 누르면 거래 상세 또는 이체 상세를 연다.
  void _openItem(FlowItem item) {
    switch (item) {
      case FlowRecord(:final transaction):
        showPayseSheet<void>(
          context,
          TransactionDetailSheet(snapshot: _snap, transaction: transaction),
        );
      case final FlowTransfer transfer:
        showPayseSheet<void>(
          context,
          TransferDetailSheet(snapshot: _snap, transfer: transfer),
        );
    }
  }

  /// 2026-10-31: 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    final scope = FlowScope.of(_snap);
    final calculation = widget.calculation;
    final period = FlowPeriod.of(
      calculation is HomeCalculationReady ? calculation.result : null,
    );
    final feed = widget.feed;
    final ready = feed.load == TxLoad.ready;
    final items = ready && period is FlowPeriodKnown
        ? flowItems(
            transactions: feed.all,
            relations: _snap.transactionRelations ?? const [],
            scope: scope,
            period: period,
            kind: _kind,
          )
        : const <FlowItem>[];
    final partial = ready && _partial(scope, feed.coverage);
    return PullRefreshScrollView(
      scrollKey: const ValueKey('period-list'),
      controller: _scroll,
      onRefresh: widget.links.onRefresh,
      slivers: [
        SliverToBoxAdapter(
          child: switch (period) {
            FlowPeriodKnown(:final previous) => TabPurpose(
              key: const ValueKey('flow-purpose'),
              icon: Icons.calendar_month_outlined,
              title: previous ? '지난 계산 기간의 거래' : '이번 월급 주기의 거래',
              description: '계산에 쓰는 계좌와 연결 카드의 내역이에요.',
            ),
            FlowPeriodUnknown() => const TabPurpose(
              key: ValueKey('flow-purpose'),
              icon: Icons.calendar_month_outlined,
              title: '이번 기간 내역',
            ),
          },
        ),
        if (feed.stale)
          SliverToBoxAdapter(
            child: NoticeBand(
              key: const ValueKey('flow-band-stale'),
              title: '새로고침하지 못했어요',
              body: '이전 정보를 보여드려요.',
              onRetry: feed.collect,
            ),
          ),
        if (partial)
          const SliverToBoxAdapter(
            child: NoticeBand(
              key: ValueKey('flow-band-partial'),
              title: '일부 거래 내역만 확인할 수 있어요',
              body: '금융사에서 일부 기간의 거래 내역을 받지 못했어요. 목록에 없는 거래가 있을 수 있어요.',
            ),
          ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(
            horizontal: PayseSpace.screenHorizontal,
          ),
          sliver: SliverList.list(
            children: [
              const SizedBox(height: PayseSpace.x2),
              if (period is FlowPeriodKnown) ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: tabKeyLineHeight,
                  ),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _PeriodTitle(period: period),
                  ),
                ),
                Text(
                  feed.load == TxLoad.loading
                      ? '거래 내역을 불러오는 중이에요'
                      : asOfLabel(_snap.asOf),
                  key: const ValueKey('flow-basis'),
                  style: PayseTypography.caption,
                ),
                const SizedBox(height: PayseSpace.x1),
                TabLinkRow(
                  key: const ValueKey('flow-pick-instrument'),
                  label: '계좌·카드별 보기',
                  trailing:
                      '계좌 ${scope.accounts.length}개 · 카드 ${scope.cards.length}개',
                  onTap: () => _showScope(scope, period),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TxChip(
                    key: const ValueKey('flow-chip-kind'),
                    label: _kind.label,
                    onTap: _pickKind,
                  ),
                ),
              ],
              ..._body(period, items, scope),
              const SizedBox(height: PayseSpace.x6),
            ],
          ),
        ),
      ],
    );
  }

  /// 2026-10-31: 대상 계좌·카드 중 일부 기간만 조회된(partial·failed) 것이 있으면 true다.
  bool _partial(FlowScope scope, List<Coverage> coverage) => coverage.any(
    (c) =>
        (c.status == 'partial' || c.status == 'failed') &&
        (c.targetKind == 'account'
            ? scope.accountIds.contains(c.targetId)
            : scope.cardIds.contains(c.targetId)),
  );

  /// 2026-10-31: 목록 본문. 기간 미상·불러오는 중·조회 실패·대상 없음·거래 없음·날짜별 목록을 구분한다.
  List<Widget> _body(FlowPeriod period, List<FlowItem> items, FlowScope scope) {
    final all = ('전체 거래 보기', widget.onShowAll);
    if (period is FlowPeriodUnknown) {
      // 2026-11-02: 월급 주기 미상은 제목 '이번 기간 내역'과 상태 설명 한 번, 할 수 있는 행동(전체 거래 보기)만 둔다. 사용자에게
      // 확인을 요구하거나 같은 안내를 반복하지 않는다.
      return [
        Column(
          key: const ValueKey('flow-period-unknown'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: PayseSpace.x2),
            const Text(
              '월급 주기를 알 수 없어\n이번 기간의 거래를 보여드릴 수 없어요.',
              style: TextStyle(
                fontSize: 15,
                height: 22 / 15,
                color: PayseColors.textPrimary,
              ),
            ),
            const SizedBox(height: PayseSpace.x2),
            TabLinkRow(
              key: const ValueKey('flow-show-all'),
              label: '전체 거래 보기',
              onTap: widget.onShowAll,
            ),
          ],
        ),
      ];
    }
    switch (widget.feed.load) {
      case TxLoad.loading:
        return [const TxSkeleton()];
      case TxLoad.failed:
        return [
          TxEmpty(
            key: const ValueKey('flow-failed'),
            title: '거래 내역을 불러오지 못했어요',
            body: '잠시 후 다시 시도해 주세요.',
            actions: [('다시 시도', widget.feed.collect)],
          ),
        ];
      case TxLoad.ready:
        break;
    }
    if (scope.accounts.isEmpty) {
      return [
        TxEmpty(
          key: const ValueKey('flow-no-scope'),
          title: '계산에 포함한 계좌가 없어요',
          actions: [all],
        ),
      ];
    }
    if (items.isEmpty) {
      return [
        TxEmpty(
          key: const ValueKey('flow-empty'),
          title: _kind == FlowKind.all
              ? '이번 기간 거래 내역이 없어요'
              : '선택한 종류의 거래 내역이 없어요',
          actions: [all],
        ),
      ];
    }
    final out = <Widget>[];
    String? day;
    for (final item in items) {
      if (item.date != day) {
        out.add(
          TxDayHeader(
            dayHeader(item.date),
            top: day == null ? PayseSpace.x2 : PayseSpace.x4,
          ),
        );
        day = item.date;
      }
      out.add(_row(item));
    }
    if ((period as FlowPeriodKnown).previous) {
      out.add(
        TxEmpty(
          key: const ValueKey('flow-after-period'),
          title: '기간 이후 거래는 전체 거래에서 볼 수 있어요',
          actions: [all],
        ),
      );
    }
    return out;
  }

  /// 2026-10-31: 한 줄을 만든다. 이체는 '보낸 계좌 → 받은 계좌'와 계산 계좌 잔액에 주는 방향을, 그 밖은 기존 거래 줄을 쓴다.
  Widget _row(FlowItem item) {
    switch (item) {
      case FlowRecord(:final transaction):
        final t = transaction;
        return TxRow(
          key: ValueKey('flow-tx-${t.transactionId}'),
          name: t.merchantName,
          subtitle: subtitle(_snap, t),
          icon: kindIcon(t),
          amount: amountText(t),
          labels: [?statusLabel(t), ?reflectionLabel(t)],
          onTap: () => _openItem(item),
        );
      case FlowTransfer(:final from, :final to, :final effect):
        String name(SourceTransaction t) {
          final a = t.accountId == null
              ? null
              : accountById(_snap, t.accountId!);
          return a == null ? '계좌 미확인' : accountTitle(a);
        }
        final amount = switch (effect) {
          TransferEffect.inside => formatKrw(from.amountKrw),
          TransferEffect.intoScope => '+${formatKrw(from.amountKrw)}',
          TransferEffect.outOfScope => '−${formatKrw(from.amountKrw)}',
        };

        return TxRow(
          key: ValueKey('flow-transfer-${from.transactionId}'),
          name: '${name(from)} → ${name(to)}',
          subtitle: '내 계좌 이체',
          icon: transferIcon,
          amount: amount,
          labels: const [],
          onTap: () => _openItem(item),
        );
    }
  }
}

/// 2026-10-31: 기간 제목 'M/D – M/D'(끝 전날까지)와 입금 확인 전이면 '월급 입금 확인 전이에요'. 2026-11-02: '이번 월급 주기'·
/// '지난 계산 기간' 라벨은 위 목적 제목과 겹쳐 뺐고, 기간을 모르면 이 줄을 두지 않는다.
class _PeriodTitle extends StatelessWidget {
  /// 2026-10-31: 기간 [period]로 만든다.
  const _PeriodTitle({required this.period});

  final FlowPeriodKnown period;

  /// 2026-10-31: 제목을 반환한다.
  @override
  Widget build(BuildContext context) {
    final p = period;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${md(p.start)} – ${md(p.end.addDays(-1))}',
          key: const ValueKey('flow-period'),
          style: tabKeyStyle,
        ),
        if (p.previous)
          const Padding(
            padding: EdgeInsets.only(top: PayseSpace.x1),
            child: Text(
              '월급 입금 확인 전이에요',
              key: ValueKey('flow-awaiting'),
              style: TextStyle(
                fontSize: 14,
                height: 20 / 14,
                fontWeight: FontWeight.w600,
                color: PayseColors.textPrimary,
              ),
            ),
          ),
      ],
    );
  }
}
