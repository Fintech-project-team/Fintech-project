import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../financial_snapshot.dart';

/// 2026-11-05: 스냅샷과 끝까지 받은 거래·조회 범위로 공유 반복 계산 입력을 만든다
/// (packages/payse_calculation/docs/recurring.md). 반복 판정·금액·일자는 [calc.detectRecurring]이 맡는다.
///
/// [transactions]·[coverage]는 같은 dataVersion으로 모든 페이지를 받은 결과다(TransactionHistoryReady 또는
/// hasMoreTransactions=false인 스냅샷). [decidedCandidateKeys]는 이미 승인·제외한 후보 키이고
/// [inputRevision]은 계산 입력 버전이다. 날짜는 계좌 출금=출금일, 카드 구매=이용일, 취소·환불=취소·환불일만
/// 쓰며 모르면 null로 둔다. 명시된 관계·분류만 제외 사유로 넣는다.
calc.RecurringInput recurringInputFromSnapshot({
  required FinancialSnapshot snapshot,
  required List<SourceTransaction> transactions,
  required List<Coverage> coverage,
  Iterable<String> decidedCandidateKeys = const [],
  int inputRevision = 0,
}) {
  final instrumentIds = <String>{
    for (final a in snapshot.accounts ?? const <Account>[]) a.accountId,
    for (final c in snapshot.cards ?? const <PaymentCard>[]) c.cardId,
  };
  final relations = snapshot.transactionRelations ?? const [];
  final byId = {for (final tx in transactions) tx.transactionId: tx};
  final internal = <String>{};
  final pairedAccountSide = <String>{};
  for (final r in relations) {
    if (r.kind == 'internal_transfer') {
      internal
        ..add(r.fromId)
        ..add(r.toId);
    } else if (r.kind == 'card_account_pair') {
      for (final id in [r.fromId, r.toId]) {
        if (byId[id]?.recordKind == 'account_entry') pairedAccountSide.add(id);
      }
    }
  }

  final entries = <calc.RecurringEntry>[];
  for (final tx in transactions) {
    final instrument = tx.recordKind == 'account_entry'
        ? tx.accountId
        : tx.cardId;
    if (instrument == null || !instrumentIds.contains(instrument)) continue;
    entries.add(
      calc.RecurringEntry(
        id: tx.transactionId,
        instrumentId: instrument,
        kind: _kind(tx),
        name: tx.merchantName,
        date: _date(tx),
        amountKrw: tx.amountKrw,
        confirmed: _confirmed(tx),
        originalId: tx.originalTransactionId,
        exclusion: _exclusion(tx, internal, pairedAccountSide),
      ),
    );
  }

  return calc.RecurringInput(
    context: calc.CalculationContext(
      dataVersion: snapshot.dataVersion,
      sourceVersion: snapshot.sourceVersion,
      ruleVersion: snapshot.ruleVersion,
      asOf: snapshot.asOf,
      inputRevision: inputRevision,
    ),
    instrumentIds: instrumentIds,
    entries: entries,
    coverage: [
      for (final c in coverage)
        if (instrumentIds.contains(c.targetId)) ..._coverage(c),
    ],
    decidedCandidateKeys: decidedCandidateKeys,
  );
}

/// 2026-11-05: 원천 종류·방향으로 반복 탐지 종류를 정한다. 계좌 입금은 반복 지출 후보가 아니다.
calc.RecurringEntryKind _kind(SourceTransaction tx) => switch (tx.recordKind) {
  'account_entry' when tx.direction == 'out' =>
    calc.RecurringEntryKind.accountOutflow,
  'card_purchase' => calc.RecurringEntryKind.cardPurchase,
  'card_refund' || 'card_cancellation' => calc.RecurringEntryKind.reversal,
  _ => calc.RecurringEntryKind.other,
};

/// 2026-11-05: 종류별 실제 날짜. 계좌 출금을 기장일로, 카드 구매를 청구일로 대신 채우지 않는다.
calc.BusinessDate? _date(SourceTransaction tx) {
  final text = switch (tx.recordKind) {
    'account_entry' =>
      tx.direction == 'out' ? tx.withdrawalDate : tx.bookingDate,
    'card_purchase' => tx.purchaseDate,
    'card_refund' => tx.refundDate,
    'card_cancellation' => tx.cancellationDate,
    _ => null,
  };
  return text == null
      ? null
      : calc.BusinessDate.parse(text, '\$.transactions[${tx.transactionId}]');
}

/// 2026-11-05: 확정된 원천인지. 계좌는 posted, 카드 구매는 approved·posted만 확정이다.
bool _confirmed(SourceTransaction tx) => tx.recordKind == 'account_entry'
    ? tx.status == 'posted'
    : tx.status == 'approved' || tx.status == 'posted';

/// 2026-11-05: 명시 근거가 있는 제외 사유. 본인 이체 관계·분류, 카드대금 분류, 카드와 같은 사건으로 확인된
/// 계좌 내역(카드 쪽을 남김)만 제외한다. 금액·날짜가 같다는 이유로 제외하지 않는다.
calc.RecurringExclusion? _exclusion(
  SourceTransaction tx,
  Set<String> internal,
  Set<String> pairedAccountSide,
) {
  if (internal.contains(tx.transactionId) ||
      tx.payseTransactionType == 'internal_transfer') {
    return calc.RecurringExclusion.internalTransfer;
  }
  if (tx.payseTransactionType == 'card_payment') {
    return calc.RecurringExclusion.cardBillPayment;
  }
  if (pairedAccountSide.contains(tx.transactionId)) {
    return calc.RecurringExclusion.duplicate;
  }
  return null;
}

/// 2026-11-05: 조회 범위 하나를 완료 구간 목록으로 바꾼다. complete·partial은 요청 기간에서 확보하지 못한
/// 구간을 뺀 나머지만 완료로 둔다. 빈틈을 모르는 partial과 failed·unconnected는 미완료 한 구간이다.
List<calc.RecurringCoverage> _coverage(Coverage c) {
  final start = calc.BusinessDate.parse(
    c.requestedStart,
    '\$.coverage.requestedStart',
  );
  final end = calc.BusinessDate.parse(
    c.requestedEnd,
    '\$.coverage.requestedEnd',
  );
  final knownGaps =
      c.status == 'complete' ||
      (c.status == 'partial' && c.missingRanges.isNotEmpty);
  if (!knownGaps) {
    return [
      calc.RecurringCoverage(
        instrumentId: c.targetId,
        from: start,
        through: end,
        complete: false,
      ),
    ];
  }
  final gaps = [
    for (final m in c.missingRanges)
      (
        calc.BusinessDate.parse(m.start, '\$.coverage.missingRanges'),
        calc.BusinessDate.parse(m.end, '\$.coverage.missingRanges'),
      ),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  final ranges = <calc.RecurringCoverage>[];
  var next = start;
  for (final (from, through) in gaps) {
    if (from.isAfter(next)) {
      ranges.add(
        calc.RecurringCoverage(
          instrumentId: c.targetId,
          from: next,
          through: from.addDays(-1),
          complete: true,
        ),
      );
    }
    if (!through.isBefore(next)) next = through.addDays(1);
  }
  if (!next.isAfter(end)) {
    ranges.add(
      calc.RecurringCoverage(
        instrumentId: c.targetId,
        from: next,
        through: end,
        complete: true,
      ),
    );
  }
  return ranges;
}
