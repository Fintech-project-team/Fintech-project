import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/home_calculation.dart';
import 'package:payse/features/overview/period_flow.dart';
import 'package:payse/features/overview/transaction_query.dart';
import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../data/calculation_input_adapter_test.dart' show alphaWithReceipt;
import '../../data/connection/connection_test_utils.dart';

const _kb = '6069b37a-abf5-56fc-8bf0-153f5301fd1c';
const _shinhan = '67521b1b-de86-54cf-98ba-91bb04d0a256';
const _hana = '48feba1a-c98e-5d0e-91e1-23d8e1ef00fc';
const _hyundai = 'dd908fb3-e0db-5927-8ce4-edc29d758df7';
const _samsung = '0613de09-9a0b-5fa0-8502-a20b4bdd6a9a';
const _woori = 'fd516d5c-e977-564a-a0fe-1f8611b20cb0';
const _kbCheck = '129f18f2-aef7-58ac-b270-3c182d3a7159';

/// 2026-10-31: 계좌 내역 한 건(테스트용 합성 값).
SourceTransaction _entry(
  String id,
  String account,
  String direction,
  int amount,
  String date, {
  String? type,
}) => SourceTransaction(
  transactionId: id,
  accountId: account,
  cardId: null,
  recordKind: 'account_entry',
  amountKrw: amount,
  direction: direction,
  status: 'posted',
  merchantName: '거래 $id',
  bookingDate: date,
  purchaseDate: null,
  withdrawalDate: null,
  payseTransactionType: type,
);

/// 2026-10-31: 카드 기록 한 건(테스트용 합성 값).
SourceTransaction _card(
  String id,
  String card,
  String kind,
  String date, {
  String direction = 'out',
}) => SourceTransaction(
  transactionId: id,
  accountId: null,
  cardId: card,
  recordKind: kind,
  amountKrw: 10000,
  direction: direction,
  status: 'posted',
  merchantName: '카드 $id',
  bookingDate: null,
  purchaseDate: kind == 'card_purchase' ? date : null,
  refundDate: kind == 'card_refund' ? date : null,
  cancellationDate: kind == 'card_cancellation' ? date : null,
  withdrawalDate: null,
  payseTransactionType: null,
);

/// 2026-10-31: 내 계좌 이체 관계.
TransactionRelation _transfer(String from, String to) => TransactionRelation(
  kind: 'internal_transfer',
  fromId: from,
  toId: to,
  evidenceRef: 'test/$from',
);

/// 2026-10-31: 9/25 이상 10/25 미만 기간(달을 걸침).
final _period = FlowPeriodKnown(
  start: calc.BusinessDate(2026, 9, 25),
  end: calc.BusinessDate(2026, 10, 25),
  previous: false,
);

/// 2026-10-31: 알파(국민·신한 포함, 하나 제외) 스냅샷.
FinancialSnapshot _alpha() => FinancialSnapshot.fromJson(alphaWithReceipt());

void main() {
  group('조회 대상', () {
    test('계산 포함 계좌와 그 계좌에서 대금이 나가는 카드만, 제외 계좌 카드는 대상도 미확인도 아니다', () {
      final scope = FlowScope.of(_alpha());
      expect(scope.accountIds, {_kb, _shinhan});
      expect(scope.cardIds, {_hyundai, _samsung, _woori});
      expect(scope.cardIds.contains(_kbCheck), isFalse, reason: '하나(제외) 출금 카드');
      expect(scope.unknownCards, isEmpty);
    });

    test('출금 계좌 null·연결 제한 카드는 대상에 넣지 않고 미확인으로 따로 둔다', () {
      final json = alphaWithReceipt();
      final cards = rows(json, 'cards');
      cards.firstWhere((c) => c['cardId'] == _hyundai)['withdrawalAccountId'] =
          null;
      cards
          .firstWhere((c) => c['cardId'] == _samsung)
          .remove('withdrawalAccountId');
      ((json['accessRestrictions'] ??= <Object?>[]) as List).add({
        'ownerType': 'card',
        'ownerId': _samsung,
        'field': 'withdrawalAccountId',
        'targetKind': 'account',
        'reason': 'not_connected',
      });
      final scope = FlowScope.of(FinancialSnapshot.fromJson(json));
      expect(scope.cardIds, {_woori});
      expect(
        {for (final c in scope.unknownCards) c.cardId},
        {_hyundai, _samsung},
      );
    });

    test('계산 포함 계좌를 바꾸면 카드가 출금 계좌를 따라 들어오고 나간다', () {
      final json = alphaWithReceipt();
      final accounts = rows(json, 'accounts');
      accounts.firstWhere((a) => a['accountId'] == _kb)['included'] = false;
      accounts.firstWhere((a) => a['accountId'] == _hana)['included'] = true;
      final scope = FlowScope.of(FinancialSnapshot.fromJson(json));
      expect(scope.accountIds, {_shinhan, _hana});
      expect(scope.cardIds, {_kbCheck});
    });
  });

  group('조회 기간', () {
    test('정상 계산이면 계산 결과의 월급 주기를 그대로 쓴다', () {
      final c = computeHomeCalculation(_alpha()) as HomeCalculationReady;
      final period = FlowPeriod.of(c.result) as FlowPeriodKnown;
      expect(period.start, c.result.salaryCycle!.periodStart);
      expect(period.end, c.result.salaryCycle!.periodEnd);
      expect(period.previous, isFalse);
    });

    test('월급 입금 확인 전이면 계산 내역의 이전 계산 기간을 늘리지 않고 쓴다', () {
      final c = computeHomeCalculation(
        FinancialSnapshot.fromJson(readSource('salary-wait')),
      ) as HomeCalculationReady;
      expect(
        c.result.salaryCycle!.state,
        calc.SalaryCycleState.awaitingDeposit,
      );
      final period = FlowPeriod.of(c.result) as FlowPeriodKnown;
      expect(period.previous, isTrue);
      expect(period.end, c.result.salaryCycle!.periodEnd);
    });

    test('월급 주기를 알 수 없으면 기간을 만들지 않는다', () {
      final c = computeHomeCalculation(
        FinancialSnapshot.fromJson(readSource('alpha-ready')),
      ) as HomeCalculationReady;
      expect(FlowPeriod.of(c.result), isA<FlowPeriodUnknown>());
      expect(FlowPeriod.of(null), isA<FlowPeriodUnknown>());
    });

    test('시작일은 넣고 다음 월급일 당일은 뺀다(달을 걸친 주기)', () {
      expect(_period.contains('2026-09-24'), isFalse);
      expect(_period.contains('2026-09-25'), isTrue);
      expect(_period.contains('2026-10-01'), isTrue);
      expect(_period.contains('2026-10-24'), isTrue);
      expect(_period.contains('2026-10-25'), isFalse);
    });
  });

  group('목록', () {
    final scope = FlowScope.of(_alpha());

    List<FlowItem> items(
      List<SourceTransaction> txs, [
      List<TransactionRelation> relations = const [],
      FlowKind kind = FlowKind.all,
    ]) => flowItems(
      transactions: txs,
      relations: relations,
      scope: scope,
      period: _period,
      kind: kind,
    );

    Set<String> ids(List<FlowItem> list) => {
      for (final i in list)
        ...switch (i) {
          FlowRecord(:final transaction) => [transaction.transactionId],
          FlowTransfer(:final from, :final to) => [
            from.transactionId,
            to.transactionId,
          ],
        },
    };

    test('대상·기간 밖 거래는 빠지고 예정 지출 없이 실제 거래만 날짜 최신순이다', () {
      final list = items([
        _entry('a1', _kb, 'out', 1000, '2026-10-01'),
        _entry('a2', _hana, 'out', 1000, '2026-10-02'),
        _entry('a3', _kb, 'in', 1000, '2026-10-25'),
        _entry('a4', _shinhan, 'in', 1000, '2026-09-25'),
        _card('c1', _samsung, 'card_purchase', '2026-10-03'),
        _card('c2', _kbCheck, 'card_purchase', '2026-10-03'),
      ]);
      expect(
        [for (final i in list) i.date],
        ['2026-10-03', '2026-10-01', '2026-09-25'],
      );
      expect(ids(list), {'c1', 'a1', 'a4'});
    });

    test('근거 있는 포함 계좌 간 이체는 한 줄로 묶고 합계 잔액 변동 없음', () {
      final out = _entry('t1', _kb, 'out', 50000, '2026-10-10');
      final into = _entry('t2', _shinhan, 'in', 50000, '2026-10-10');
      final list = items([out, into], [_transfer('t1', 't2')]);
      expect(list, hasLength(1));
      final t = list.single as FlowTransfer;
      expect(t.from, same(out));
      expect(t.to, same(into));
      expect(t.effect, TransferEffect.inside);
    });

    test('한쪽만 포함이면 계산 범위로 나가거나 들어온 방향이고, 범위 밖 쪽 원본도 상세용으로 남는다', () {
      final outOf = items(
        [
          _entry('t1', _kb, 'out', 400000, '2026-10-10'),
          _entry('t2', _hana, 'in', 400000, '2026-10-10'),
        ],
        [_transfer('t1', 't2')],
      );
      expect((outOf.single as FlowTransfer).effect, TransferEffect.outOfScope);
      expect((outOf.single as FlowTransfer).to.accountId, _hana);
      final into = items(
        [
          _entry('t3', _hana, 'out', 200000, '2026-10-11'),
          _entry('t4', _shinhan, 'in', 200000, '2026-10-11'),
        ],
        [_transfer('t3', 't4')],
      );
      expect((into.single as FlowTransfer).effect, TransferEffect.intoScope);
    });

    test('근거 없는 이체는 분류가 내 계좌 이체여도 묶지 않고 원본 그대로 둔다', () {
      final list = items([
        _entry(
          't1',
          _kb,
          'out',
          50000,
          '2026-10-10',
          type: 'internal_transfer',
        ),
        _entry(
          't2',
          _shinhan,
          'in',
          50000,
          '2026-10-10',
          type: 'internal_transfer',
        ),
      ]);
      expect(list.whereType<FlowTransfer>(), isEmpty);
      expect(ids(list), {'t1', 't2'});
    });

    test('방향·금액이 맞지 않는 관계는 짝으로 쓰지 않고, 원본을 잃거나 두 번 보이지 않는다', () {
      final txs = [
        _entry('t1', _kb, 'out', 50000, '2026-10-10'),
        _entry('t2', _shinhan, 'in', 40000, '2026-10-10'),
        _entry('t3', _kb, 'in', 1000, '2026-10-12'),
        _entry('t4', _shinhan, 'out', 1000, '2026-10-12'),
        _entry('t5', _kb, 'out', 7000, '2026-10-13'),
        _entry('t6', _shinhan, 'in', 7000, '2026-10-13'),
      ];
      final list = items(txs, [
        _transfer('t1', 't2'),
        _transfer('t3', 't4'),
        _transfer('t5', 't6'),
        _transfer('t5', 't2'),
      ]);
      expect(list.whereType<FlowTransfer>(), hasLength(1));
      final all = [
        for (final i in list)
          ...switch (i) {
            FlowRecord(:final transaction) => [transaction.transactionId],
            FlowTransfer(:final from, :final to) => [
              from.transactionId,
              to.transactionId,
            ],
          },
      ];
      expect(all..sort(), ['t1', 't2', 't3', 't4', 't5', 't6']);
    });

    test('거래 종류: 카드 사용·환불·취소와 카드대금 출금을 나누고, 계좌 입출금에는 이체도 들어간다', () {
      final txs = [
        _card('c1', _samsung, 'card_purchase', '2026-10-03'),
        _card('c2', _samsung, 'card_refund', '2026-10-04', direction: 'in'),
        _card('c3', _woori, 'card_cancellation', '2026-10-05', direction: 'in'),
        _entry('p1', _kb, 'out', 300000, '2026-10-06', type: 'card_payment'),
        _entry('t1', _kb, 'out', 50000, '2026-10-10'),
        _entry('t2', _shinhan, 'in', 50000, '2026-10-10'),
        _entry('u1', _kb, 'out', 9000, '2026-10-11', type: 'internal_transfer'),
      ];
      final relations = [_transfer('t1', 't2')];
      expect(ids(items(txs, relations, FlowKind.card)), {'c1', 'c2', 'c3'});
      expect(ids(items(txs, relations, FlowKind.account)), {
        'p1',
        't1',
        't2',
        'u1',
      });
      expect(ids(items(txs, relations, FlowKind.transfer)), {'t1', 't2', 'u1'});
      expect(ids(items(txs, relations)), hasLength(txs.length));
    });
  });

  group('물려받은 월급 주기 조회', () {
    const bounds = QueryBounds('2025-10-20', '2026-10-19');
    const cycle = PeriodSelection.cycle(
      start: '2026-09-25',
      end: '2026-10-24',
      label: '이번 월급 주기',
    );

    test('경계는 그대로 쓰고 기준일 뒤로는 늘리지 않는다', () {
      expect(bounds.range(cycle), ('2026-09-25', '2026-10-19'));
      expect(bounds.title(cycle), '9/25 – 10/24');
      expect(bounds.monthOf(cycle), isNull, reason: '월 이동 화살표 없음');
    });

    test('실제 목록 거르기: 시작일 포함, 시작 전·기준일 뒤 제외', () {
      final query = TransactionQuery(
        period: cycle,
        accountIds: const {_kb},
        cardIds: const {},
      );
      final kept = filterAndSort(
        [
          _entry('a', _kb, 'out', 1, '2026-09-24'),
          _entry('b', _kb, 'out', 1, '2026-09-25'),
          _entry('c', _kb, 'out', 1, '2026-10-19'),
          _entry('d', _kb, 'out', 1, '2026-10-20'),
        ],
        query,
        bounds,
      );
      expect([for (final t in kept) t.transactionId], ['c', 'b']);
    });
  });
}
