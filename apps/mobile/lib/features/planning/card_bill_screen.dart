import 'package:flutter/material.dart';

import '../../data/financial_snapshot.dart';
import '../../data/statement_relations.dart';
import '../../shared/design/amount_format.dart';
import '../../shared/design/payse_tokens.dart';
import '../connection/connection_review.dart' show accountById, lastFour;
import '../overview/calculation_detail_screen.dart' show SnapshotNames, mdText;
import '../overview/pull_refresh.dart' show NoticeBand;
import '../overview/transaction_rules.dart' show cardById, longDate, recordDate;

/// 2026-11-02: 청구 상세 안내. [band]면 안내 띠(제목·설명), 아니면 청구 항목 위 한 줄 문구([body])다.
typedef BillNotice = ({String? title, String body, bool band});

/// 2026-11-02: 청구 금액이 카드사 값이라는 안내.
const String billAmountNote = '이번 청구 금액은 카드사가 제공한 금액이에요.';

/// 2026-11-02: 청구 항목 수 문구. v4는 항목 수(거래 연결 없는 항목 포함), 일부만 받았으면 '확인된 항목 n건', 받지 못했으면 null,
/// v3는 연결된 거래 수다. 받은 거래 수로 전체 건수를 정하지 않는다.
String? billCountText(Statement s) {
  final items = s.items;
  if (items == null) return '연결된 거래 ${s.includedTransactionRefs.length}건';
  return switch (s.detailCompleteness) {
    'complete' => '${items.length}건',
    'unavailable' => null,
    _ => '확인된 항목 ${items.length}건',
  };
}

/// 2026-11-02: 청구 내역 확보 정도에 맞는 안내. 어느 경우에도 청구 금액은 Statement.amountKRW 그대로다.
BillNotice billNotice(Statement s) => switch (s.detailCompleteness) {
  'complete' => (title: null, body: billAmountNote, band: false),
  'unavailable' => (
    title: '청구 내역을 받지 못했어요',
    body: '카드사에서 청구 항목을 받지 못했어요. $billAmountNote',
    band: true,
  ),
  _ => (
    title: '청구 내역 일부만 받았어요',
    body: '카드사에서 청구 항목을 모두 받지 못했어요. $billAmountNote',
    band: true,
  ),
};

/// 2026-11-02: 모든 청구 항목에 이번 청구분(billedAmountKRW)이 없을 때 목록 위에 한 번 두는 안내.
const String billedMissingNote = '카드사가 항목별 청구 금액을 알려 주지 않아 결제 금액만 보여드려요.';

/// 2026-11-02: 청구 [s]의 항목이 있고 모두 이번 청구분이 없으면 true다. 이때는 줄마다 안내하지 않고 목록 위에 한 번만 둔다.
bool billedAllMissing(Statement s) {
  final items = s.items;
  return items != null &&
      items.isNotEmpty &&
      items.every((i) => i.billedAmountKrw == null);
}

/// 2026-11-02: 청구 항목 한 줄의 표시 값. [billedKrw]가 null이면 카드사가 이 항목의 이번 청구분을 주지 않은 것이며 다른 금액으로
/// 대신하지 않는다.
typedef BillLine = ({
  String name,
  String sub,
  List<String> notes,
  int? billedKrw,
});

/// 2026-11-02: v4 청구 항목 [item]의 표시 값. 할부는 그 청구 항목의 회차(없으면 연결 거래의 회차)와 결제 전체 금액을 '결제 금액'으로
/// 밝힌다. 같은 거래를 포함한 다른 청구가 있으면 그 수를 적는다. 거래 연결 없음과 확인하지 못한 연결을 구분한다.
/// 이번 청구분이 없는 항목은 일부 항목에만 없을 때 그 줄에 '이번 청구분 정보 없음'을 적는다(모두 없으면 [billedMissingNote]).
BillLine billItemLine(
  StatementRelations relations,
  Statement statement,
  StatementItem item,
) {
  final allMissing = billedAllMissing(statement);
  final link = relations.itemTransaction(item);
  final tx = link is FoundItemTransaction ? link.transaction : null;
  final date = item.purchaseDate ?? (tx == null ? null : recordDate(tx));
  final round = item.installmentRound ?? tx?.installmentCurrent;
  final months = item.installmentMonths ?? tx?.installmentTotal;
  final installment = round != null && months != null
      ? '할부 $round/$months'
      : null;
  final paid = tx?.amountKrw ?? item.originalUsedAmountKrw;
  final others = item.transactionId == null
      ? 0
      : relations.statementsIncluding(item.transactionId!).length - 1;
  final billed = item.billedAmountKrw;
  return (
    name: item.label ?? item.merchantName ?? tx?.merchantName ?? '청구 항목',
    sub: [
      if (date != null) '${mdText(date)} 이용',
      ?installment,
      if (link is NoItemTransaction) '카드사 청구 항목 · 연결된 거래 없음',
    ].join(' · '),
    notes: [
      if (paid != null && (installment != null || billed == null))
        '결제 금액 ${formatKrw(paid)}',
      if (billed == null && !allMissing) '이번 청구분 정보 없음',
      if (others > 0) '다른 청구 $others건에도 포함',
      if (link is UnresolvedItemTransaction) '거래 정보를 확인하지 못했어요',
    ],
    billedKrw: billed,
  );
}

/// 2026-11-02: v3 청구의 연결 거래 [transactionId] 표시 값. v3에는 청구서별 금액·회차가 없어 이번 청구 금액을 보이지 않는다.
BillLine billRefLine(
  StatementRelations relations,
  Statement statement,
  String transactionId,
) {
  final tx = relations.transaction(transactionId);
  final date = tx == null ? null : recordDate(tx);
  final others = relations.statementsIncluding(transactionId).length - 1;
  return (
    name: tx?.merchantName ?? '청구 항목',
    sub: [if (date != null) '${mdText(date)} 이용'].join(' · '),
    notes: [
      if (tx != null) '결제 금액 ${formatKrw(tx.amountKrw)}',
      if (others > 0) '다른 청구 $others건에도 포함',
      if (tx == null) '거래 정보를 확인하지 못했어요',
    ],
    billedKrw: null,
  );
}

/// 2026-11-02: 03-3 카드 결제 상세(읽기 전용). 하단 탭 없이 뒤로 가기 막대가 있는 화면이며, 뒤로 가면 들어온 목록(조건·펼침·
/// 스크롤)으로 돌아간다. 청구 금액·결제 예정일은 카드사 값 그대로이고 카드 결제일 설정으로 날짜를 채우지 않는다.
class CardBillScreen extends StatelessWidget {
  /// 2026-11-02: [snapshot]의 청구 [statementId]와, 받은 거래 전체 [transactions](같은 자료 버전, 없으면 Snapshot 거래만)로
  /// 만든다.
  const CardBillScreen({
    required this.snapshot,
    required this.statementId,
    this.transactions = const [],
    super.key,
  });

  final FinancialSnapshot snapshot;
  final String statementId;
  final List<SourceTransaction> transactions;

  /// 2026-11-02: 화면을 반환한다. 청구를 찾지 못하면(새로고침 뒤 사라짐 등) 안내만 보인다.
  @override
  Widget build(BuildContext context) {
    final relations = StatementRelations(snapshot, transactions: transactions);
    final statement = relations.statement(statementId);
    return Scaffold(
      backgroundColor: PayseColors.background,
      appBar: AppBar(
        backgroundColor: PayseColors.background,
        surfaceTintColor: PayseColors.background,
        foregroundColor: PayseColors.textPrimary,
        centerTitle: false,
        titleSpacing: 0,
        title: const Text(
          '카드 결제 상세',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        shape: const Border(bottom: BorderSide(color: PayseColors.border)),
      ),
      body: statement == null
          ? const Center(
              child: Text(
                '청구 정보를 찾을 수 없어요',
                key: ValueKey('bill-missing'),
                style: PayseTypography.caption,
              ),
            )
          : _BillBody(relations: relations, statement: statement),
    );
  }
}

/// 2026-11-02: 청구 머리(카드·이번 청구 금액·정보 줄)와 안내, 청구 항목 목록.
class _BillBody extends StatelessWidget {
  /// 2026-11-02: 관계 조회 [relations]와 청구 [statement]로 만든다.
  const _BillBody({required this.relations, required this.statement});

  final StatementRelations relations;
  final Statement statement;

  /// 2026-11-02: 본문을 반환한다.
  @override
  Widget build(BuildContext context) {
    final s = statement;
    final snapshot = relations.snapshot;
    final card = cardById(snapshot, s.cardId);
    final payer = relations.representative(s.statementId);
    final account = payer == null
        ? null
        : accountById(snapshot, payer.withdrawalAccountId);
    final names = SnapshotNames(snapshot);
    final due = s.dueDate;
    final count = billCountText(s);
    final notice = billNotice(s);
    final items = s.items;
    final lines = items == null
        ? [
            for (final id in s.includedTransactionRefs)
              billRefLine(relations, s, id),
          ]
        : notice.band && s.detailCompleteness == 'unavailable'
        ? const <BillLine>[]
        : [for (final i in items) billItemLine(relations, s, i)];
    final pad = const EdgeInsets.symmetric(
      horizontal: PayseSpace.screenHorizontal,
    );
    return ListView(
      key: const ValueKey('bill-list'),
      padding: const EdgeInsets.only(bottom: 34),
      children: [
        Padding(
          padding: pad.copyWith(top: PayseSpace.x5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                card == null
                    ? '카드 정보를 찾을 수 없어요'
                    : '${card.productName} ····${lastFour(card.maskedNumber)}',
                key: const ValueKey('bill-card'),
                style: const TextStyle(
                  fontSize: 15,
                  height: 22 / 15,
                  fontWeight: FontWeight.w600,
                  color: PayseColors.textPrimary,
                ),
              ),
              const SizedBox(height: PayseSpace.x2),
              const Text('이번 청구 금액', style: PayseTypography.caption),
              Text(
                formatKrw(s.amountKrw),
                key: const ValueKey('bill-amount'),
                style: const TextStyle(
                  fontSize: 28,
                  height: 1.25,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.84,
                  color: PayseColors.textPrimary,
                  fontFeatures: PayseTypography.tabular,
                ),
              ),
              const SizedBox(height: PayseSpace.x5),
              const Divider(height: 1, color: PayseColors.dividerSection),
              _InfoRow(
                label: '결제 예정일',
                value: due == null ? '결제 예정일 미확인' : longDate(due),
                muted: due == null,
              ),
              _InfoRow(
                label: '결제 계좌',
                value: account == null
                    ? '결제 계좌 미확인'
                    : '${names.accountName(account.accountId)} '
                          '${names.maskedTail(account.accountId)}',
                muted: account == null,
              ),
              if (s.periodStart case final start?)
                _InfoRow(
                  label: '이용기간',
                  value: '${_monthDay(start)} ~ ${_monthDay(s.periodEnd!)}',
                ),
              if (count != null) _InfoRow(label: '청구 항목', value: count),
            ],
          ),
        ),
        if (notice.band) ...[
          const SizedBox(height: PayseSpace.x4),
          NoticeBand(
            key: const ValueKey('bill-notice'),
            title: notice.title!,
            body: notice.body,
          ),
        ],
        if (lines.isNotEmpty)
          Padding(
            padding: pad.copyWith(top: PayseSpace.section),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.only(bottom: PayseSpace.x2),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: PayseColors.dividerSection),
                    ),
                  ),
                  child: Text(
                    s.detailCompleteness == 'partial' ? '확인된 청구 항목' : '청구 항목',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: PayseColors.textPrimary,
                    ),
                  ),
                ),
                if (!notice.band)
                  Padding(
                    padding: const EdgeInsets.only(top: PayseSpace.x2),
                    child: Text(
                      notice.body,
                      key: const ValueKey('bill-note'),
                      style: PayseTypography.caption,
                    ),
                  ),
                if (billedAllMissing(s))
                  Padding(
                    padding: const EdgeInsets.only(top: PayseSpace.x1),
                    child: Text(
                      billedMissingNote,
                      key: const ValueKey('bill-billed-missing'),
                      style: PayseTypography.caption,
                    ),
                  ),
                for (final (i, line) in lines.indexed)
                  _BillLineRow(key: ValueKey('bill-line-$i'), line: line),
              ],
            ),
          ),
      ],
    );
  }

  /// 2026-11-02: 'YYYY-MM-DD'를 'M월 D일'로 쓴다.
  static String _monthDay(String date) =>
      '${int.parse(date.substring(5, 7))}월 ${int.parse(date.substring(8, 10))}일';
}

/// 2026-11-02: 청구 머리 정보 줄(라벨 왼쪽, 값 오른쪽). [muted]면 값을 미확인 색으로 쓴다.
class _InfoRow extends StatelessWidget {
  /// 2026-11-02: 라벨 [label], 값 [value], 미확인 표시 [muted]로 만든다.
  const _InfoRow({
    required this.label,
    required this.value,
    this.muted = false,
  });

  final String label;
  final String value;
  final bool muted;

  /// 2026-11-02: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: PayseSpace.x3),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 15,
                height: 22 / 15,
                color: PayseColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: PayseSpace.x4),
          Expanded(
            child: Text(
              value,
              key: ValueKey('bill-info-$label'),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 15,
                height: 22 / 15,
                color: muted
                    ? PayseColors.textSecondary
                    : PayseColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 2026-11-02: 청구 항목 한 줄. 왼쪽 이름·이용일·보조 줄, 오른쪽 이번 청구 금액('이번 청구'). 금액이 없으면 오른쪽을 비운다.
class _BillLineRow extends StatelessWidget {
  /// 2026-11-02: 표시 값 [line]으로 만든다.
  const _BillLineRow({required this.line, super.key});

  final BillLine line;

  /// 2026-11-02: 줄을 반환한다.
  @override
  Widget build(BuildContext context) {
    final billed = line.billedKrw;
    return Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.symmetric(vertical: PayseSpace.x4),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PayseColors.dividerRow)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 22 / 15,
                    fontWeight: FontWeight.w600,
                    color: PayseColors.textPrimary,
                  ),
                ),
                if (line.sub.isNotEmpty)
                  Text(line.sub, style: PayseTypography.caption),
                if (line.notes.isNotEmpty)
                  Text(
                    line.notes.join(' · '),
                    style: PayseTypography.caption.copyWith(
                      color: PayseColors.textPrimary,
                    ),
                  ),
              ],
            ),
          ),
          if (billed != null) ...[
            const SizedBox(width: PayseSpace.x3),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatKrw(billed),
                  style: PayseTypography.ledgerAmount.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Text('이번 청구', style: PayseTypography.caption),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 2026-11-02: 카드 결제 상세를 연다. 뒤로 가면 지금 화면으로 돌아온다.
void openCardBill(
  BuildContext context, {
  required FinancialSnapshot snapshot,
  required String statementId,
  List<SourceTransaction> transactions = const [],
}) {
  Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => CardBillScreen(
        snapshot: snapshot,
        statementId: statementId,
        transactions: transactions,
      ),
    ),
  );
}
