import 'business_date.dart';
import 'inputs.dart';
import 'ledger.dart';
import 'money.dart';
import 'salary_cycle.dart';

/// 2026-10-23: 홈 계산에서 의무 한 건이 놓인 위치.
enum ObligationPlacement {
  /// 2026-10-23: 현재 구간 E에 포함(연체 포함).
  inCurrentPeriod,

  /// 2026-10-23: 급여 입금 확인 후 반영 대기. E에 넣지 않지만 취소·지급 처리하지 않는다.
  awaitingSalary,

  /// 2026-10-23: 구간 끝 이후 의무. '기간 밖 의무'로 안내한다.
  outsidePeriod,

  /// 2026-10-23: 출금 계좌가 홈 합산에서 제외된 계좌. E·구간 계산에 넣지 않고 따로 안내한다.
  excludedAccount,

  /// 2026-10-23: 유효 정산으로 잔여 0.
  settled,
  cancelled,
}

/// 2026-10-23: 의무 한 건의 계산 근거. settledKrw가 '이미 나간 돈'이다.
class ObligationLine {
  /// 2026-10-23: 의무 [obligationId], 금액·정산·잔여, 예정일, 위치(null은 구간 미정), R 겹침 [overlapKrw]로 만든다.
  const ObligationLine({
    required this.obligationId,
    required this.amountKrw,
    required this.settledKrw,
    required this.remainingKrw,
    required this.dueDate,
    required this.placement,
    required this.overlapKrw,
  });

  final String obligationId;
  final int amountKrw;
  final int settledKrw;
  final int remainingKrw;
  final BusinessDate dueDate;
  final ObligationPlacement? placement;
  final int? overlapKrw;
}

/// 2026-10-23: 홈 현재 금액 입력. [salary]가 null이면 월급 설정을 받지 못한 상태다.
class CurrentAmountInput {
  /// 2026-10-23: 장부 [ledger]와 월급 설정 [salary]로 만든다.
  const CurrentAmountInput({required this.ledger, required this.salary});

  final LedgerInput ledger;
  final SalaryInput? salary;
}

/// 2026-10-23: U=B−E−(R−O) 결과. 각 값은 자기 근거가 모두 있을 때만 채우고 아니면 null이다.
class CurrentAmountResult {
  /// 2026-10-23: 기준 [context]와 각 값·사유·의무 근거로 만든다. 목록은 수정 불가로 보관한다.
  CurrentAmountResult({
    required this.context,
    required this.salaryCycle,
    required this.b,
    required this.e,
    required this.r,
    required this.o,
    required this.rEff,
    required this.u,
    required List<InsufficientReason> insufficient,
    required List<ObligationLine>? obligationLines,
  }) : insufficient = List.unmodifiable(insufficient),
       obligationLines = obligationLines == null
           ? null
           : List.unmodifiable(obligationLines);

  final CalculationContext context;
  final SalaryCycle? salaryCycle;
  final int? b;
  final int? e;
  final int? r;
  final int? o;
  final int? rEff;
  final int? u;
  final List<InsufficientReason> insufficient;
  final List<ObligationLine>? obligationLines;

  /// 2026-10-23: U를 계산했으면 true. false면 insufficient에 이유가 있다.
  bool get calculated => u != null;
}

/// 2026-10-23: [input]으로 홈 현재 금액을 계산한다. 원본을 바꾸지 않고 같은 입력에 같은 결과를 반환한다.
/// 계약 위반은 CalculationInputException, 정보 부족·보류는 null 값과 insufficient 사유다.
CurrentAmountResult calculateCurrentAmount(CurrentAmountInput input) {
  final ledger = Ledger.prepare(input.ledger);
  final context = input.ledger.context;
  final today = context.businessDate;

  final salary = input.salary;
  final cycle = salary == null ? null : resolveSalaryCycle(today, salary);
  final cycleIssues = <InsufficientReason>[
    if (salary == null) InsufficientReason.salarySettingsMissing,
    if (cycle?.issue != null) cycle!.issue!,
  ];

  final states = ledger.obligations;
  final overlap = ledger.overlapByObligation;
  List<ObligationLine>? lines;
  final eIssues = <InsufficientReason>[
    ...ledger.obligationIssues,
    ...cycleIssues,
  ];
  int? e;
  var o = 0;
  if (states != null) {
    final determined =
        cycle != null && cycle.state != SalaryCycleState.insufficientData;
    lines = [
      for (final s in states)
        ObligationLine(
          obligationId: s.obligation.obligationId,
          amountKrw: s.obligation.amountKrw,
          settledKrw: s.settledKrw,
          remainingKrw: s.remainingKrw,
          dueDate: s.obligation.dueDate,
          placement: _placement(
            s,
            ledger.isIncluded(s.obligation.withdrawalAccountId),
            determined ? cycle : null,
            today,
          ),
          overlapKrw: overlap == null
              ? null
              : overlap[s.obligation.obligationId] ?? 0,
        ),
    ];
    if (eIssues.isEmpty) {
      var sum = 0;
      for (final line in lines) {
        if (line.placement != ObligationPlacement.inCurrentPeriod) continue;
        sum = addKrw(sum, line.remainingKrw, 'E');
        if (overlap != null) o = addKrw(o, line.overlapKrw!, 'O');
      }
      e = sum;
    }
  }

  final oIssues = <InsufficientReason>[...eIssues, ...ledger.overlapIssues];
  final oValue = oIssues.isEmpty ? o : null;
  final r = ledger.r;
  final rEff = (r != null && oValue != null)
      ? subtractKrw(r, oValue, 'R-O')
      : null;
  final b = ledger.b;
  final u = (b != null && e != null && rEff != null)
      ? subtractKrw(subtractKrw(b, e, 'B-E'), rEff, 'U')
      : null;

  final all = <InsufficientReason>[];
  for (final reason in [
    ...ledger.bIssues,
    ...oIssues,
    ...ledger.reserveIssues,
  ]) {
    if (!all.contains(reason)) all.add(reason);
  }
  return CurrentAmountResult(
    context: context,
    salaryCycle: cycle,
    b: b,
    e: e,
    r: r,
    o: oValue,
    rEff: rEff,
    u: u,
    insufficient: all,
    obligationLines: lines,
  );
}

/// 2026-10-23: 의무 [s]의 위치를 정한다. [accountIncluded]가 false면 제외 계좌 의무다.
/// [cycle]이 null이면 정산·취소·제외 계좌 외 위치는 미정(null)이다.
ObligationPlacement? _placement(
  ObligationState s,
  bool accountIncluded,
  SalaryCycle? cycle,
  BusinessDate today,
) {
  if (s.obligation.status == ObligationStatus.cancelled) {
    return ObligationPlacement.cancelled;
  }
  if (s.remainingKrw == 0) return ObligationPlacement.settled;
  // 포함 계좌에서 제외 계좌로 돈을 보낸다고 가정하지 않으므로 E에 넣지 않는다.
  if (!accountIncluded) return ObligationPlacement.excludedAccount;
  if (cycle == null) return null;
  final due = s.obligation.dueDate;
  if (cycle.state == SalaryCycleState.awaitingDeposit) {
    // C02: 급여일(pPrev) 당일·연체(예정일 < t0) 미지급 의무만 입금 확인 뒤 반영한다.
    // 그 밖의 의무는 유지 중인 이전 구간 밖이다. 어느 쪽이든 대기 중 E에는 넣지 않는다.
    final salaryDayOrOverdue = due == cycle.periodEnd || due.isBefore(today);
    return salaryDayOrOverdue
        ? ObligationPlacement.awaitingSalary
        : ObligationPlacement.outsidePeriod;
  }
  return due.isBefore(cycle.periodEnd!)
      ? ObligationPlacement.inCurrentPeriod
      : ObligationPlacement.outsidePeriod;
}
