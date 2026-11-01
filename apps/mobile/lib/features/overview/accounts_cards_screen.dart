import 'package:flutter/material.dart';

import '../../data/connection/transaction_history.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_tokens.dart';
import 'accounts_screen.dart';
import 'home_calculation.dart';
import 'overview_links.dart';
import 'overview_pages.dart';
import 'period_flow_screen.dart';
import 'transaction_feed.dart';
import 'transaction_query.dart';
import 'transactions_screen.dart';

/// 2026-10-30: 하단 '계좌·카드' 탭(29-2 D10). 제목 아래 안쪽 탭을 두고, 고른 안쪽 탭과 각 화면의 조회 조건·스크롤은 다른
/// 하단 탭에 다녀와도 유지한다.
/// 2026-10-31: 안쪽 탭은 '이번 기간 내역 | 전체 거래 | 계좌 관리'이며 처음에는 이번 기간 내역이다(#163). 두 거래 화면은 같은
/// 거래 수집 상태를 함께 쓴다. 고른 안쪽 탭은 앱 셸이 가진 [tab]에 두어 홈의 '이번 기간 내역 보기'로도 바꾼다.
class AccountsCardsScreen extends StatefulWidget {
  /// 2026-10-30: 현재 Snapshot [snapshot], 홈 계산 [calculation], 저장·조회 연결 [writer], 새로고침으로 받은 거래 전체
  /// [history]로 만든다.
  /// 2026-10-31: 화면 사이 연결 [links]와 고른 안쪽 탭 [tab]을 더했다. 새로고침은 [OverviewLinks.onRefresh]를 쓴다.
  const AccountsCardsScreen({
    required this.snapshot,
    required this.calculation,
    required this.links,
    required this.tab,
    this.writer,
    this.history,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final HomeCalculation calculation;
  final OverviewLinks links;
  final ValueNotifier<AccountsCardsTab> tab;
  final AccountsWriter? writer;
  final TransactionHistoryReady? history;

  /// 2026-10-30: 상태 객체를 반환한다.
  @override
  State<AccountsCardsScreen> createState() => _AccountsCardsScreenState();
}

/// 2026-10-31: 두 거래 화면이 함께 쓰는 거래 수집 상태를 가진다.
class _AccountsCardsScreenState extends State<AccountsCardsScreen> {
  late final TransactionFeed _feed = TransactionFeed(
    snapshot: widget.snapshot,
    repository: widget.writer?.repository,
    onSessionInvalid: widget.writer?.onSessionInvalid,
    history: widget.history,
  );

  /// 2026-10-31: 전체 거래에서 고른 조회 기간. 개별 조회를 열 때 넘긴다.
  PeriodSelection _allPeriod = PeriodSelection.thisMonth;

  /// 2026-10-31: 새 Snapshot·받은 거래를 수집 상태에 알린다.
  @override
  void didUpdateWidget(covariant AccountsCardsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _feed.update(widget.snapshot, widget.history);
  }

  /// 2026-10-31: 수집 상태를 폐기한다.
  @override
  void dispose() {
    _feed.dispose();
    super.dispose();
  }

  /// 2026-10-31: 연결한 전체 계좌·카드에서 고르는 시트를 열고, 전체 거래에서 고른 기간으로 그 조회를 연다.
  Future<void> _pickInstrument() async {
    final picked = await pickInstrument(
      context,
      widget.snapshot,
      InstrumentScope.connected,
    );
    if (picked != null && mounted) {
      openInstrument(context, widget.links, picked, period: _allPeriod);
    }
  }

  /// 2026-10-30: 제목·안쪽 탭·화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    final w = widget.writer;
    final links = widget.links;
    return SafeArea(
      bottom: false,
      child: ValueListenableBuilder<AccountsCardsTab>(
        valueListenable: widget.tab,
        builder: (context, tab, _) => Column(
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
                '계좌·카드',
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
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final (i, (t, label)) in const [
                      (AccountsCardsTab.period, '이번 기간 내역'),
                      (AccountsCardsTab.all, '전체 거래'),
                      (AccountsCardsTab.accounts, '계좌 관리'),
                    ].indexed) ...[
                      if (i > 0) const SizedBox(width: PayseSpace.x6),
                      _InnerTab(
                        key: ValueKey('inner-tab-${t.name}'),
                        label: label,
                        selected: tab == t,
                        onTap: () => widget.tab.value = t,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: tab.index,
                children: [
                  PeriodFlowScreen(
                    calculation: widget.calculation,
                    feed: _feed,
                    links: links,
                    onShowAll: () => widget.tab.value = AccountsCardsTab.all,
                  ),
                  TransactionsScreen(
                    snapshot: widget.snapshot,
                    feed: _feed,
                    onRefresh: links.onRefresh,
                    onPickInstrument: _pickInstrument,
                    onPeriodChanged: (p) => _allPeriod = p,
                  ),
                  MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: AccountsScreen(
                      snapshot: widget.snapshot,
                      calculation: widget.calculation,
                      writer: w,
                      onOpenAccount: (a) => openInstrument(
                        context,
                        links,
                        AccountInstrument(a.accountId),
                      ),
                      onOpenCard: (c) => openInstrument(
                        context,
                        links,
                        CardInstrument(c.cardId),
                      ),
                      onOpenCalculation: () => openCalculation(context, links),
                      onRefresh: links.onRefresh,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 2026-10-30: 안쪽 탭 하나(높이 48, 고르면 700·차콜과 아래 3dp 달빛 노랑 막대, 아니면 500·textSecondary).
class _InnerTab extends StatelessWidget {
  /// 2026-10-30: 문구 [label], 선택 [selected], 누르기 [onTap]으로 만든다.
  const _InnerTab({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 2026-10-30: 탭을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: PayseSize.touchMin,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? PayseColors.textPrimary
                      : PayseColors.textSecondary,
                ),
              ),
              if (selected)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    height: 3,
                    decoration: const BoxDecoration(
                      color: PayseColors.moonYellow,
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
