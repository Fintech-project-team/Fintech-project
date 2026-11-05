import 'package:flutter_test/flutter_test.dart';
import 'package:payse_calculation/payse_calculation.dart';

import 'support.dart';

/// 2026-11-04: 사용자 확정 버전만 준비한다. 후보/AI 출력은 계획 입력이 아니다.
RecurringPlanRevision revision({
  String id = 'rev-1',
  String month = '2027-01',
  bool isCurrent = true,
  int amount = 100000,
  bool card = false,
  ObligationStatus status = ObligationStatus.active,
  List<RecurringScheduleOverride> overrides = const [],
}) => RecurringPlanRevision(
  revisionId: id,
  planId: 'plan-1',
  effectiveFromMonth: month,
  isCurrent: isCurrent,
  amountKrw: amount,
  monthlyDay: 31,
  withdrawalAccountId: 'acc-main',
  paymentTiming: card
      ? RecurringPaymentTiming.cardBill
      : RecurringPaymentTiming.immediate,
  scheduleBasis: card
      ? RecurringScheduleBasis.purchase
      : RecurringScheduleBasis.withdrawal,
  status: status,
  cardId: card ? 'card-1' : null,
  scheduleOverrides: overrides,
);

void main() {
  final ctx = context('2027-02-04T12:00:00+09:00');
  final plan = RecurringPlan(planId: 'plan-1', firstOccurrenceMonth: '2027-01');

  test('월말 보정·명시 일정 우선·원래 31일 복원·첫 회차 전 미생성', () {
    final revisions = [
      revision(
        overrides: [
          RecurringScheduleOverride(
            occurrenceMonth: '2027-02',
            plannedDate: '2027-02-26',
            evidenceRef: 'confirmed',
          ),
        ],
      ),
    ];
    RecurringSchedule expand(int year, int month) => expandRecurring(
      context: ctx,
      month: PayMonth(year, month),
      plans: [plan],
      revisions: revisions,
    );
    expect(expand(2026, 12).cashObligations, isEmpty);
    expect(
      expand(2027, 2).cashObligations!.single.dueDate.toString(),
      '2027-02-26',
    );
    expect(
      expand(2027, 3).cashObligations!.single.dueDate.toString(),
      '2027-03-31',
    );
    expect(
      expand(2027, 2).cashObligations!.single.obligationId,
      'plan-1:2027-02',
    );
    expect(
      expandRecurring(
        context: ctx,
        month: PayMonth(2027, 2),
        plans: [plan],
        revisions: [revision()],
      ).cashObligations!.single.dueDate.toString(),
      '2027-02-28',
    );
  });

  test('시작 월과 현재 권위 버전을 선택하되 저장된 정산 회차는 고정 유지', () {
    final revisions = [
      revision(isCurrent: false),
      revision(id: 'rev-2', amount: 120000),
      revision(id: 'rev-3', month: '2027-03', amount: 130000),
    ];
    final saved = obligation('saved', 90000, '2027-02-21');
    final fixed = FixedRecurringOccurrence(
      planId: 'plan-1',
      occurrenceMonth: '2027-02',
      revisionId: 'rev-1',
      obligation: saved,
    );
    final feb = expandRecurring(
      context: ctx,
      month: PayMonth(2027, 2),
      plans: [plan],
      revisions: revisions,
      fixedOccurrences: [fixed],
    );
    expect(identical(feb.cashObligations!.single, saved), isTrue);
    expect(feb.revisionIds['plan-1:2027-02'], 'rev-1');
    final mar = expandRecurring(
      context: ctx,
      month: PayMonth(2027, 3),
      plans: [plan],
      revisions: revisions,
      fixedOccurrences: [fixed],
    );
    expect(mar.cashObligations!.single.amountKrw, 130000);
    expect(mar.revisionIds['plan-1:2027-03'], 'rev-3');
    expect(
      expandRecurring(
        context: ctx,
        month: PayMonth(2027, 2),
        plans: [plan],
        revisions: revisions,
      ).cashObligations!.single.amountKrw,
      120000,
    );
  });

  test('카드 구매 회차는 청구 연결 전 계산 제한·연결 후 추가 현금 의무 0개', () {
    final missing = expandRecurring(
      context: ctx,
      month: PayMonth(2027, 2),
      plans: [plan],
      revisions: [revision(card: true)],
    );
    expect(missing.cashObligations, isNull);
    expect(missing.issues.single.recurrenceKey, 'plan-1:2027-02');
    final covered = expandRecurring(
      context: ctx,
      month: PayMonth(2027, 2),
      plans: [plan],
      revisions: [revision(card: true)],
      coveredCardKeys: {'plan-1:2027-02'},
    );
    expect(covered.cashObligations, isEmpty);
    expect(covered.issues, isEmpty);
  });

  test('승인 계획을 U에 한 번 반영하고 저장된 지급 회차는 실제 출금 후 재차감하지 않는다', () {
    const asOf = '2027-02-04T12:00:00+09:00';
    final pay = salary(25, [('2027-01-25', SalaryConfirmation.confirmed)]);
    final rev = RecurringPlanRevision(
      revisionId: 'rev-1',
      planId: 'plan-1',
      effectiveFromMonth: '2027-01',
      isCurrent: true,
      amountKrw: 100000,
      monthlyDay: 20,
      withdrawalAccountId: 'acc-main',
      paymentTiming: RecurringPaymentTiming.immediate,
      scheduleBasis: RecurringScheduleBasis.withdrawal,
      status: ObligationStatus.active,
    );
    final approved = expandRecurring(
      context: ctx,
      month: PayMonth(2027, 2),
      plans: [plan],
      revisions: [rev],
    );
    expect(
      current(
        ledger(ctx, [
          account('acc-main', 1000000, asOf),
        ], obligations: approved.cashObligations),
        pay,
      ).u,
      900000,
    );
    final saved = obligation('saved', 100000, '2027-02-20');
    final paid = expandRecurring(
      context: ctx,
      month: PayMonth(2027, 2),
      plans: [plan],
      revisions: [rev],
      fixedOccurrences: [
        FixedRecurringOccurrence(
          planId: 'plan-1',
          occurrenceMonth: '2027-02',
          revisionId: 'rev-1',
          obligation: saved,
        ),
      ],
    );
    expect(
      current(
        ledger(
          ctx,
          [account('acc-main', 900000, asOf)],
          obligations: paid.cashObligations,
          settlements: [settlement('link', 'saved', 100000)],
        ),
        pay,
      ).u,
      900000,
    );
  });

  test('중복 현재 버전·누락 버전·미래 고정 버전·다른 청구 키를 0원으로 숨기지 않는다', () {
    for (final revisions in <List<RecurringPlanRevision>>[
      [],
      [revision(), revision(id: 'duplicate')],
      [revision(month: '2027-02')],
      [revision(isCurrent: false)],
    ]) {
      expect(
        () => expandRecurring(
          context: ctx,
          month: PayMonth(2027, 2),
          plans: [plan],
          revisions: revisions,
        ),
        throwsA(isA<CalculationInputException>()),
      );
    }
    expect(
      () => expandRecurring(
        context: ctx,
        month: PayMonth(2027, 2),
        plans: [plan],
        revisions: [
          revision(),
          revision(id: 'future', month: '2027-03'),
        ],
        fixedOccurrences: [
          FixedRecurringOccurrence(
            planId: 'plan-1',
            occurrenceMonth: '2027-02',
            revisionId: 'future',
            obligation: obligation('saved', 1000, '2027-02-20'),
          ),
        ],
      ),
      throwsA(isA<CalculationInputException>()),
    );
    expect(
      () => expandRecurring(
        context: ctx,
        month: PayMonth(2027, 2),
        plans: [plan],
        revisions: [revision(card: true)],
        coveredCardKeys: {'other:2027-02'},
      ),
      throwsA(isA<CalculationInputException>()),
    );
    expect(
      expandRecurring(
        context: ctx,
        month: PayMonth(2027, 2),
        plans: [plan],
        revisions: [revision(status: ObligationStatus.cancelled)],
      ).cashObligations,
      isEmpty,
    );
  });
}
