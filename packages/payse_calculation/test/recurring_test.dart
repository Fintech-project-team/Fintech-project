import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

/// 2026-11-04: 같은 월간 지출의 독립된 원천을 만든다. 기대값은 구현에서 계산하지 않는다.
RecurringEntry entry(
  String id,
  String date, {
  String name = '달빛 관리비',
  int amount = 100000,
  RecurringEntryKind kind = RecurringEntryKind.accountOutflow,
  String? original,
  String instrument = 'acc-main',
  RecurringExclusion? exclusion,
  bool confirmed = true,
}) => RecurringEntry(
  id: id,
  instrumentId: instrument,
  kind: kind,
  name: name,
  date: BusinessDate.parse(date, 'test.date'),
  amountKrw: amount,
  confirmed: confirmed,
  originalId: original,
  exclusion: exclusion,
);

/// 2026-11-04: 완전 조회를 기본으로 하는 1년 자료 준비다. 일부 조회는 명시적으로 바꾼다.
RecurringInput recurringInput(
  List<RecurringEntry> rows, {
  String asOf = '2026-11-04T12:00:00+09:00',
  bool complete = true,
  List<String> decided = const [],
}) => RecurringInput(
  context: context(asOf),
  instrumentIds: ['acc-main'],
  entries: rows,
  coverage: [
    RecurringCoverage(
      instrumentId: 'acc-main',
      from: BusinessDate(2025, 11, 5),
      through: context(asOf).businessDate,
      complete: complete,
    ),
  ],
  decidedCandidateKeys: decided,
);

void main() {
  test('최근3개월만 사용하고 마지막 확인액·독립 월·asOf·정규화를 보존한다', () {
    final rows = [
      entry('old', '2026-07-20', amount: 500000),
      entry('a', '2026-08-20', amount: 100000, name: '  달빛   관리비 '),
      entry('b', '2026-09-20', amount: 101000),
      entry('c', '2026-10-20', amount: 102000),
    ];
    final detected = detectRecurring(recurringInput(rows));
    final candidate = detected.candidates.single;
    expect(candidate.evidenceIds, ['a', 'b', 'c']);
    expect(candidate.suggestedAmountKrw, 102000);
    expect(candidate.suggestedDay, 20);
    expect(candidate.amountVaries, isTrue);
    expect(candidate.features['observedMonths'], [
      '2026-08',
      '2026-09',
      '2026-10',
    ]);
    expect(candidate.normalizedName, '달빛 관리비');
    expect(detected.startExclusive.toString(), '2026-08-04');
    expect(
      detectRecurring(recurringInput(rows.reversed.toList()))
          .candidates
          .single
          .key,
      candidate.key,
    );
    expect(
      detectRecurring(recurringInput(rows, decided: [candidate.key]))
          .candidates,
      isEmpty,
    );
  });
  test('같은 달 세 번 구매와 달별 여러 회차를 월간 반복으로 올리지 않는다', () {
    for (final dates in [
      ['2026-10-01', '2026-10-15', '2026-10-30'],
      ['2026-08-20', '2026-09-20', '2026-10-20', '2026-10-22'],
    ]) {
      final detected = detectRecurring(
        recurringInput([
          for (var i = 0; i < dates.length; i++) entry('$i', dates[i]),
        ]),
      );
      expect(detected.candidates, isEmpty);
      expect(
        detected.issues.single.kind,
        RecurringIssueKind.multipleOccurrences,
      );
    }
  });
  test('금액 중앙값±10%는 경계 포함이며 예정액은 중앙값으로 바꾸지 않는다', () {
    for (final amount in [90000, 110000, 89999, 110001]) {
      final result = detectRecurring(
        recurringInput([
          entry('a', '2026-08-20'),
          entry('b', '2026-09-20'),
          entry('c', '2026-10-20', amount: amount),
        ]),
      );
      if (amount == 90000 || amount == 110000) {
        expect(result.candidates.single.suggestedAmountKrw, amount);
      } else {
        expect(result.candidates, isEmpty);
        expect(result.issues.single.kind, RecurringIssueKind.changedAmount);
      }
    }
  });
  test('윤년·달력3개월·월말 보정을 지키고 변동 날짜를 확정하지 않는다', () {
    final monthEnd = detectRecurring(
      recurringInput([
        entry('a', '2026-01-31'),
        entry('b', '2026-02-28'),
        entry('c', '2026-03-31'),
      ], asOf: '2026-04-04T12:00:00+09:00'),
    );
    expect(monthEnd.candidates.single.suggestedDay, 31);
    final variable = detectRecurring(
      recurringInput([
        entry('a', '2026-08-15'),
        entry('b', '2026-09-20'),
        entry('c', '2026-10-25'),
      ]),
    );
    expect(variable.candidates.single.suggestedDay, isNull);
    final beyond = detectRecurring(
      recurringInput([
        entry('a', '2026-08-14'),
        entry('b', '2026-09-20'),
        entry('c', '2026-10-25'),
      ]),
    );
    expect(beyond.candidates, isEmpty);
    expect(beyond.issues.single.kind, RecurringIssueKind.irregularDates);
  });
  test('환불·취소·이체·청구·명시 중복은 반복 현금 지출로 만들지 않는다', () {
    final rows = [
      entry('a', '2026-08-20'),
      entry('b', '2026-09-20'),
      entry('c', '2026-10-20'),
    ];
    final reversed = detectRecurring(
      recurringInput([
        ...rows,
        entry(
          'r',
          '2026-10-25',
          kind: RecurringEntryKind.reversal,
          original: 'c',
        ),
      ]),
    );
    expect(reversed.candidates, isEmpty);
    expect(reversed.issues.single.kind, RecurringIssueKind.reversal);
    for (final excluded in RecurringExclusion.values) {
      expect(
        detectRecurring(
          recurringInput([
            for (var m = 8; m <= 10; m++)
              entry(
                '$m',
                '2026-${m.toString().padLeft(2, '0')}-20',
                exclusion: excluded,
              ),
          ]),
        ).completeWithoutCandidates,
        isTrue,
      );
    }
  });
  test('후보0·조회 불완전·미확정 원천을 분리하고 미래·중복 ID를 거절한다', () {
    expect(
      detectRecurring(recurringInput([])).completeWithoutCandidates,
      isTrue,
    );
    final partial = detectRecurring(recurringInput([], complete: false));
    expect(partial.completeWithoutCandidates, isFalse);
    expect(partial.issues.single.kind, RecurringIssueKind.incompleteCoverage);
    final unconfirmed = detectRecurring(
      recurringInput([
        entry('a', '2026-08-20'),
        entry('b', '2026-09-20'),
        entry('c', '2026-10-20', confirmed: false),
      ]),
    );
    expect(unconfirmed.issues.single.kind, RecurringIssueKind.unconfirmed);
    expect(
      () => detectRecurring(recurringInput([entry('x', '2026-11-05')])),
      throwsA(isA<CalculationInputException>()),
    );
    expect(
      () => detectRecurring(
        recurringInput([entry('x', '2026-10-01'), entry('x', '2026-10-01')]),
      ),
      throwsA(isA<CalculationInputException>()),
    );
  });
}
