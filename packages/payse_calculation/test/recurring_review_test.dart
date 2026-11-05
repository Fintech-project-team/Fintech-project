import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'recurring_test.dart' show entry, recurringInput;
import 'support.dart';

void main() {
  final rows = [
    entry('a', '2026-08-20'),
    entry('b', '2026-09-20'),
    entry('c', '2026-10-20'),
  ];
  test('이번 달 미관측 후보도 사용자 확인 전 U에는 넣지 않는다', () {
    final detected = detectRecurring(recurringInput(rows));
    final candidate = detected.candidates.single;
    final suggestions = reviewRecurring(detected, [
      RecurringMeaning(
        context: detected.context,
        candidateKey: candidate.key,
        state: RecurringMeaningState.candidate,
        evidenceIds: ['a', 'b', 'c'],
        name: '월 관리비',
        value: 'housing_management',
        reasonCode: 'supported',
      ),
    ]);
    expect(suggestions.single.isThisMonthCashCandidate, isTrue);
    expect(suggestions.single.isThisMonthRecommendation, isTrue);
    expect(suggestions.single.thisMonthDate.toString(), '2026-11-20');
    expect(suggestions.single.reviews, [
      RecurringReviewReason.userConfirmation,
    ]);
    const asOf = '2026-11-04T12:00:00+09:00';
    final pay = salary(25, [('2026-10-25', SalaryConfirmation.confirmed)]);
    expect(
      current(
        ledger(context(asOf), [account('acc-main', 1000000, asOf)]),
        pay,
      ).u,
      1000000,
    );
    final approved = [obligation('confirmed', 100000, '2026-11-20')];
    expect(
      current(
        ledger(context(asOf), [
          account('acc-main', 1000000, asOf),
        ], obligations: approved),
        pay,
      ).u,
      900000,
    );
    expect(
      current(
        ledger(
          context(asOf),
          [account('acc-main', 900000, asOf)],
          obligations: approved,
          settlements: [settlement('paid', 'confirmed', 100000)],
        ),
        pay,
      ).u,
      900000,
    );
  });
  test('정상 유보·실패·진행은 구별하며 후보 금액은 AI가 변경하지 않는다', () {
    final detected = detectRecurring(recurringInput(rows));
    final candidate = detected.candidates.single;
    for (final state in RecurringMeaningState.values) {
      final result = reviewRecurring(detected, [
        RecurringMeaning(
          context: detected.context,
          candidateKey: candidate.key,
          state: state,
          evidenceIds: ['a', 'b', 'c'],
          reason: '확인이 필요해요',
          value: state == RecurringMeaningState.candidate ? 'telecom' : null,
          reasonCode: state == RecurringMeaningState.candidate
              ? 'supported'
              : 'insufficient_evidence',
        ),
      ]).single;
      expect(result.candidate.suggestedAmountKrw, 100000);
      expect(result.meaning!.state, state);
      expect(
        result.isThisMonthRecommendation,
        state == RecurringMeaningState.candidate,
      );
      expect(
        result.reviews.contains(RecurringReviewReason.analysisFailed),
        state == RecurringMeaningState.failed,
      );
    }
    expect(
      reviewRecurring(detected, []).single.reviews,
      contains(RecurringReviewReason.analysisPending),
    );
  });
  test('카드 구매 반복일은 현금 출금일이 아니며 이미 관측한 이번 달을 중복 추천하지 않는다', () {
    final card = detectRecurring(
      recurringInput([
        for (var m = 8; m <= 10; m++)
          entry(
            '$m',
            '2026-${m.toString().padLeft(2, '0')}-20',
            kind: RecurringEntryKind.cardPurchase,
          ),
      ]),
    );
    final suggestion = reviewRecurring(card, []).single;
    expect(suggestion.thisMonthDate, isNull);
    expect(suggestion.isThisMonthCashCandidate, isFalse);
    expect(suggestion.reviews, contains(RecurringReviewReason.cardBillDate));
    final observed = detectRecurring(
      recurringInput([
        entry('a', '2026-09-02'),
        entry('b', '2026-10-02'),
        entry('c', '2026-11-02'),
      ]),
    );
    expect(
      reviewRecurring(observed, []).single.alreadyObservedThisMonth,
      isTrue,
    );
    expect(
      reviewRecurring(observed, []).single.isThisMonthCashCandidate,
      isFalse,
    );
  });
  test('구버전·다른 근거·중복 응답을 현재 후보로 채택하지 않는다', () {
    final detected = detectRecurring(recurringInput(rows));
    final candidate = detected.candidates.single;
    for (final wrong in [
      RecurringMeaning(
        context: context('2026-11-03T12:00:00+09:00'),
        candidateKey: candidate.key,
        state: RecurringMeaningState.unknown,
        evidenceIds: ['a', 'b', 'c'],
      ),
      RecurringMeaning(
        context: detected.context,
        candidateKey: candidate.key,
        state: RecurringMeaningState.candidate,
        evidenceIds: ['a', 'b', 'foreign'],
        value: 'telecom',
        reasonCode: 'supported',
      ),
    ]) {
      expect(
        () => reviewRecurring(detected, [wrong]),
        throwsA(isA<CalculationInputException>()),
      );
    }
  });
  test('candidate와 null 또는 unknown과 확정값을 섞어 우선 추천하지 않는다', () {
    final detected = detectRecurring(recurringInput(rows));
    final candidate = detected.candidates.single;
    for (final state in [
      RecurringMeaningState.candidate,
      RecurringMeaningState.unknown,
    ]) {
      final invalid = RecurringMeaning(
        context: detected.context,
        candidateKey: candidate.key,
        state: state,
        evidenceIds: ['a', 'b', 'c'],
        value: state == RecurringMeaningState.candidate ? null : 'telecom',
        reasonCode: 'supported',
      );
      expect(
        () => reviewRecurring(detected, [invalid]),
        throwsA(isA<CalculationInputException>()),
      );
    }
  });
}
