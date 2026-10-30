import 'dart:convert';

import '../financial_snapshot.dart';
import 'financial_api.dart';

/// 2026-10-30: 거래 내역 수집 결과. 모든 페이지를 같은 자료 버전으로 받았을 때만 [TransactionHistoryReady]다.
sealed class TransactionHistoryResult {
  const TransactionHistoryResult();
}

/// 2026-10-30: 모든 페이지를 받아 병합했다. [snapshot]은 수집 기준 Snapshot(409 뒤 다시 받았으면 새 것)이다.
final class TransactionHistoryReady extends TransactionHistoryResult {
  /// 2026-10-30: 기준 [snapshot], 병합한 거래 [transactions], 마지막 페이지의 조회 범위 [coverage]로 만든다.
  const TransactionHistoryReady({
    required this.snapshot,
    required this.transactions,
    required this.coverage,
  });

  final FinancialSnapshot snapshot;
  final List<SourceTransaction> transactions;
  final List<Coverage> coverage;
}

/// 2026-10-30: 페이지를 끝까지 받지 못했다. 받은 페이지는 목록으로 쓰지 않는다.
final class TransactionHistoryFailed extends TransactionHistoryResult {
  /// 2026-10-30: 실패를 만든다.
  const TransactionHistoryFailed();
}

/// 2026-10-30: 세션이 끝났다. 신규 로그인으로 넘긴다.
final class TransactionHistorySessionInvalid extends TransactionHistoryResult {
  /// 2026-10-30: 세션 무효를 만든다.
  const TransactionHistorySessionInvalid();
}

/// 2026-10-30: Snapshot(첫 페이지)부터 page.nextCursor를 따라 GET /transactions를 끝까지 받아 병합한다
/// (apps/mobile/docs/accounts-transactions.md §4-6). 수집 중 자료 버전이 바뀌면(409) 받은 페이지를 버리고 새 Snapshot부터
/// 다시 받는다. 같은 거래 ID가 다른 값으로 오면 계약 오류로 실패한다. 날짜 정렬은 화면 쪽에서 한다.
class TransactionHistoryCollector {
  /// 2026-10-30: 저장소 [repository]로 만든다. [maxRestarts]는 409 뒤 다시 받는 최대 횟수다.
  const TransactionHistoryCollector(this.repository, {this.maxRestarts = 3});

  final UserFinancialRepository repository;
  final int maxRestarts;

  /// 2026-10-30: [first] Snapshot부터 수집한다.
  Future<TransactionHistoryResult> collect(FinancialSnapshot first) async {
    var snapshot = first;
    for (var attempt = 0; attempt <= maxRestarts; attempt++) {
      final outcome = await _collectFrom(snapshot);
      if (outcome != null) return outcome;
      final reloaded = await repository.loadSnapshot();
      switch (reloaded) {
        case FinancialOk(:final value):
          try {
            snapshot = FinancialSnapshot.fromJson(value);
          } on SnapshotFormatException {
            return const TransactionHistoryFailed();
          }
        case FinancialSessionInvalid():
          return const TransactionHistorySessionInvalid();
        default:
          return const TransactionHistoryFailed();
      }
    }
    return const TransactionHistoryFailed();
  }

  /// 2026-10-30: [snapshot]부터 끝까지 받는다. 자료 버전이 바뀌었으면 null(다시 시작)이다.
  Future<TransactionHistoryResult?> _collectFrom(
    FinancialSnapshot snapshot,
  ) async {
    final byId = <String, SourceTransaction>{};
    final raw = <String, String>{};
    for (final t in snapshot.transactions ?? const <SourceTransaction>[]) {
      byId[t.transactionId] = t;
    }
    var coverage = snapshot.coverage;
    var cursor = snapshot.nextTransactionCursor;
    while (cursor != null) {
      final result = await repository.loadTransactionPage(cursor);
      switch (result) {
        case FinancialOk(:final value):
          final TransactionPage page;
          try {
            page = TransactionPage.fromJson(value);
          } on SnapshotFormatException {
            return const TransactionHistoryFailed();
          }
          if (page.dataVersion != snapshot.dataVersion) return null;
          final rows = (value['transactions']! as List).cast<Map>();
          for (var i = 0; i < page.transactions.length; i++) {
            final t = page.transactions[i];
            final text = jsonEncode(rows[i]);
            final seen = raw[t.transactionId];
            if (seen != null && seen != text) {
              return const TransactionHistoryFailed();
            }
            raw[t.transactionId] = text;
            byId[t.transactionId] = t;
          }
          coverage = page.coverage;
          cursor = page.nextCursor;
        case FinancialStaleData():
          return null;
        case FinancialSessionInvalid():
          return const TransactionHistorySessionInvalid();
        default:
          return const TransactionHistoryFailed();
      }
    }
    return TransactionHistoryReady(
      snapshot: snapshot,
      transactions: List.unmodifiable(byId.values),
      coverage: coverage,
    );
  }
}
