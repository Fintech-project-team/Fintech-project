import 'financial_snapshot.dart';

/// 2026-11-02: 예정 지출이 대표하는 청구를 찾은 결과.
sealed class ObligationStatement {
  const ObligationStatement();
}

/// 2026-11-02: 청구 연결이 없다(statementId null, 제한 표식 없음).
final class NoStatement extends ObligationStatement {
  const NoStatement();
}

/// 2026-11-02: 연결은 있지만 청구 카드가 미연결이라 응답에서 생략됐다.
final class RestrictedStatement extends ObligationStatement {
  const RestrictedStatement();
}

/// 2026-11-02: 연결된 청구 [statement].
final class LinkedStatement extends ObligationStatement {
  /// 2026-11-02: 찾은 청구 [statement]로 만든다.
  const LinkedStatement(this.statement);

  final Statement statement;
}

/// 2026-11-02: 청구 항목의 거래를 찾은 결과.
sealed class ItemTransaction {
  const ItemTransaction();
}

/// 2026-11-02: 원천에서 거래 연결이 없는 항목(연회비·독립 조정, transactionId null).
final class NoItemTransaction extends ItemTransaction {
  const NoItemTransaction();
}

/// 2026-11-02: 거래가 미연결이라 연결이 생략됐거나, 거래 ID는 있지만 받은 거래·관련 거래에서 찾지 못했다.
final class UnresolvedItemTransaction extends ItemTransaction {
  const UnresolvedItemTransaction();
}

/// 2026-11-02: 찾은 거래 [transaction].
final class FoundItemTransaction extends ItemTransaction {
  /// 2026-11-02: 찾은 거래 [transaction]으로 만든다.
  const FoundItemTransaction(this.transaction);

  final SourceTransaction transaction;
}

/// 2026-11-02: 출금 거래가 결제한 카드 청구들. [restricted]면 사슬 중간의 청구 연결이 제한 표식으로 끊겼다.
typedef PaidStatements = ({List<Statement> statements, bool restricted});

/// 2026-11-02: 한 Snapshot(과 같은 자료 버전의 받은 거래)의 청구·정산 관계 조회. 계약에 명시된 ID 관계만 따라가며
/// 이름·금액·날짜로 연결을 추정하지 않는다. 금액을 계산하지 않고 화면 문구도 만들지 않는다.
class StatementRelations {
  /// 2026-11-02: [snapshot]과, 페이지를 모두 받았다면 그 거래 [transactions]로 만든다. 거래는 Snapshot 거래·관련 거래와
  /// 합쳐 ID로 찾는다.
  StatementRelations(
    this.snapshot, {
    Iterable<SourceTransaction> transactions = const [],
  }) : _statements = {
         for (final s in snapshot.statements ?? <Statement>[]) s.statementId: s,
       },
       _transactions = {
         for (final t in [
           ...?snapshot.transactions,
           ...?snapshot.relatedTransactions,
           ...transactions,
         ])
           t.transactionId: t,
       };

  final FinancialSnapshot snapshot;
  final Map<String, Statement> _statements;
  final Map<String, SourceTransaction> _transactions;

  /// 2026-11-02: 청구 [statementId]. 공개되지 않았으면 null이다.
  Statement? statement(String statementId) => _statements[statementId];

  /// 2026-11-02: 받은 거래·관련 거래에서 [transactionId]를 찾는다. 없으면 null이다.
  SourceTransaction? transaction(String transactionId) =>
      _transactions[transactionId];

  /// 2026-11-02: 예정 지출 [obligation]이 대표하는 청구.
  ObligationStatement statementOf(Obligation obligation) {
    final id = obligation.statementId;
    if (id == null) {
      return snapshot.isRestricted(
            'obligation',
            obligation.obligationId,
            'statementId',
          )
          ? const RestrictedStatement()
          : const NoStatement();
    }
    final statement = _statements[id];
    return statement == null
        ? const RestrictedStatement()
        : LinkedStatement(statement);
  }

  /// 2026-11-02: 청구 [statementId]를 대표하는 취소되지 않은 예정 지출. 없으면 null이다.
  Obligation? representative(String statementId) {
    for (final o in snapshot.obligations ?? <Obligation>[]) {
      if (o.statementId == statementId && o.status == 'active') return o;
    }
    return null;
  }

  /// 2026-11-02: 거래 [transactionId]를 포함한 청구 전부(Snapshot 순서). v4는 항목의 거래 연결, v3는 includedTransactionRefs다.
  List<Statement> statementsIncluding(String transactionId) => [
    for (final s in _statements.values)
      if (_includes(s, transactionId)) s,
  ];

  /// 2026-11-02: 청구 [statement]가 거래 [transactionId]를 포함하면 true다.
  static bool _includes(Statement statement, String transactionId) {
    final items = statement.items;
    if (items == null) {
      return statement.includedTransactionRefs.contains(transactionId);
    }
    return items.any((i) => i.transactionId == transactionId);
  }

  /// 2026-11-02: 청구 항목 [item]의 거래.
  ItemTransaction itemTransaction(StatementItem item) {
    final id = item.transactionId;
    if (item.transactionRestricted) return const UnresolvedItemTransaction();
    if (id == null) return const NoItemTransaction();
    final t = _transactions[id];
    return t == null
        ? const UnresolvedItemTransaction()
        : FoundItemTransaction(t);
  }

  /// 2026-11-02: 예정 지출 [obligationId]의 유효 정산(무효 시각 없음).
  List<Settlement> validSettlements(String obligationId) => [
    for (final s in snapshot.settlements ?? <Settlement>[])
      if (s.obligationId == obligationId && s.invalidatedAt == null) s,
  ];

  /// 2026-11-02: 예정 지출 [obligationId]의 유효 정산 출금 거래 중 받은 것(정산 순서, 같은 거래는 한 번).
  List<SourceTransaction> settledTransactions(String obligationId) {
    final seen = <String>{};
    return [
      for (final s in validSettlements(obligationId))
        if (seen.add(s.transactionId) && _transactions[s.transactionId] != null)
          _transactions[s.transactionId]!,
    ];
  }

  /// 2026-11-02: 출금 거래 [transactionId]가 결제한 카드 청구. 유효 정산 → 예정 지출 → 청구가 모두 이어질 때만 담는다.
  /// 한 출금이 여러 청구에 연결되면 모두 담는다.
  PaidStatements paidStatements(String transactionId) {
    final obligations = {
      for (final o in snapshot.obligations ?? <Obligation>[]) o.obligationId: o,
    };
    final statements = <Statement>[];
    var restricted = false;
    for (final s in snapshot.settlements ?? <Settlement>[]) {
      if (s.transactionId != transactionId || s.invalidatedAt != null) continue;
      final o = obligations[s.obligationId];
      if (o == null) continue;
      switch (statementOf(o)) {
        case LinkedStatement(:final statement):
          if (!statements.contains(statement)) statements.add(statement);
        case RestrictedStatement():
          restricted = true;
        case NoStatement():
          break;
      }
    }
    return (statements: statements, restricted: restricted);
  }
}
