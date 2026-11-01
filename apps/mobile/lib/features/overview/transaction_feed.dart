import 'package:flutter/foundation.dart';

import '../../data/connection/financial_api.dart';
import '../../data/connection/transaction_history.dart';
import '../../data/financial_snapshot.dart';

/// 2026-10-30: 거래 내역 수집 상태.
enum TxLoad { loading, ready, failed }

/// 2026-10-31: 한 Snapshot의 거래 전체를 모으는 상태(#163). 전체 거래와 이번 기간 내역이 같은 객체를 함께 써서 같은 자료
/// 버전의 페이지를 두 번 받지 않는다. 받은 거래로 화면마다 거를 뿐 금액을 계산하지 않는다.
class TransactionFeed extends ChangeNotifier {
  /// 2026-10-31: 기준 [snapshot], 다음 페이지 조회 [repository](없으면 Snapshot 거래만), 세션 무효 [onSessionInvalid],
  /// 새로고침으로 이미 받은 거래 전체 [history]로 만들고 바로 모으기 시작한다.
  TransactionFeed({
    required this._snapshot,
    this.repository,
    this.onSessionInvalid,
    this._history,
  }) {
    collect();
  }

  final UserFinancialRepository? repository;
  final VoidCallback? onSessionInvalid;
  FinancialSnapshot _snapshot;
  TransactionHistoryReady? _history;
  bool _disposed = false;
  int _request = 0;

  TxLoad load = TxLoad.loading;

  /// 2026-10-31: 다시 받기에 실패해 이전 완료 결과를 보이는 중이면 true다.
  bool stale = false;
  FinancialSnapshot? _base;
  List<SourceTransaction> all = const [];
  List<Coverage> coverage = const [];

  /// 2026-10-31: 목록이 기준으로 삼는 Snapshot. 완료 결과가 있으면 그 Snapshot이다.
  FinancialSnapshot get snapshot => _base ?? _snapshot;

  /// 2026-10-31: 새 Snapshot [snapshot]·받은 거래 [history]를 알린다. 자료 버전이 바뀌었거나 같은 버전의 새 거래 전체가
  /// 오면 다시 모은다.
  void update(FinancialSnapshot snapshot, TransactionHistoryReady? history) {
    final changed = snapshot.dataVersion != _snapshot.dataVersion;
    final newHistory = !identical(history, _history);
    _snapshot = snapshot;
    _history = history;
    if (changed || (newHistory && _matchingHistory != null)) collect();
  }

  /// 2026-10-30: 현재 Snapshot과 자료 버전이 같은 받아 둔 거래 전체. 없으면 null이다.
  TransactionHistoryReady? get _matchingHistory {
    final h = _history;
    return h != null && h.snapshot.dataVersion == _snapshot.dataVersion
        ? h
        : null;
  }

  /// 2026-10-30: 모든 페이지를 받는다. 실패하면 이전 완료 결과가 있으면 유지하고 [stale]을, 없으면 [TxLoad.failed]다.
  Future<void> collect() async {
    final request = ++_request;
    final repo = repository;
    final first = _snapshot;
    if (_base == null) load = TxLoad.loading;
    _notify();
    final TransactionHistoryResult result;
    if (_matchingHistory case final ready?) {
      result = ready;
    } else if (repo == null || first.nextTransactionCursor == null) {
      result = TransactionHistoryReady(
        snapshot: first,
        transactions: first.transactions ?? const [],
        coverage: first.coverage,
      );
    } else {
      result = await TransactionHistoryCollector(repo).collect(first);
    }
    if (_disposed || request != _request) return;
    switch (result) {
      case TransactionHistoryReady(
        :final snapshot,
        :final transactions,
        :final coverage,
      ):
        _base = snapshot;
        all = transactions;
        this.coverage = coverage;
        load = TxLoad.ready;
        stale = false;
      case TransactionHistorySessionInvalid():
        onSessionInvalid?.call();
        return;
      case TransactionHistoryFailed():
        if (_base == null) {
          load = TxLoad.failed;
        } else {
          stale = true;
        }
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// 2026-10-31: 늦게 끝난 요청이 알리지 않게 한다.
  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
