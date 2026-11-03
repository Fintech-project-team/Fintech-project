import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/connection/snapshot_projector.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/data/statement_relations.dart';

import 'connection/connection_test_utils.dart';
import 'connection/statement_items_test.dart' show readV4;

/// 2026-11-02: beta 원본을 [codes] 기관만 연결한 HTTP 응답으로 투영해 읽는다.
FinancialSnapshot _projected(Set<String> codes) {
  final source = readSource('beta-ready');
  return FinancialSnapshot.fromJson(
    SnapshotProjector.project(
      source,
      ProjectionState(
        institutionLinks: [
          for (final code in codes)
            {
              'userId': source['userId'],
              'linkId': 'link-$code',
              'institutionCode': code,
              'consentedAt': '2026-10-22T10:00:00Z',
              'disconnectedAt': null,
            },
        ],
        selectedAccountIds: null,
        dataVersion: '3',
      ),
    ),
  );
}

const _all = {
  'bank.kb',
  'bank.shinhan',
  'bank.hana',
  'bank.ibk',
  'bank.kakao',
  'card.hyundai',
  'card.samsung',
  'card.woori',
  'card.kb',
};

/// 2026-11-02: demo-life 원본에 같은 할부 거래를 포함한 두 번째 청구를 더한 JSON을 반환한다.
Map<String, Object?> _twoStatements() {
  final json = readV4('demo-life');
  final first = rows(json, 'statements').first;
  final item = (first['items']! as List).cast<Map>().first;
  json['statements'] = [
    first,
    {
      ...first,
      'statementId': '00000000-0000-4000-8000-000000000123',
      'dueDate': '2026-11-10',
      'amountKRW': 90000,
      'includedTransactionRefs': [item['transactionId']],
      'items': [
        {...item, 'itemId': '00000000-0000-4000-8000-000000000124'},
      ],
    },
  ];
  return json;
}

void main() {
  test('예정 지출 → 청구: 연결·연결 없음·청구 미연결(제한)을 구분한다', () {
    final s = FinancialSnapshot.fromJson(readSource('beta-ready'));
    final r = StatementRelations(s);
    final linked = s.obligations!.firstWhere((o) => o.statementId != null);
    expect(
      (r.statementOf(linked) as LinkedStatement).statement.statementId,
      linked.statementId,
    );
    expect(r.representative(linked.statementId!), same(linked));
    final plain = s.obligations!.firstWhere((o) => o.statementId == null);
    expect(r.statementOf(plain), isA<NoStatement>());

    final hidden = _projected(_all.difference({'card.hyundai'}));
    final rh = StatementRelations(hidden);
    final restricted = hidden.obligations!.where(
      (o) => rh.statementOf(o) is RestrictedStatement,
    );
    expect(restricted, hasLength(1));
  });

  test('카드 거래 → 포함된 청구: 할부 1건을 청구 2개가 참조하면 둘 다', () {
    final s = FinancialSnapshot.fromJson(_twoStatements());
    final r = StatementRelations(s);
    final tx = s.statements!.first.items!.first.transactionId!;
    expect(
      [for (final x in r.statementsIncluding(tx)) x.amountKrw],
      [s.statements!.first.amountKrw, 90000],
    );
    final other = s.statements!.first.items![1].transactionId!;
    expect(r.statementsIncluding(other), hasLength(1));
  });

  test('청구 항목의 거래: 찾음·연결 없음·확인 못함을 구분한다', () {
    final s = FinancialSnapshot.fromJson(readV4('demo-life'));
    final r = StatementRelations(s);
    final item = s.statements!.first.items!.first;
    expect(r.itemTransaction(item), isA<FoundItemTransaction>());
    StatementItem copy({String? id, bool restricted = false}) => StatementItem(
      itemId: 'i',
      transactionId: id,
      transactionRestricted: restricted,
      label: '연회비',
      merchantName: null,
      purchaseDate: null,
      originalUsedAmountKrw: null,
      billedPrincipalKrw: null,
      feeOrAdjustmentAmountKrw: null,
      billedAmountKrw: 10000,
      installmentMonths: null,
      installmentRound: null,
    );
    expect(r.itemTransaction(copy()), isA<NoItemTransaction>());
    expect(
      r.itemTransaction(copy(id: 'missing')),
      isA<UnresolvedItemTransaction>(),
    );
    expect(
      r.itemTransaction(copy(restricted: true)),
      isA<UnresolvedItemTransaction>(),
    );
  });

  test('v3 청구는 includedTransactionRefs로 포함 여부를 찾는다', () {
    final s = FinancialSnapshot.fromJson(readSource('beta-ready'));
    final statement = s.statements!.single;
    expect(statement.items, isNull);
    final r = StatementRelations(s);
    for (final id in statement.includedTransactionRefs) {
      expect(r.statementsIncluding(id).single, same(statement));
    }
  });

  test('받은 거래 페이지를 넘기면 그 거래도 찾는다', () {
    final s = FinancialSnapshot.fromJson(readSource('demo-life'));
    final tx = s.transactions!.first;
    final json = readSource('demo-life');
    final r = StatementRelations(
      FinancialSnapshot.fromJson(json..['transactions'] = <Object?>[]),
      transactions: [tx],
    );
    expect(r.transaction(tx.transactionId), same(tx));
  });

  test('출금 → 정산 → 예정 지출 → 청구 → 카드, 무효 정산은 제외', () {
    final json = readSource('beta-ready');
    final s = FinancialSnapshot.fromJson(json);
    final statement = s.statements!.single;
    final payer = s.obligations!.firstWhere(
      (o) => o.statementId == statement.statementId,
    );
    final settlement = s.settlements!.firstWhere(
      (x) => x.obligationId == payer.obligationId,
    );
    final paid = StatementRelations(s).paidStatements(settlement.transactionId);
    expect(paid.statements.single.statementId, statement.statementId);
    expect(paid.restricted, isFalse);

    rows(json, 'settlements').firstWhere(
      (x) => x['linkId'] == settlement.linkId,
    )['invalidatedAt'] = '2026-10-19T00:00:00+09:00';
    final invalid = StatementRelations(FinancialSnapshot.fromJson(json));
    expect(
      invalid.paidStatements(settlement.transactionId).statements,
      isEmpty,
    );
    expect(invalid.settledTransactions(payer.obligationId), isEmpty);
  });

  test('카드 청구 연결이 제한 표식으로 끊기면 결제한 카드 대신 제한만 알린다', () {
    final s = _projected(_all.difference({'card.hyundai'}));
    final payer = s.obligations!.firstWhere(
      (o) => s.isRestricted('obligation', o.obligationId, 'statementId'),
    );
    final settlement = s.settlements!.firstWhere(
      (x) => x.obligationId == payer.obligationId,
    );
    final paid = StatementRelations(s).paidStatements(settlement.transactionId);
    expect(paid.statements, isEmpty);
    expect(paid.restricted, isTrue);
  });

  test('관계가 없는 출금은 결제한 카드가 없다', () {
    final s = FinancialSnapshot.fromJson(readSource('beta-ready'));
    final settled = {for (final x in s.settlements!) x.transactionId};
    final other = s.transactions!.firstWhere(
      (t) =>
          t.recordKind == 'account_entry' &&
          t.direction == 'out' &&
          !settled.contains(t.transactionId),
    );
    final paid = StatementRelations(s).paidStatements(other.transactionId);
    expect(paid.statements, isEmpty);
    expect(paid.restricted, isFalse);
  });
}
