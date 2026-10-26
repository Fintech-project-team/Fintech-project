import 'business_date.dart';
import 'inputs.dart';
import 'ledger.dart';
import 'money.dart';

/// 2026-10-23: 홈 월급 구간 상태. 입금 대기는 정상 업무 상태이고, 구간을 정할 근거가 없으면 정보 부족이다.
enum SalaryCycleState { normal, awaitingDeposit, insufficientData }

/// 2026-10-23: 월급 회차의 입금 근거 상태. absent는 근거 항목 자체가 없는 것이며 unknown과 다르다.
enum SalaryReceiptStatus { absent, unknown, partial, confirmed }

/// 2026-10-23: 월급일 규칙 또는 회차 근거로 정한 날짜와 말일 보정 여부.
class PayDate {
  /// 2026-10-23: 날짜 [date]와 없는 날이라 말일로 바꿨는지 [monthEndAdjusted]로 만든다.
  /// 2026-10-26: 명목 회차 [payMonth]와 회차 근거의 예정일인지 [fromEvidence]를 함께 남긴다.
  const PayDate(
    this.date,
    this.monthEndAdjusted, {
    this.payMonth,
    this.fromEvidence = false,
  });

  final BusinessDate date;
  final bool monthEndAdjusted;
  final PayMonth? payMonth;

  /// 2026-10-26: 날짜 출처. true면 원천 근거의 예정일, false면 salaryDay 반복 설정으로 예상한 날짜다.
  /// 입금 상태(confirmation)와 별개이며 원천 근거도 입금 전(unknown)일 수 있다.
  final bool fromEvidence;
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

  /// 2026-10-26: 예정일이 t0 이하인 가장 늦은 회차의 월급일 pPrev(근거 예정일 우선).
  final PayDate? previousPayDate;

  /// 2026-10-26: pPrev 회차보다 뒤 회차의 예정일 중 t0 이후 가장 먼저 도래하는 월급일 pNext.
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
  return PayDate(m.date, m.monthEndAdjusted, payMonth: PayMonth(year, month));
}

/// 2026-10-26: 회차별 예정일 표. 근거가 있는 회차는 근거의 확인 예정일, 없는 회차는 salaryDay 반복 가정이다.
/// 같은 payMonth 근거가 둘 이상이면 입력 오류다. 서로 다른 회차의 같은 예정일은 그대로 보존한다.
class SalarySchedule {
  /// 2026-10-26: 월급일 [salaryDay](1~31)와 근거 목록 [evidence]로 만든다.
  SalarySchedule(this.salaryDay, List<SalaryReceipt> evidence)
    : _byMonth = _index(evidence);

  final int salaryDay;
  final Map<PayMonth, SalaryReceipt> _byMonth;

  static Map<PayMonth, SalaryReceipt> _index(List<SalaryReceipt> evidence) {
    final byMonth = <PayMonth, SalaryReceipt>{};
    for (final receipt in evidence) {
      if (byMonth.containsKey(receipt.payMonth)) {
        throw CalculationInputException(
          InputErrorCode.duplicateId,
          'salary.receiptEvidence',
          '같은 회차 근거 중복(${receipt.payMonth})',
        );
      }
      byMonth[receipt.payMonth] = receipt;
    }
    return byMonth;
  }

  /// 2026-10-26: [month] 회차의 근거. 없으면 null이다.
  SalaryReceipt? receiptOf(PayMonth month) => _byMonth[month];

  /// 2026-10-26: [month] 회차의 예정일. 근거 예정일을 우선하고, 없으면 반복 가정(말일 보정)이다.
  /// 근거 예정일이 말일 보정한 규칙 날짜와 같으면 말일 보정 표시를 유지한다.
  PayDate payDateOf(PayMonth month) {
    final rule = monthlyPayDate(month.year, month.month, salaryDay);
    final receipt = _byMonth[month];
    if (receipt == null) return rule;
    return PayDate(
      receipt.expectedPayDate,
      rule.monthEndAdjusted && rule.date == receipt.expectedPayDate,
      payMonth: month,
      fromEvidence: true,
    );
  }

  /// 2026-10-26: [month]보다 뒤 회차의 예정일 중 [after]보다 늦고 가장 먼저 도래하는 회차와 그 날짜.
  /// 원천 근거 예정일과, 근거가 없는 회차의 반복 설정 날짜를 함께 후보로 본다(같은 회차는 근거 날짜만).
  /// 같은 날짜의 회차가 둘 이상이면 [tied]가 true이고 그중 가장 큰 payMonth를 고른다.
  ({PayMonth month, PayDate pay, bool tied}) earliestAfter(
    PayMonth month,
    BusinessDate after,
  ) {
    PayMonth? best;
    PayDate? bestPay;
    var tied = false;
    void consider(PayMonth m) {
      final pay = payDateOf(m);
      if (!pay.date.isAfter(after)) return;
      final order = bestPay == null ? -1 : pay.date.compareTo(bestPay!.date);
      if (order < 0) {
        best = m;
        bestPay = pay;
        tied = false;
      } else if (order == 0) {
        tied = true;
        if (m.compareTo(best!) > 0) {
          best = m;
          bestPay = pay;
        }
      }
    }

    for (final m in _byMonth.keys) {
      if (m.compareTo(month) > 0) consider(m);
    }
    // 근거가 없는 회차의 반복 설정 날짜는 달마다 늦어지므로 [after] 이후 첫 회차만 후보가 된다.
    var recurring = month.shift(1);
    while (_byMonth.containsKey(recurring) ||
        !payDateOf(recurring).date.isAfter(after)) {
      recurring = recurring.shift(1);
    }
    consider(recurring);
    return (month: best!, pay: bestPay!, tied: tied);
  }

  /// 2026-10-26: [month]보다 앞 회차 중 예정일이 [month] 회차와 같은 회차들. 근거 회차와, 그 날짜가 든 달의
  /// 반복 월급일 회차를 본다.
  List<PayMonth> sameDateBefore(PayMonth month) {
    final date = payDateOf(month).date;
    final calendarMonth = PayMonth(date.year, date.month);
    return [
      for (final m in {..._byMonth.keys, calendarMonth})
        if (m.compareTo(month) < 0 && payDateOf(m).date == date) m,
    ];
  }

  /// 2026-10-26: 예정일이 [today] 이하인 가장 늦은 회차. payMonth와 예정일 사이 기간을 제한하지 않으므로
  /// 모든 근거 회차와, 근거가 없는 회차의 반복 가정 날짜를 함께 본다.
  PayMonth latestOnOrBefore(BusinessDate today) {
    // 근거가 없는 회차의 반복 가정 날짜는 그 달 안에 있으므로 t0 달부터 거꾸로 찾으면 된다.
    var assumed = PayMonth(today.year, today.month);
    while (_byMonth.containsKey(assumed) ||
        payDateOf(assumed).date.isAfter(today)) {
      assumed = assumed.shift(-1);
    }
    var latest = assumed;
    for (final receipt in _byMonth.values) {
      if (!receipt.expectedPayDate.isAfter(today) &&
          receipt.payMonth.compareTo(latest) > 0) {
        latest = receipt.payMonth;
      }
    }
    return latest;
  }
}

/// 2026-10-23: [today](t0)와 [salary]로 현재 월급 구간을 정한다. 현재 시각을 읽지 않는다.
/// 2026-10-26: 근거는 payMonth로 회차에 연결한다. 직전(현재) 회차는 예정일 ≤ t0인 가장 큰 payMonth, 다음 경계는
/// 그보다 뒤 회차의 예정일 중 t0 이후 가장 먼저 도래하는 날짜이며, 이동한 예정일의 달에 1을 더하지 않는다. 확인된 이동 예정일이 없는 회차는 반복 월급일로
/// 경계만 예상하고, 그 예상을 원천 근거로 만들거나 입금 확인으로 보지 않는다(상태 absent). 입금 전 이동 예정일이
/// unknown 근거로 오면 경계로 쓰되 입금 완료로 보지 않는다. 휴일 보정은 하지 않는다. 과거 회차가 늦게 입금돼
/// 순서가 뒤집혀도 현재 회차는 payMonth로 정하므로 되돌리지 않는다. 서로 다른 회차의 예정일이 같으면 회차를
/// 구분해야 하는 현재 구간만 제한한다. 확인 전후는 근거의 confirmation 값으로만 나눈다. 거래 시각을
/// 읽지 않으며, 전달된 근거가 이 asOf에 유효한 상태라는 전제로 계산한다(어댑터 책임).
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

  final schedule = SalarySchedule(day, evidence);
  final previousMonth = schedule.latestOnOrBefore(today);
  final before = schedule.payDateOf(previousMonth.shift(-1));
  final previous = schedule.payDateOf(previousMonth);
  final upcoming = schedule.earliestAfter(previousMonth, today);
  final next = upcoming.pay;

  SalaryReceiptStatus statusOf(PayDate pay) =>
      switch (schedule.receiptOf(pay.payMonth!)?.confirmation) {
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

  // 2026-10-26 결정: 과거 회차가 늦게 입금돼 예정일이 현재 회차보다 늦어도(날짜 역전) 현재 회차·구간을 되돌리지
  // 않는다. 현재 회차는 예정일이 t0 이하인 가장 큰 payMonth라 다음 회차 예정일은 항상 t0보다 늦다.

  if (nextStatus == SalaryReceiptStatus.confirmed) {
    // 다음 회차가 미리 입금 확인되면 확인 시점부터 그다음 회차 예정일까지의 구간으로 전환한다.
    // 그다음 회차들도 미리 confirmed면 이미 잔액에 있으므로 입금 전인 첫 회차의 예정일까지 건너뛴다.
    var afterNext = schedule.earliestAfter(upcoming.month, next.date);
    while (schedule.receiptOf(afterNext.month)?.confirmation ==
        SalaryConfirmation.confirmed) {
      afterNext = schedule.earliestAfter(afterNext.month, afterNext.pay.date);
    }
    return SalaryCycle(
      state: SalaryCycleState.normal,
      previousPayDate: previous,
      nextPayDate: next,
      periodEnd: afterNext.pay.date,
      previousReceipt: previousStatus,
      nextReceipt: nextStatus,
    );
  }

  // 2026-10-26 수정안: 앞 회차와 예정일이 같은데 그 회차들의 입금이 모두 확인되지 않았으면 오늘 반영된 입금이
  // 어느 회차인지 구분해야 하고, 입금 대기면 유지할 이전 구간 길이가 0이라 현재 구간 계산만 제한한다.
  final tied = schedule.sameDateBefore(previousMonth);
  if (tied.isNotEmpty &&
      (previousStatus != SalaryReceiptStatus.confirmed ||
          tied.any(
            (m) =>
                schedule.receiptOf(m)?.confirmation !=
                SalaryConfirmation.confirmed,
          ))) {
    return insufficient(InsufficientReason.payDateConflict);
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
      return SalaryCycle(
        state: SalaryCycleState.awaitingDeposit,
        previousPayDate: previous,
        nextPayDate: next,
        // 늦게 입금될 앞 회차의 예정일이 더 늦으면 유지할 이전 구간 시작을 정할 수 없어 표시하지 않는다.
        periodStart: before.date.isBefore(previous.date) ? before.date : null,
        periodEnd: previous.date,
        previousReceipt: previousStatus,
        nextReceipt: nextStatus,
      );
  }
}

/// 2026-10-26: [cycle]에서 [today]가 정상 주기의 어디쯤인지(0~1)를 반환한다. 홈 달 표시용 진행 정보이며
/// 금액·주기 전환 계산에는 쓰지 않는다. 입금 대기·정보 부족이면 null이다.
/// 기준 시작일은 실제 주기 시작일이고, 다음 회차 조기 입금 확인으로 시작일을 모르면 그 회차 예정일을 쓴다.
/// 진행률 = (오늘 − 기준 시작일) ÷ (주기 마지막 날 − 기준 시작일)이며 기준 시작일 전은 0, 마지막 날은 1이다.
double? cycleProgress(SalaryCycle cycle, BusinessDate today) {
  if (cycle.state != SalaryCycleState.normal) return null;
  final basis = cycle.periodStart ?? cycle.nextPayDate?.date;
  final end = cycle.periodEnd;
  if (basis == null || end == null) return null;
  final span = _daysBetween(basis, end.addDays(-1));
  if (span <= 0) return 1;
  final elapsed = _daysBetween(basis, today);
  if (elapsed <= 0) return 0;
  if (elapsed >= span) return 1;
  return elapsed / span;
}

/// 2026-10-26: [from]에서 [to]까지의 날짜 수(음수 가능).
int _daysBetween(BusinessDate from, BusinessDate to) => DateTime.utc(
  to.year,
  to.month,
  to.day,
).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
