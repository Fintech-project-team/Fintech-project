import 'business_date.dart';
import 'inputs.dart';
import 'ledger.dart';
import 'money.dart';

/// 2026-10-23: 홈 월급 구간 상태. 입금 대기는 정상 업무 상태이고, 구간을 정할 근거가 없으면 정보 부족이다.
enum SalaryCycleState { normal, awaitingDeposit, insufficientData }

/// 2026-10-23: 월급 회차의 입금 근거 상태. absent는 근거 항목 자체가 없는 것이며 unknown과 다르다.
enum SalaryReceiptStatus { absent, unknown, partial, confirmed }

/// 2026-10-23: 월급일 규칙으로 정한 날짜와 말일 보정 여부.
class PayDate {
  /// 2026-10-23: 날짜 [date]와 없는 날이라 말일로 바꿨는지 [monthEndAdjusted]로 만든다.
  const PayDate(this.date, this.monthEndAdjusted);

  final BusinessDate date;
  final bool monthEndAdjusted;
}

/// 2026-10-23: 홈 계산에 쓰는 현재 월급 구간 [periodStart, periodEnd).
class SalaryCycle {
  /// 2026-10-23: 상태 [state], 직전·다음 월급일, 구간, 두 회차의 근거 상태, 정보 부족 사유로 만든다.
  const SalaryCycle({
    required this.state,
    this.previousPayDate,
    this.nextPayDate,
    this.periodStart,
    this.periodEnd,
    this.previousReceipt,
    this.nextReceipt,
    this.issue,
  });

  final SalaryCycleState state;

  /// 2026-10-23: t0 이하의 가장 늦은 월급일 pPrev(규칙 날짜).
  final PayDate? previousPayDate;

  /// 2026-10-23: t0보다 늦은 가장 이른 월급일 pNext(규칙 날짜).
  final PayDate? nextPayDate;

  /// 2026-10-23: 구간 시작(표시용). 홈 계산은 구간 끝만 쓰고 시작일로 의무를 거르지 않는다
  /// (연체는 시작일과 무관하게 포함). pNext 회차가 미리 confirmed면 확인 시각이 계약에 없어 null이다.
  final BusinessDate? periodStart;

  /// 2026-10-23: 구간 끝(제외). 정상은 pNext, 입금 대기는 pPrev(이전 구간 유지),
  /// pNext 회차가 미리 confirmed면 그다음 월급일이다.
  final BusinessDate? periodEnd;
  final SalaryReceiptStatus? previousReceipt;
  final SalaryReceiptStatus? nextReceipt;
  final InsufficientReason? issue;
}

/// 2026-10-23: [salaryDay] 월급의 [year]년 [month]월 예정일을 반환한다. 29~31일의 없는 날은 말일이다.
PayDate monthlyPayDate(int year, int month, int salaryDay) {
  final m = BusinessDate.monthly(year, month, salaryDay);
  return PayDate(m.date, m.monthEndAdjusted);
}

/// 2026-10-23: [today](t0)와 [salary]로 현재 월급 구간을 정한다. 현재 시각을 읽지 않는다.
/// 근거는 expectedPayDate가 월급일 규칙 날짜와 같을 때만 그 회차로 본다(날짜 근접성으로 추정하지 않음).
/// 확인 전후는 근거의 confirmation 값으로만 나눈다. 거래 시각을 읽지 않으며, 전달된 근거가
/// 이 asOf에 유효한 상태라는 전제로 계산한다(어댑터 책임).
SalaryCycle resolveSalaryCycle(BusinessDate today, SalaryInput salary) {
  final day = salary.salaryDay;
  if (day == null) {
    return const SalaryCycle(
      state: SalaryCycleState.insufficientData,
      issue: InsufficientReason.salaryDayMissing,
    );
  }
  final evidence = salary.receiptEvidence;
  if (evidence == null) {
    return const SalaryCycle(
      state: SalaryCycleState.insufficientData,
      issue: InsufficientReason.receiptEvidenceUnavailable,
    );
  }

  final byDate = <BusinessDate, SalaryReceipt>{};
  for (final receipt in evidence) {
    if (byDate.containsKey(receipt.expectedPayDate)) {
      throw CalculationInputException(
        InputErrorCode.duplicateId,
        'salary.receiptEvidence',
        '같은 예정일 근거 중복(${receipt.expectedPayDate})',
      );
    }
    byDate[receipt.expectedPayDate] = receipt;
  }

  final thisMonth = monthlyPayDate(today.year, today.month, day);
  final PayDate previous;
  final PayDate next;
  if (thisMonth.date.isAfter(today)) {
    final (py, pm) = today.shiftMonth(-1);
    previous = monthlyPayDate(py, pm, day);
    next = thisMonth;
  } else {
    final (ny, nm) = today.shiftMonth(1);
    previous = thisMonth;
    next = monthlyPayDate(ny, nm, day);
  }

  SalaryReceiptStatus statusOf(PayDate pay) =>
      switch (byDate[pay.date]?.confirmation) {
        null => SalaryReceiptStatus.absent,
        SalaryConfirmation.unknown => SalaryReceiptStatus.unknown,
        SalaryConfirmation.partial => SalaryReceiptStatus.partial,
        SalaryConfirmation.confirmed => SalaryReceiptStatus.confirmed,
      };
  final previousStatus = statusOf(previous);
  final nextStatus = statusOf(next);

  SalaryCycle insufficient(InsufficientReason issue) => SalaryCycle(
    state: SalaryCycleState.insufficientData,
    previousPayDate: previous,
    nextPayDate: next,
    previousReceipt: previousStatus,
    nextReceipt: nextStatus,
    issue: issue,
  );

  // 휴일 이동처럼 규칙 날짜와 다른 근거는 어느 회차인지 계약으로 표현할 수 없어 정보 부족이다(회차 필드 필요).
  for (final d in byDate.keys) {
    final sameMonthAsPrevious =
        d.year == previous.date.year && d.month == previous.date.month;
    final sameMonthAsNext =
        d.year == next.date.year && d.month == next.date.month;
    if ((sameMonthAsPrevious && d != previous.date) ||
        (sameMonthAsNext && d != next.date)) {
      return insufficient(InsufficientReason.receiptScheduleMismatch);
    }
  }

  if (nextStatus == SalaryReceiptStatus.confirmed) {
    // 다음 회차가 미리 입금 확인되면 확인 시점부터 그다음 월급일까지의 구간으로 전환한다.
    final (ny, nm) = next.date.shiftMonth(1);
    return SalaryCycle(
      state: SalaryCycleState.normal,
      previousPayDate: previous,
      nextPayDate: next,
      periodEnd: monthlyPayDate(ny, nm, day).date,
      previousReceipt: previousStatus,
      nextReceipt: nextStatus,
    );
  }

  switch (previousStatus) {
    case SalaryReceiptStatus.absent:
      return insufficient(InsufficientReason.receiptEvidenceAbsent);
    case SalaryReceiptStatus.confirmed:
      return SalaryCycle(
        state: SalaryCycleState.normal,
        previousPayDate: previous,
        nextPayDate: next,
        periodStart: previous.date,
        periodEnd: next.date,
        previousReceipt: previousStatus,
        nextReceipt: nextStatus,
      );
    case SalaryReceiptStatus.unknown:
    case SalaryReceiptStatus.partial:
      final (by, bm) = previous.date.shiftMonth(-1);
      return SalaryCycle(
        state: SalaryCycleState.awaitingDeposit,
        previousPayDate: previous,
        nextPayDate: next,
        periodStart: monthlyPayDate(by, bm, day).date,
        periodEnd: previous.date,
        previousReceipt: previousStatus,
        nextReceipt: nextStatus,
      );
  }
}
