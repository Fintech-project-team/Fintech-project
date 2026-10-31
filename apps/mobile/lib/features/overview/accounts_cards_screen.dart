import 'package:flutter/material.dart';

import '../../data/connection/transaction_history.dart';
import '../../data/financial_snapshot.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart';
import 'accounts_screen.dart';
import 'home_calculation.dart';
import 'pull_refresh.dart';
import 'transactions_screen.dart';

/// 2026-10-30: 하단 '계좌·카드' 탭(29-2 D10). 제목 아래 안쪽 탭 '거래 내역 / 계좌 관리'를 두고, 고른 안쪽 탭과 각 화면의
/// 조회 조건·스크롤은 다른 하단 탭에 다녀와도 유지한다. 계좌 관리에서 계좌 행을 누르면 그 계좌로 고정한 거래 내역을 연다.
class AccountsCardsScreen extends StatefulWidget {
  /// 2026-10-30: 현재 Snapshot [snapshot], 홈 계산 [calculation], 저장·조회 연결 [writer], 아래로 당겨 새로고침
  /// [onRefresh], 새로고침으로 받은 거래 전체 [history]로 만든다.
  const AccountsCardsScreen({
    required this.snapshot,
    required this.calculation,
    this.writer,
    this.onRefresh,
    this.history,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final HomeCalculation calculation;
  final AccountsWriter? writer;
  final PullRefresh? onRefresh;
  final TransactionHistoryReady? history;

  /// 2026-10-30: 상태 객체를 반환한다.
  @override
  State<AccountsCardsScreen> createState() => _AccountsCardsScreenState();
}

/// 2026-10-30: 고른 안쪽 탭을 가진다.
class _AccountsCardsScreenState extends State<AccountsCardsScreen> {
  int _tab = 0;

  /// 2026-10-30: 계좌 [account]로 고정한 거래 내역 화면을 연다.
  void _openAccount(Account account) {
    final w = widget.writer;
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => AccountTransactionsPage(
          snapshot: widget.snapshot,
          account: account,
          writer: w,
          onRefresh: widget.onRefresh,
          history: widget.history,
        ),
      ),
    );
  }

  /// 2026-10-30: 제목·안쪽 탭·화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    final w = widget.writer;
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
            child: Row(
              children: [
                _InnerTab(
                  key: const ValueKey('inner-tab-transactions'),
                  label: '거래 내역',
                  selected: _tab == 0,
                  onTap: () => setState(() => _tab = 0),
                ),
                const SizedBox(width: PayseSpace.x6),
                _InnerTab(
                  key: const ValueKey('inner-tab-accounts'),
                  label: '계좌 관리',
                  selected: _tab == 1,
                  onTap: () => setState(() => _tab = 1),
                ),
              ],
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: [
                TransactionsScreen(
                  snapshot: widget.snapshot,
                  repository: w?.repository,
                  onSessionInvalid: w?.onSessionInvalid,
                  onRefresh: widget.onRefresh,
                  history: widget.history,
                ),
                MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: AccountsScreen(
                    snapshot: widget.snapshot,
                    calculation: widget.calculation,
                    writer: w,
                    onOpenAccount: _openAccount,
                    onRefresh: widget.onRefresh,
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

/// 2026-10-30: 계좌 관리에서 연 계좌별 거래 내역. 위 막대에 계좌 이름과 '은행명 ····끝 4자리'를 보이고 거래 수단은
/// [account]로 고정한다. 연 뒤 당겨서 새로고침하면 받은 Snapshot·거래로 이 화면도 바꾼다.
class AccountTransactionsPage extends StatefulWidget {
  /// 2026-10-30: 연 시점의 Snapshot [snapshot], 계좌 [account], 조회 연결 [writer], 새로고침 [onRefresh], 받아 둔 거래
  /// [history]로 만든다.
  const AccountTransactionsPage({
    required this.snapshot,
    required this.account,
    this.writer,
    this.onRefresh,
    this.history,
    super.key,
  });

  final FinancialSnapshot snapshot;
  final Account account;
  final AccountsWriter? writer;
  final PullRefresh? onRefresh;
  final TransactionHistoryReady? history;

  /// 2026-10-30: 상태 객체를 반환한다.
  @override
  State<AccountTransactionsPage> createState() =>
      _AccountTransactionsPageState();
}

/// 2026-10-30: 이 화면이 보이는 Snapshot·거래를 가진다.
class _AccountTransactionsPageState extends State<AccountTransactionsPage> {
  late FinancialSnapshot _snapshot = widget.snapshot;
  late TransactionHistoryReady? _history = widget.history;

  /// 2026-10-30: 화면을 반환한다.
  @override
  Widget build(BuildContext context) {
    final w = widget.writer;
    final account =
        accountById(_snapshot, widget.account.accountId) ?? widget.account;
    return Scaffold(
      backgroundColor: PayseColors.background,
      appBar: AppBar(
        backgroundColor: PayseColors.background,
        surfaceTintColor: PayseColors.background,
        foregroundColor: PayseColors.textPrimary,
        centerTitle: false,
        titleSpacing: 0,
        toolbarHeight: 56,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              account.nickname ?? account.productName,
              key: const ValueKey('account-tx-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                height: 1.45,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '${institutionName(_snapshot, account.institutionCode)} '
              '····${lastFour(account.maskedNumber)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: PayseTypography.caption,
            ),
          ],
        ),
      ),
      body: TransactionsScreen(
        snapshot: _snapshot,
        repository: w?.repository,
        onSessionInvalid: w?.onSessionInvalid,
        accountId: account.accountId,
        history: _history,
        onRefresh: widget.onRefresh,
        onRefreshed: (history) => setState(() {
          _snapshot = history.snapshot;
          _history = history;
        }),
      ),
    );
  }
}
