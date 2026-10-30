import 'package:flutter_test/flutter_test.dart';
import 'package:payse/data/financial_snapshot.dart';
import 'package:payse/features/overview/transaction_query.dart';
import 'package:payse/features/overview/transaction_rules.dart';

import '../../data/connection/connection_test_utils.dart';

/// 2026-10-30: 데모알파 원본(v3) 스냅샷.
FinancialSnapshot _demo() =>
    FinancialSnapshot.fromJson(readSource('demo-ready'));

SourceTransaction _first(
  FinancialSnapshot s,
  bool Function(SourceTransaction) test,
) => s.transactions!.firstWhere(test);

/// 2026-10-30: [base]의 원본 JSON에서 [id] 거래를 [patch]로 바꾼 스냅샷.
FinancialSnapshot _patched(String id, Map<String, Object?> patch) {
  final json = readSource('demo-ready');
  final rows = (json['transactions']! as List).cast<Map>();
  rows.firstWhere((t) => t['transactionId'] == id).addAll(patch);
  return FinancialSnapshot.fromJson(json);
}

void main() {
  group('분류·부호·라벨', () {
    final s = _demo();
    test('거래 종류는 recordKind·direction만으로 나누고 카드 사용은 계좌 출금이 아니다', () {
      for (final t in s.transactions!) {
        final type = TxType.of(t);
        expect(type.isAccount, isAccountEntry(t));
        if (t.recordKind == 'card_purchase') {
          expect(type, TxType.cardPurchase);
        }
      }
    });

    test('부호는 direction을 따르고 승인 취소는 +, 카드 문구와 함께 보인다', () {
      final cancel = _first(s, (t) => t.recordKind == 'card_cancellation');
      expect(amountText(cancel), startsWith('+'));
      expect(subtitle(s, cancel), startsWith('승인 취소 · '));
      expect(subtitle(s, cancel), contains('····'));
      final purchase = _first(s, (t) => t.recordKind == 'card_purchase');
      expect(amountText(purchase), startsWith('−'));
    });

    test('같은 행에 승인 취소를 종류와 라벨로 겹쳐 쓰지 않는다', () {
      final cancel = _first(s, (t) => t.recordKind == 'card_cancellation');
      expect(cancel.status, 'cancelled');
      expect(statusLabel(cancel), isNull);
      final original = _first(
        s,
        (t) => t.transactionId == cancel.originalTransactionId,
      );
      expect(kindLabel(original), '카드 사용');
      expect(statusLabel(original), '승인 취소');
    });

    test(
      '상태 라벨: 카드 승인·미확인, 계좌 미반영, 계좌 approved·cancelled는 카드 문구·미확인으로 바꾸지 않음',
      () {
        final card = _first(s, (t) => t.recordKind == 'card_purchase');
        final acct = _first(s, isAccountEntry);
        expect(
          statusLabel(
            _first(
              _patched(card.transactionId, {'status': 'approved'}),
              (t) => t.transactionId == card.transactionId,
            ),
          ),
          '승인',
        );
        expect(
          statusLabel(
            _first(
              _patched(card.transactionId, {'status': 'unknown'}),
              (t) => t.transactionId == card.transactionId,
            ),
          ),
          '처리 상태 미확인',
        );
        for (final status in ['approved', 'cancelled']) {
          final t = _first(
            _patched(acct.transactionId, {'status': status}),
            (t) => t.transactionId == acct.transactionId,
          );
          expect(statusLabel(t), isNull, reason: 'A 답변 전 표시 미완료');
        }
        final notReflected = _first(
          _patched(acct.transactionId, {
            'reflectionReason': 'not_reflected',
            'balanceReflected': false,
          }),
          (t) => t.transactionId == acct.transactionId,
        );
        expect(reflectionLabel(notReflected), '잔액 미반영');
      },
    );

    test('내 계좌 이체·카드대금 납부는 데이터 분류가 있을 때만', () {
      final transfer = _first(
        s,
        (t) => t.payseTransactionType == 'internal_transfer',
      );
      expect(kindLabel(transfer), '내 계좌 이체');
      expect(TxType.of(transfer), TxType.accountIn);
    });
  });

  group('상세 정보 줄', () {
    final s = _demo();
    test('승인 취소: 취소일, 원래 결제(확보했을 때만), 같은 뜻의 거래 내용 생략', () {
      final cancel = _first(s, (t) => t.recordKind == 'card_cancellation');
      final original = _first(
        s,
        (t) => t.transactionId == cancel.originalTransactionId,
      );
      final rows = detailRows(s, cancel, original: original);
      final labels = [for (final r in rows) r.$1];
      expect(labels, contains('취소일'));
      expect(labels, isNot(contains('거래 일시')));
      expect(labels, contains('원래 결제'));
      expect(labels, isNot(contains('거래 내용')), reason: "'승인취소'는 거래 종류와 같은 뜻");
      expect(rows.firstWhere((r) => r.$1 == '취소일').$2, contains('10:30'));
      final noOriginal = [for (final r in detailRows(s, cancel)) r.$1];
      expect(noOriginal, isNot(contains('원래 결제')));
    });

    test('시간이 없으면 날짜만(00:00으로 채우지 않음)', () {
      final purchase = _first(
        s,
        (t) => t.recordKind == 'card_purchase' && t.occurredAt == null,
      );
      final when = detailRows(
        s,
        purchase,
      ).firstWhere((r) => r.$1 == '거래 일시').$2;
      expect(when, isNot(contains(':')));
    });
  });

  group('기간·조건', () {
    final s = _demo();
    final bounds = QueryBounds.of(s, s.coverage);

    test('이번 달·최근 3개월·최근 1년·월 선택 범위와 양 끝 부분 월', () {
      expect(bounds.range(PeriodSelection.thisMonth), (
        '2026-10-01',
        '2026-10-19',
      ));
      expect(bounds.range(const PeriodSelection(PeriodKind.recent3)), (
        '2026-07-20',
        '2026-10-19',
      ));
      expect(bounds.range(const PeriodSelection(PeriodKind.recent1y)), (
        '2025-10-20',
        '2026-10-19',
      ));
      expect(
        bounds.rangeText(const PeriodSelection(PeriodKind.recent1y)),
        '2025년 10월 20일 ~ 2026년 10월 19일',
      );
      expect(bounds.partialNote('2025-10'), '20일부터');
      expect(bounds.partialNote('2026-10'), '19일까지');
      expect(bounds.partialNote('2026-08'), isNull);
      expect(bounds.months.first, '2025-10');
      expect(bounds.months.last, '2026-10');
    });

    test('월 이동: 이번 달에서 다음 달 없음, 조회 첫 달에서 이전 달 없음', () {
      expect(bounds.shift('2026-10', 1), isNull);
      expect(bounds.shift('2026-10', -1)!.month, '2026-09');
      expect(bounds.shift('2025-10', -1), isNull);
      expect(bounds.shift('2026-09', 1), PeriodSelection.thisMonth);
    });

    test('거래 수단을 바꿔 거래 종류가 맞지 않으면 전체로, 기간은 유지', () {
      const q = TransactionQuery(
        period: PeriodSelection(PeriodKind.recent3),
        type: TxType.cardRefund,
      );
      final accountsOnly = q.withMeans({'a'}, const {});
      expect(accountsOnly.type, isNull);
      expect(accountsOnly.period, q.period);
      expect(accountsOnly.availableTypes, [
        TxType.accountIn,
        TxType.accountOut,
      ]);
      final kept = q.withMeans(null, {'c'});
      expect(kept.type, TxType.cardRefund);
      expect(q.withPeriod(PeriodSelection.thisMonth).type, TxType.cardRefund);
    });

    test('거르기: 계좌만·카드만·거래 종류, 정렬은 날짜 최신순', () {
      final list = filterAndSort(
        s.transactions!,
        const TransactionQuery(period: PeriodSelection(PeriodKind.recent1y)),
        bounds,
      );
      for (var i = 1; i < list.length; i++) {
        expect(
          recordDate(list[i - 1])!.compareTo(recordDate(list[i])!),
          greaterThanOrEqualTo(0),
        );
      }
      final cards = filterAndSort(
        s.transactions!,
        const TransactionQuery(
          period: PeriodSelection(PeriodKind.recent1y),
          accountIds: {},
        ),
        bounds,
      );
      expect(cards.every((t) => !isAccountEntry(t)), isTrue);
      final outs = filterAndSort(
        s.transactions!,
        const TransactionQuery(
          period: PeriodSelection(PeriodKind.recent1y),
          type: TxType.accountOut,
        ),
        bounds,
      );
      expect(
        outs.every((t) => isAccountEntry(t) && t.direction == 'out'),
        isTrue,
      );
    });
  });
}
