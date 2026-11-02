import 'dart:convert';

import 'financial_api.dart';

/// 2026-11-01: Snapshot(첫 페이지)과 GET /transactions 후속 페이지를 같은 버전으로 끝까지 받아 하나의 Snapshot JSON으로 합치는
/// 저장소(docs/api-response-models.md §3). 홈 계산·거래 화면은 합친 결과만 받으며, 중간 실패면 일부 자료를 돌려주지 않는다.
/// 쓰기 성공 뒤 새 Snapshot도 다시 합친다. 합친 결과의 page.nextCursor는 null이다.
class AssembledFinancialRepository implements UserFinancialRepository {
  /// 2026-11-01: 실제 요청을 보내는 [inner]로 만든다. [maxRestarts]는 수집 중 자료 버전이 바뀌었을 때 처음부터 다시 받는 최대 횟수다.
  const AssembledFinancialRepository(this.inner, {this.maxRestarts = 3});

  final UserFinancialRepository inner;
  final int maxRestarts;

  /// 2026-11-01: 세션 종료를 안쪽 저장소에 전한다.
  @override
  void close() => inner.close();

  /// 2026-11-01: 현재 Snapshot을 받아 모든 페이지를 합쳐 반환한다. 하나라도 실패하면 그 실패를 그대로 돌려준다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadSnapshot() async {
    final first = await inner.loadSnapshot();
    if (first case FinancialOk(:final value)) return assemble(value);
    return first;
  }

  /// 2026-11-01: 후속 페이지 하나를 그대로 받는다.
  @override
  Future<FinancialOutcome<Map<String, Object?>>> loadTransactionPage(
    String cursor,
  ) => inner.loadTransactionPage(cursor);

  /// 2026-11-01: POST /institution-links 뒤 새 Snapshot을 합친다.
  @override
  Future<FinancialOutcome<WriteSuccess>> linkInstitutions(
    List<String> institutionCodes,
    WriteContext write,
  ) async => _afterWrite(await inner.linkInstitutions(institutionCodes, write));

  /// 2026-11-01: PATCH /account-selection 뒤 새 Snapshot을 합친다.
  @override
  Future<FinancialOutcome<WriteSuccess>> selectAccounts(
    List<String> accountIds,
    WriteContext write,
  ) async => _afterWrite(await inner.selectAccounts(accountIds, write));

  /// 2026-11-01: PATCH /settings 뒤 새 Snapshot을 합친다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateSalarySettings(
    SalaryPatch salary,
    WriteContext write,
  ) async => _afterWrite(await inner.updateSalarySettings(salary, write));

  /// 2026-11-01: PATCH /accounts/{accountId} 뒤 새 Snapshot을 합친다.
  @override
  Future<FinancialOutcome<WriteSuccess>> updateAccountNickname(
    String accountId,
    String? nickname,
    WriteContext write,
  ) async => _afterWrite(
    await inner.updateAccountNickname(accountId, nickname, write),
  );

  /// 2026-11-01: 저장 성공 [result]의 Snapshot을 합친다. 저장은 이미 확정됐으므로 합치기에 실패해도 성공을 실패로 바꾸지 않고
  /// 받은 첫 페이지 Snapshot을 그대로 둔다(남은 페이지가 있다는 표시가 유지되어 계산은 정보 부족으로 처리된다).
  Future<FinancialOutcome<WriteSuccess>> _afterWrite(
    FinancialOutcome<WriteSuccess> result,
  ) async {
    if (result case FinancialOk(:final value)) {
      final assembled = await assemble(value.snapshot);
      if (assembled case FinancialOk(value: final snapshot)) {
        return FinancialOk(
          WriteSuccess(
            receipt: value.receipt,
            replayed: value.replayed,
            snapshot: snapshot,
          ),
        );
      }
    }
    return result;
  }

  /// 2026-11-01: [snapshot]부터 끝까지 받아 합친다. 수집 중 자료 버전이 바뀌면(409·다른 dataVersion) 받은 페이지를 버리고 새 Snapshot부터
  /// 다시 받는다. 사용자·형식·원천·규칙 버전·기준 시각이 다르거나 같은 ID가 다른 값이면 계약 오류([FinancialUnavailable])다.
  Future<FinancialOutcome<Map<String, Object?>>> assemble(
    Map<String, Object?> snapshot,
  ) async {
    var current = snapshot;
    for (var attempt = 0; attempt <= maxRestarts; attempt++) {
      final outcome = await _collect(current);
      if (outcome != null) return outcome;
      final reloaded = await inner.loadSnapshot();
      if (reloaded case FinancialOk(:final value)) {
        current = value;
      } else {
        return reloaded;
      }
    }
    return const FinancialUnavailable();
  }

  /// 2026-11-01: [snapshot]의 page.nextCursor부터 받는다. 자료 버전이 바뀌었으면 null(다시 시작)이다.
  Future<FinancialOutcome<Map<String, Object?>>?> _collect(
    Map<String, Object?> snapshot,
  ) async {
    final page = snapshot['page'];
    var cursor = page is Map ? page['nextCursor'] : null;
    if (cursor == null) return FinancialOk(snapshot);
    final merged = <String, _MergedArray>{
      for (final entry in _arrays.entries)
        if (snapshot[entry.key] is List) entry.key: _MergedArray(entry.value),
    };
    for (final entry in merged.entries) {
      if (!entry.value.addAll(snapshot[entry.key]! as List)) {
        return const FinancialUnavailable();
      }
    }
    var coverage = snapshot['coverage'];
    while (cursor != null) {
      if (cursor is! String) return const FinancialUnavailable();
      final result = await inner.loadTransactionPage(cursor);
      final Map<String, Object?> next;
      switch (result) {
        case FinancialOk(:final value):
          next = value;
        case FinancialStaleData():
          return null;
        default:
          return result;
      }
      final nextPage = next['page'];
      if (nextPage is! Map) return const FinancialUnavailable();
      if (next['dataVersion'] != snapshot['dataVersion'] ||
          nextPage['dataVersion'] != snapshot['dataVersion']) {
        return null;
      }
      for (final key in _sameContext) {
        if (next[key] != snapshot[key]) return const FinancialUnavailable();
      }
      if (nextPage['sourceVersion'] != snapshot['sourceVersion']) {
        return const FinancialUnavailable();
      }
      for (final entry in merged.entries) {
        final rows = next[entry.key];
        if (rows is! List || !entry.value.addAll(rows)) {
          return const FinancialUnavailable();
        }
      }
      coverage = next['coverage'];
      cursor = nextPage['nextCursor'];
    }
    return FinancialOk({
      ...snapshot,
      for (final entry in merged.entries) entry.key: entry.value.rows,
      'coverage': coverage,
      'page': {...(page! as Map).cast<String, Object?>(), 'nextCursor': null},
    });
  }

  /// 2026-11-01: 페이지와 Snapshot이 같아야 하는 공통 필드 H(dataVersion은 따로 본다).
  static const List<String> _sameContext = [
    'userId',
    'schemaVersion',
    'currency',
    'sourceVersion',
    'ruleVersion',
    'asOf',
  ];

  /// 2026-11-01: 페이지마다 이어 받는 배열과 중복 판정 기준(§3). 같은 기준인데 값이 다르면 계약 오류다.
  /// accessRestrictions는 따로 정한 ID가 없어 전체 값이 같은 것만 하나로 합친다.
  static final Map<String, List<String>?> _arrays = {
    'transactions': ['transactionId'],
    'relatedTransactions': ['transactionId'],
    'referenceResolutions': ['transactionId'],
    'transactionRelations': ['kind', 'fromId', 'toId', 'evidenceRef'],
    'occurrenceLinks': [
      'recurrenceKey',
      'purchaseTransactionId',
      'statementId',
      'obligationId',
      'evidenceRef',
    ],
    'accessRestrictions': null,
  };
}

/// 2026-11-01: 한 배열의 병합 상태. 처음 나온 순서를 유지하고 같은 기준의 항목은 한 번만 남긴다.
class _MergedArray {
  /// 2026-11-01: 중복 판정 필드 [keyFields](null이면 전체 값)로 만든다.
  _MergedArray(this.keyFields);

  final List<String>? keyFields;
  final Map<String, String> _seen = {};
  final List<Object?> rows = [];

  /// 2026-11-01: [items]를 더한다. 같은 기준인데 값이 다르거나 항목이 객체가 아니면 false를 반환한다.
  bool addAll(List<Object?> items) {
    for (final item in items) {
      if (item is! Map) return false;
      final value = _canonical(item);
      final fields = keyFields;
      final key = fields == null
          ? value
          : jsonEncode([for (final f in fields) item[f]]);
      final seen = _seen[key];
      if (seen == null) {
        _seen[key] = value;
        rows.add(item);
      } else if (seen != value) {
        return false;
      }
    }
    return true;
  }

  /// 2026-11-01: 객체 키 순서와 무관하게 같은 값이면 같은 문자열을 반환한다.
  static String _canonical(Object? value) => jsonEncode(_sorted(value));

  /// 2026-11-01: Map 키를 정렬한 복사본을 반환한다.
  static Object? _sorted(Object? value) => switch (value) {
    final Map map => {
      for (final key in (map.keys.map((k) => '$k').toList()..sort()))
        key: _sorted(map[key]),
    },
    final List list => [for (final item in list) _sorted(item)],
    _ => value,
  };
}
