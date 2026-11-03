import 'package:payse_calculation/payse_calculation.dart' as calc;

import '../../shared/design/amount_format.dart';
import '../overview/calculation_detail_screen.dart' show dueLabel, md, mdText;

/// 2026-11-02: 계획 탭 기간 종류. 월급 기간은 홈 계산의 월급 주기, 달력 월은 1일~말일이다.
enum PlanPeriodKind { salary, month }

/// 2026-11-02: 월급 기간의 위치. 기준 시각의 현재 주기를 기준으로 앞뒤를 나눈다.
enum SalaryRole { past, current, next, later }

/// 2026-11-02: 계획 탭의 조회 기간 [start, end). [start]가 null이면 시작일을 알 수 없는 현재 월급 기간이다.
class PlanPeriod {
  /// 2026-11-02: 종류 [kind], 시작 [start](포함), 끝 [end](제외), 월급 기간 위치 [role]로 만든다.
  const PlanPeriod({
    required this.kind,
    required this.start,
    required this.end,
    this.role,
  });

  final PlanPeriodKind kind;
  final calc.BusinessDate? start;
  final calc.BusinessDate end;
  final SalaryRole? role;

  /// 2026-11-02: 예정일 [due]가 이 기간에 들면 true다.
  bool contains(calc.BusinessDate due) =>
      due.isBefore(end) && (start == null || !due.isBefore(start!));

  /// 2026-11-02: 머리 제목. 현재 월급 기간은 '다음 월급일까지', 그 밖의 월급 기간은 날짜 범위, 달력 월은 'YYYY년 M월'이다.
  String get title => switch ((kind, role)) {
    (PlanPeriodKind.month, _) =>
      '${end.addDays(-1).year}년 ${end.addDays(-1).month}월',
    (_, SalaryRole.current) => '다음 월급일까지',
    _ => range,
  };

  /// 2026-11-02: 실제 날짜 범위('9/25 ~ 10/24', 시작을 모르면 '~ 10/24').
  String get range {
    final last = md(end.addDays(-1));
    final s = start;
    return s == null ? '~ $last' : '${md(s)} ~ $last';
  }

  /// 2026-11-02: 범위 아래 설명. 현재 월급 기간은 날짜 범위, 다른 월급 기간은 위치 이름, 달력 월은 날짜 범위다.
  String get caption => switch ((kind, role)) {
    (PlanPeriodKind.month, _) || (_, SalaryRole.current) => range,
    (_, SalaryRole.past) => '지난 월급 기간',
    (_, SalaryRole.next) => '다음 월급 기간',
    _ => '그다음 월급 기간',
  };

  @override
  bool operator ==(Object other) =>
      other is PlanPeriod &&
      other.kind == kind &&
      other.start == start &&
      other.end == end;

  @override
  int get hashCode => Object.hash(kind, start, end);
}

/// 2026-11-02: 고를 수 있는 월급 기간 목록(오래된 순)과 현재 기간 위치.
typedef SalaryPeriods = ({List<PlanPeriod> periods, int currentIndex});

/// 2026-11-03: 기간 예측(계산 패키지 [calc.projectPeriods]) 구간 하나의 경계. null은 계산이 경계를 정하지 못한 것이다.
typedef ProjectionFrame = ({calc.BusinessDate? start, calc.BusinessDate? end});

/// 2026-11-03: 홈과 같은 장부 [ledger]·월급 입력 [salary]로 기간 예측을 실행해 구간 경계(C1~C3, 계산이 상한으로 자른 끝 포함)를
/// 돌려준다. 월급일·근거를 받지 못했거나, 계산 입력이 맞지 않거나, 계산이 구간 결과를 주지 않으면(baseline null) 빈 목록이다
/// (미래 월급 기간 없음).
List<ProjectionFrame> projectionFrames({
  required calc.BusinessDate today,
  required calc.LedgerInput? ledger,
  required calc.SalaryInput? salary,
}) {
  final day = salary?.salaryDay;
  final evidence = salary?.receiptEvidence;
  if (ledger == null || day == null || evidence == null) return const [];
  try {
    final scheduled = calc.scheduledPayDates(
      after: today,
      salaryDay: day,
      receiptEvidence: evidence,
      amountKrw: null,
    );
    final result = calc.projectPeriods(
      calc.ProjectionInput(
        ledger: ledger,
        payDates: scheduled.payDates,
        items: const [],
        salaryUncertainFrom: scheduled.uncertainFrom,
      ),
    );
    return [
      for (final p in result.baseline?.periods ?? const <calc.PeriodResult>[])
        (start: p.start, end: p.end),
    ];
  } on calc.CalculationInputException {
    return const [];
  }
}

/// 2026-11-02: 월급 기간 목록을 만든다. 현재 기간은 홈 계산 [cycle], 과거는 원천 월급 일정의 예정일로 앞뒤 경계가 모두 확인되는
/// 주기만이다. 현재 월급일 설정을 과거에 소급하지 않고 입금 거래일을 경계로 쓰지 않는다. 현재 기간을 정할 수 없으면 null이다.
/// 2026-11-03: 미래는 기간 예측 구간 [frames]의 끝 경계를 현재 기간 끝부터 그대로 이어 붙인다(계산이 자른 마지막 구간 포함,
/// 화면에서 상한을 따로 두지 않음). 끝을 정하지 못한 구간에서 멈춘다.
SalaryPeriods? salaryPeriods({
  required calc.SalaryCycle? cycle,
  required calc.SalaryInput? salary,
  List<ProjectionFrame> frames = const [],
}) {
  final end = cycle?.periodEnd;
  if (cycle == null || end == null) return null;
  final current = PlanPeriod(
    kind: PlanPeriodKind.salary,
    start: cycle.periodStart,
    end: end,
    role: SalaryRole.current,
  );
  final past = _pastPeriods(cycle, salary?.receiptEvidence);
  final future = _futurePeriods(end, frames);
  return (periods: [...past, current, ...future], currentIndex: past.length);
}

/// 2026-11-02: 현재 기간 시작부터 거꾸로, 바로 앞 명목 회차의 원천 예정일이 있고 그 사이에 다른 회차의 예정일이 끼지 않을
/// 때만 지난 월급 기간을 잇는다. 현재 시작일이 원천 예정일이 아니거나 근거를 받지 못했으면 지난 기간이 없다.
List<PlanPeriod> _pastPeriods(
  calc.SalaryCycle cycle,
  List<calc.SalaryReceipt>? evidence,
) {
  final start = cycle.periodStart;
  final pay = cycle.previousPayDate;
  final month = pay?.payMonth;
  if (evidence == null ||
      start == null ||
      pay == null ||
      month == null ||
      !pay.fromEvidence ||
      pay.date != start) {
    return const [];
  }
  final byMonth = {for (final r in evidence) r.payMonth: r};
  final result = <PlanPeriod>[];
  var end = start;
  var m = month;
  while (true) {
    final prev = byMonth[m.shift(-1)];
    if (prev == null || !prev.expectedPayDate.isBefore(end)) break;
    final s = prev.expectedPayDate;
    final between = evidence.any(
      (r) => r.expectedPayDate.isAfter(s) && r.expectedPayDate.isBefore(end),
    );
    if (between) break;
    result.insert(
      0,
      PlanPeriod(
        kind: PlanPeriodKind.salary,
        start: s,
        end: end,
        role: SalaryRole.past,
      ),
    );
    end = s;
    m = prev.payMonth;
  }
  return result;
}

/// 2026-11-03: 현재 기간 끝 [end] 이후의 월급 기간. 기간 예측 구간의 끝 경계 중 [end]보다 늦은 것을 차례로 잇는다.
List<PlanPeriod> _futurePeriods(
  calc.BusinessDate end,
  List<ProjectionFrame> frames,
) {
  final result = <PlanPeriod>[];
  var start = end;
  for (final f in frames) {
    final e = f.end;
    if (e == null) break;
    if (!e.isAfter(start)) continue;
    result.add(
      PlanPeriod(
        kind: PlanPeriodKind.salary,
        start: start,
        end: e,
        role: result.isEmpty ? SalaryRole.next : SalaryRole.later,
      ),
    );
    start = e;
  }
  return result;
}

/// 2026-11-02: [date]가 든 달력 월.
PlanPeriod monthOf(calc.BusinessDate date) {
  final first = calc.BusinessDate(date.year, date.month, 1);
  return PlanPeriod(
    kind: PlanPeriodKind.month,
    start: first,
    end: first.addMonthsClamped(1),
  );
}

/// 2026-11-02: 고를 수 있는 달력 월(오래된 순). 받은 예정 지출 [dues]의 가장 이른 달부터 가장 늦은 달까지이며 [today]의 달을
/// 항상 포함하고 빈 달도 건너뛰지 않는다.
List<PlanPeriod> calendarMonths(
  calc.BusinessDate today,
  Iterable<calc.BusinessDate> dues,
) {
  var first = monthOf(today);
  var last = first;
  for (final due in dues) {
    final m = monthOf(due);
    if (m.start!.isBefore(first.start!)) first = m;
    if (m.start!.isAfter(last.start!)) last = m;
  }
  final result = <PlanPeriod>[];
  for (var m = first; !m.start!.isAfter(last.start!); m = monthOf(m.end)) {
    result.add(m);
  }
  return result;
}

/// 2026-11-02: 예정 지출 한 건이 계획 탭에서 놓이는 구역.
enum PlanGroup { upcoming, done, excluded }

/// 2026-11-02: 홈 계산 결과의 위치로 구역을 정한다. 취소는 null(보이지 않음), 잔여 0은 이미 나간 돈, 계산 제외 계좌는 계산에서
/// 뺀 계좌, 그 밖(구간 미정 포함)은 앞으로 나갈 돈이다. 예정일이 지났다는 이유로 이미 나간 돈에 넣지 않는다.
PlanGroup? planGroup(calc.ObligationLine line) => switch (line.placement) {
  calc.ObligationPlacement.cancelled => null,
  calc.ObligationPlacement.settled => PlanGroup.done,
  calc.ObligationPlacement.excludedAccount => PlanGroup.excluded,
  _ => PlanGroup.upcoming,
};

/// 2026-11-02: 기간 [period]에 예정일이 든 예정 지출을 구역별로 예정일순(같은 날은 ID순)으로 나눈다.
Map<PlanGroup, List<calc.ObligationLine>> linesIn(
  PlanPeriod period,
  Iterable<calc.ObligationLine> lines,
) {
  final result = {for (final g in PlanGroup.values) g: <calc.ObligationLine>[]};
  for (final line in lines) {
    final group = planGroup(line);
    if (group != null && period.contains(line.dueDate)) {
      result[group]!.add(line);
    }
  }
  for (final list in result.values) {
    list.sort(_byDue);
  }
  return result;
}

int _byDue(calc.ObligationLine a, calc.ObligationLine b) {
  final byDate = a.dueDate.compareTo(b.dueDate);
  return byDate != 0 ? byDate : a.obligationId.compareTo(b.obligationId);
}

/// 2026-11-02: 기준 시각이 속한 기간 [current]보다 예정일이 이른 앞으로 나갈 돈(계산에서 뺀 계좌 제외). 시작일을 모르면 빈 목록이다.
List<calc.ObligationLine> carriedOver(
  PlanPeriod current,
  Iterable<calc.ObligationLine> lines,
) {
  final start = current.start;
  if (start == null) return const [];
  return [
    for (final line in lines)
      if (planGroup(line) == PlanGroup.upcoming && line.dueDate.isBefore(start))
        line,
  ]..sort(_byDue);
}

/// 2026-11-02: 앞으로 나갈 돈의 날짜 라벨(홈 [dueLabel]과 같은 규칙·문구). 지난 예정일은 '예정일 지남'이다. 예정일 전·당일은
/// [labelEnd](현재 월급 기간 다음 기간의 끝, 없으면 현재 기간 끝) 전일 때만 'D-n'·'오늘'이며, 월급 기간을 정할 수 없으면
/// ([labelEnd] null) 붙이지 않는다. 보고 있는 기간과 무관하다.
String? planDueLabel(
  calc.ObligationLine line,
  calc.BusinessDate today,
  calc.BusinessDate? labelEnd,
) {
  final due = line.dueDate;
  if (due.isBefore(today)) return '예정일 지남';
  if (labelEnd == null || !due.isBefore(labelEnd)) return null;
  return dueLabel(due, today);
}

/// 2026-11-02: 날짜 라벨 범위의 끝. 현재 월급 기간 바로 다음 기간이 있으면 그 끝, 없으면 현재 기간 끝이다.
calc.BusinessDate? labelEnd(SalaryPeriods? periods) {
  if (periods == null) return null;
  final i = periods.currentIndex;
  final list = periods.periods;
  return (i + 1 < list.length ? list[i + 1] : list[i]).end;
}

/// 2026-11-03: 일부 출금 줄의 출금 문구. [dates]는 유효 정산마다 연결 출금 거래의 출금일(거래를 못 찾았거나 날짜가 없으면 null),
/// [settledKrw]는 홈 계산의 정산 합계, [amountKrw]는 예정 금액이다. 모든 정산이 같은 확인된 날짜일 때만 'n원 중 M/D에 m원
/// 출금됐어요'이고, 정산이 하나인데 날짜를 모르면 'n원 중 m원 출금됐어요', 날짜가 여럿이거나 일부를 모르면 끝에 '(누적)'을 붙인다.
/// 한 날짜에 합계 전체를 붙이지 않는다. 2026-11-03 혜연 결정으로 '예정 n원 · M/D 출금 m원'에서 한 문장으로 바꿨고 '만'은 쓰지 않는다.
String withdrawalNote(List<String?> dates, int settledKrw, int amountKrw) {
  final head = '${formatKrw(amountKrw)} 중';
  final paid = formatKrw(settledKrw);
  final known = {for (final d in dates) ?d};
  if (dates.isNotEmpty && !dates.contains(null) && known.length == 1) {
    return '$head ${mdText(known.single)}에 $paid 출금됐어요';
  }
  return dates.length <= 1 ? '$head $paid 출금됐어요' : '$head $paid 출금됐어요 (누적)';
}
