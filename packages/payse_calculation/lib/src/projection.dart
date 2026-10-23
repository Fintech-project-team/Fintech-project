import 'business_date.dart';
import 'inputs.dart';
import 'ledger.dart';
import 'money.dart';
import 'salary_cycle.dart';

/// 2026-10-23: 미래 월급일의 근거. 확인된 일정인지 사용자가 가정했는지 결과에 남긴다.
enum PayDateBasis { confirmed, assumed }

/// 2026-10-23: 구간 경계 p1~p3 하나와 그날 입금될 월급.
class PlannedPayDate {
  /// 2026-10-23: 날짜 [date](YYYY-MM-DD), 금액 [amountKrw](Money, null 미입력), 근거 [basis],
  /// 말일 보정 여부 [monthEndAdjusted]로 만든다.
  PlannedPayDate({
    required String date,
    required int? amountKrw,
    required this.basis,
    this.monthEndAdjusted = false,
  }) : date = BusinessDate.parse(date, 'payDates.date'),
       amountKrw = amountKrw == null
           ? null
           : requireMoney(amountKrw, 'payDates[$date].amountKrw');

  final BusinessDate date;
  final int? amountKrw;
  final PayDateBasis basis;
  final bool monthEndAdjusted;
}

/// 2026-10-23: [after]보다 늦은 월급일 [count]개를 [salaryDay] 규칙으로 가정한다.
/// 각 달은 원래 일자에서 말일 보정하고 보정 여부를 표시한다. 휴일 이동은 만들지 않는다.
List<PlannedPayDate> assumedPayDates({
  required BusinessDate after,
  required int salaryDay,
  required int? amountKrw,
  int count = 3,
}) {
  if (salaryDay < 1 || salaryDay > 31) {
    throw CalculationInputException(
      InputErrorCode.invalidValue,
      'salaryDay',
      '1~31이어야 함($salaryDay)',
    );
  }
  var offset =
      monthlyPayDate(after.year, after.month, salaryDay).date.isAfter(after)
      ? 0
      : 1;
  final result = <PlannedPayDate>[];
  while (result.length < count) {
    final (y, m) = after.shiftMonth(offset);
    final pay = monthlyPayDate(y, m, salaryDay);
    result.add(
      PlannedPayDate(
        date: pay.date.toString(),
        amountKrw: amountKrw,
        basis: PayDateBasis.assumed,
        monthEndAdjusted: pay.monthEndAdjusted,
      ),
    );
    offset += 1;
  }
  return List.unmodifiable(result);
}

/// 2026-10-23: 가상 소비 결제 방식.
enum PaymentMethod { immediate, cardLumpSum }

/// 2026-10-23: 가상 소비 한 건. 실제 거래·의무로 저장하지 않는다.
class VirtualPurchase {
  /// 2026-10-23: [itemId], 금액 [amountKrw](PositiveMoney), 구매일 [purchaseDate], 결제 방식,
  /// 카드 확인 출금일 [plannedWithdrawalDate](카드만, null 미확인)로 만든다.
  VirtualPurchase({
    required this.itemId,
    required int amountKrw,
    required String purchaseDate,
    required this.paymentMethod,
    String? plannedWithdrawalDate,
  }) : amountKrw = requirePositiveMoney(amountKrw, 'items[$itemId].amountKrw'),
       purchaseDate = BusinessDate.parse(
         purchaseDate,
         'items[$itemId].purchaseDate',
       ),
       plannedWithdrawalDate = plannedWithdrawalDate == null
           ? null
           : BusinessDate.parse(
               plannedWithdrawalDate,
               'items[$itemId].plannedWithdrawalDate',
             ) {
    requireId(itemId, 'items.itemId');
    final withdrawal = this.plannedWithdrawalDate;
    if (paymentMethod == PaymentMethod.immediate && withdrawal != null) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'items[$itemId].plannedWithdrawalDate',
        '즉시출금은 구매일에 출금하므로 별도 출금일을 받지 않음',
      );
    }
    if (withdrawal != null && withdrawal.isBefore(this.purchaseDate)) {
      throw CalculationInputException(
        InputErrorCode.invalidSchedule,
        'items[$itemId].plannedWithdrawalDate',
        '카드 결제일이 구매일보다 이름',
      );
    }
  }

  final String itemId;
  final int amountKrw;
  final BusinessDate purchaseDate;
  final PaymentMethod paymentMethod;
  final BusinessDate? plannedWithdrawalDate;
}

/// 2026-10-23: 구간 계산 입력. [payDates]는 p1~p3(최대 3개), [items]는 가상 소비 0~5건이다.
class ProjectionInput {
  /// 2026-10-23: 장부 [ledger], 월급일 [payDates], 가상 소비 [items]로 만든다. 목록은 복사해 보관한다.
  ProjectionInput({
    required this.ledger,
    required List<PlannedPayDate> payDates,
    required List<VirtualPurchase> items,
  }) : payDates = List.unmodifiable(payDates),
       items = List.unmodifiable(items);

  final LedgerInput ledger;
  final List<PlannedPayDate> payDates;
  final List<VirtualPurchase> items;
}

/// 2026-10-23: 가상 소비가 현금 이벤트로 반영된 상태.
enum ItemPlacementStatus { reflected, outOfRange, scheduleUnknown }

/// 2026-10-23: 가상 소비 한 건의 현금 출금일과 귀속 구간.
class ItemPlacement {
  /// 2026-10-23: [itemId], 현금 출금일 [cashDate](null 미확인), 귀속 구간 [periodIndex](1~3, null 미귀속), [status]로 만든다.
  const ItemPlacement({
    required this.itemId,
    required this.cashDate,
    required this.periodIndex,
    required this.status,
  });

  final String itemId;
  final BusinessDate? cashDate;
  final int? periodIndex;
  final ItemPlacementStatus status;
}

/// 2026-10-23: 시각 없는 같은 날 입금·출금. 일중 순서는 확정하지 않는다.
class DayOrderWarning {
  /// 2026-10-23: 날짜 [date]와 출금이 먼저면 전날 일 마감 H로 부족해지는지 [possibleIntradayShortfall]로 만든다.
  const DayOrderWarning(this.date, this.possibleIntradayShortfall);

  final BusinessDate date;
  final bool possibleIntradayShortfall;
}

/// 2026-10-23: 구간 하나의 일 마감 기준 결과. 정보 부족이면 금액이 null이다.
class PeriodResult {
  /// 2026-10-23: 구간 번호 [index](1~3), [start]·[end](끝 제외, null 미정), 완전·잘림 여부, 금액·사유로 만든다.
  PeriodResult({
    required this.index,
    required this.start,
    required this.end,
    required this.complete,
    required this.startH,
    required this.endH,
    required this.endA,
    required this.minH,
    required this.minA,
    required List<InsufficientReason> insufficient,
  }) : insufficient = List.unmodifiable(insufficient);

  final int index;
  final BusinessDate? start;
  final BusinessDate? end;

  /// 2026-10-23: 월급일 p_k가 상한 이내면 true, 상한에 잘렸으면 false, 경계 미정이면 null.
  final bool? complete;
  final int? startH;
  final int? endH;

  /// 2026-10-23: 종료 직전(끝 전날 일 마감) A.
  final int? endA;
  final int? minH;
  final int? minA;
  final List<InsufficientReason> insufficient;
}

/// 2026-10-23: 한 시나리오(기존 또는 가상 소비 모두 반영)의 구간 결과.
class ScenarioResult {
  /// 2026-10-23: 구간 결과 [periods]와 일중 순서 경고 [dayOrderWarnings]로 만든다.
  ScenarioResult({
    required List<PeriodResult> periods,
    required List<DayOrderWarning> dayOrderWarnings,
  }) : periods = List.unmodifiable(periods),
       dayOrderWarnings = List.unmodifiable(dayOrderWarnings);

  final List<PeriodResult> periods;
  final List<DayOrderWarning> dayOrderWarnings;
}

/// 2026-10-23: 구간별 H/A 결과. 최대 부족액·최초 부족 시점은 포함하지 않는다.
class ProjectionResult {
  /// 2026-10-23: 기준 [context], 상한 [horizonEnd], 시나리오 결과, 구간별 종료 A 차이, 범위 밖 항목, 사유로 만든다.
  ProjectionResult({
    required this.context,
    required this.horizonEnd,
    required this.baseline,
    required this.allItems,
    required List<int?>? endADifferences,
    required List<ItemPlacement> itemPlacements,
    required List<String> outOfRangeObligationIds,
    required List<String> excludedAccountObligationIds,
    required List<InsufficientReason> insufficient,
  }) : endADifferences = endADifferences == null
           ? null
           : List.unmodifiable(endADifferences),
       itemPlacements = List.unmodifiable(itemPlacements),
       outOfRangeObligationIds = List.unmodifiable(outOfRangeObligationIds),
       excludedAccountObligationIds = List.unmodifiable(
         excludedAccountObligationIds,
       ),
       insufficient = List.unmodifiable(insufficient);

  final CalculationContext context;

  /// 2026-10-23: 전체 종료 상한 min(p3, t0+달력3개월). p3가 없으면 t0+달력3개월.
  final BusinessDate horizonEnd;
  final ScenarioResult? baseline;

  /// 2026-10-23: 가상 소비 모두 반영 결과. 가상 소비가 0건이면 결과를 해제해 null이다.
  final ScenarioResult? allItems;

  /// 2026-10-23: 구간별 종료 직전 A 차이(allItems − baseline). 세 구간을 합산하지 않는다.
  final List<int?>? endADifferences;
  final List<ItemPlacement> itemPlacements;

  /// 2026-10-23: 상한 이후 예정이라 반영하지 않은 의무. 영향 없음이 아니라 미반영이다.
  final List<String> outOfRangeObligationIds;

  /// 2026-10-23: 출금 계좌가 제외 계좌라 포함 계좌 기준 구간에 넣지 않은 활성 미정산 의무.
  final List<String> excludedAccountObligationIds;
  final List<InsufficientReason> insufficient;

  /// 2026-10-23: 시각 없는 날짜 입력만 쓰므로 항상 일 마감 기준이다.
  String get timePrecision => 'day_end';
}

class _Frame {
  _Frame(this.index, this.start, this.end, this.complete, this.issue);

  final int index;
  final BusinessDate? start;
  final BusinessDate? end;
  final bool? complete;
  final InsufficientReason? issue;
}

class _CashEvent {
  const _CashEvent(this.date, this.inflowKrw, this.outflowKrw, this.releaseKrw);

  final BusinessDate date;
  final int inflowKrw;
  final int outflowKrw;

  /// 2026-10-23: 배정 의무를 가상 출금할 때 함께 해제하는 R 겹침.
  final int releaseKrw;
}

/// 2026-10-23: [input]으로 C1~C3 구간별 일 마감 H/A를 계산한다. 현재 시각·이전 A를 쓰지 않는다.
/// H=이전 H+입금−출금, A=H−(같은 구간 남은 출금 예약+연체 잔여)−(남은 R−남은 예약과 겹치는 O)다.
ProjectionResult projectPeriods(ProjectionInput input) {
  final ledger = Ledger.prepare(input.ledger);
  final context = input.ledger.context;
  final t0 = context.businessDate;
  final calendarCap = t0.addMonthsClamped(3);

  final pays = input.payDates;
  if (pays.length > 3) {
    throw CalculationInputException(
      InputErrorCode.invalidValue,
      'payDates',
      '최대 3개(${pays.length})',
    );
  }
  for (var i = 0; i < pays.length; i++) {
    final previous = i == 0 ? t0 : pays[i - 1].date;
    if (!pays[i].date.isAfter(previous)) {
      throw CalculationInputException(
        InputErrorCode.invalidSchedule,
        'payDates[$i]',
        'p1은 t0보다, 이후 월급일은 앞 월급일보다 늦어야 함',
      );
    }
  }
  final cap = pays.length == 3 && pays[2].date.isBefore(calendarCap)
      ? pays[2].date
      : calendarCap;
  final frames = _frames(t0, pays, cap);

  final items = input.items;
  if (items.length > 5) {
    throw CalculationInputException(
      InputErrorCode.invalidValue,
      'items',
      '가상 소비는 최대 5건(${items.length})',
    );
  }
  final itemIds = <String>{};
  for (final item in items) {
    if (!itemIds.add(item.itemId)) {
      throw CalculationInputException(
        InputErrorCode.duplicateId,
        'items',
        item.itemId,
      );
    }
    if (item.purchaseDate.isBefore(t0) || !item.purchaseDate.isBefore(cap)) {
      throw CalculationInputException(
        InputErrorCode.invalidSchedule,
        'items[${item.itemId}].purchaseDate',
        '구매일은 t0 이상 상한 전이어야 함',
      );
    }
  }
  final placements = [for (final item in items) _placeItem(item, frames, cap)];

  final issues = <InsufficientReason>[
    ...ledger.bIssues,
    ...ledger.obligationIssues,
    ...ledger.reserveIssues,
    ...ledger.overlapIssues,
  ];
  final baseEvents = <_CashEvent>[];
  var carriedKrw = 0;
  var carriedOverlapKrw = 0;
  final outOfRange = <String>[];
  final excludedAccount = <String>[];
  final states = ledger.obligations;
  final overlap = ledger.overlapByObligation;
  if (states != null && overlap != null) {
    for (final s in states) {
      if (!s.open) continue;
      if (!ledger.isIncluded(s.obligation.withdrawalAccountId)) {
        // 포함 계좌 기준 구간이라 제외 계좌 의무는 이벤트·예약에 넣지 않고 따로 안내한다.
        excludedAccount.add(s.obligation.obligationId);
        continue;
      }
      final due = s.obligation.dueDate;
      if (!due.isBefore(cap)) {
        outOfRange.add(s.obligation.obligationId);
        continue;
      }
      // 가상 출금 때 해제하는 보호액은 이 의무에 연결된 미해제 배정 중 출금액만큼이다.
      // 다른 의무의 배정이나 배정되지 않은 보호액은 그대로 남는다.
      final linked = overlap[s.obligation.obligationId] ?? 0;
      final release = linked < s.remainingKrw ? linked : s.remainingKrw;
      if (due.isBefore(t0)) {
        // 연체 미지급 의무는 지급일을 만들지 않고 남은 의무로 계속 예약한다(C09).
        carriedKrw = addKrw(carriedKrw, s.remainingKrw, 'carried');
        carriedOverlapKrw = addKrw(carriedOverlapKrw, release, 'carriedO');
      } else {
        baseEvents.add(_CashEvent(due, 0, s.remainingKrw, release));
      }
    }
  }

  var salaryMissingFrom = frames.length;
  for (var j = 0; j < pays.length; j++) {
    final pay = pays[j];
    if (!pay.date.isBefore(cap)) continue;
    final amount = pay.amountKrw;
    if (amount == null) {
      salaryMissingFrom = salaryMissingFrom < j + 1 ? salaryMissingFrom : j + 1;
      continue;
    }
    baseEvents.add(_CashEvent(pay.date, amount, 0, 0));
  }

  final dedupedIssues = <InsufficientReason>[];
  for (final reason in issues) {
    if (!dedupedIssues.contains(reason)) dedupedIssues.add(reason);
  }
  if (dedupedIssues.isNotEmpty) {
    return ProjectionResult(
      context: context,
      horizonEnd: cap,
      baseline: null,
      allItems: null,
      endADifferences: null,
      itemPlacements: placements,
      outOfRangeObligationIds: outOfRange,
      excludedAccountObligationIds: excludedAccount,
      insufficient: dedupedIssues,
    );
  }

  final start = _Start(
    h: ledger.b!,
    r: ledger.r!,
    carriedKrw: carriedKrw,
    carriedOverlapKrw: carriedOverlapKrw,
  );
  final baseline = _simulate(
    start,
    frames,
    baseEvents,
    _nullFrom(salaryMissingFrom, InsufficientReason.salaryAmountMissing),
  );

  ScenarioResult? allItems;
  List<int?>? differences;
  if (items.isNotEmpty) {
    var unknownFrom = frames.length;
    final itemEvents = <_CashEvent>[...baseEvents];
    for (var i = 0; i < items.length; i++) {
      final placement = placements[i];
      if (placement.status == ItemPlacementStatus.reflected) {
        itemEvents.add(
          _CashEvent(placement.cashDate!, 0, items[i].amountKrw, 0),
        );
      } else if (placement.status == ItemPlacementStatus.scheduleUnknown) {
        // 결제일 미상이면 구매일 이후 끝나는 구간의 비교를 미완성으로 둔다(카드 결제는 구매일보다 이르지 않음).
        for (var k = 0; k < frames.length; k++) {
          final end = frames[k].end;
          if (end == null || end.isAfter(items[i].purchaseDate)) {
            if (k < unknownFrom) unknownFrom = k;
            break;
          }
        }
      }
    }
    allItems = _simulate(start, frames, itemEvents, {
      ..._nullFrom(salaryMissingFrom, InsufficientReason.salaryAmountMissing),
      ..._nullFrom(unknownFrom, InsufficientReason.cardScheduleUnknown),
    });
    differences = [
      for (var k = 0; k < baseline.periods.length; k++)
        (allItems.periods[k].endA != null && baseline.periods[k].endA != null)
            ? subtractKrw(
                allItems.periods[k].endA!,
                baseline.periods[k].endA!,
                'difference[$k]',
              )
            : null,
    ];
  }

  return ProjectionResult(
    context: context,
    horizonEnd: cap,
    baseline: baseline,
    allItems: allItems,
    endADifferences: differences,
    itemPlacements: placements,
    outOfRangeObligationIds: outOfRange,
    excludedAccountObligationIds: excludedAccount,
    insufficient: const [],
  );
}

class _Start {
  const _Start({
    required this.h,
    required this.r,
    required this.carriedKrw,
    required this.carriedOverlapKrw,
  });

  final int h;
  final int r;
  final int carriedKrw;
  final int carriedOverlapKrw;
}

/// 2026-10-23: 구간 [from] 이후(0부터 센 번호)를 [reason]으로 null 처리하는 표를 만든다.
Map<int, InsufficientReason> _nullFrom(int from, InsufficientReason reason) => {
  for (var k = from; k < 3; k++) k: reason,
};

/// 2026-10-23: t0, 월급일 [pays], 상한 [cap]으로 C1~C3 경계를 만든다. 시작이 상한 이상인 구간은 없다.
List<_Frame> _frames(
  BusinessDate t0,
  List<PlannedPayDate> pays,
  BusinessDate cap,
) {
  final frames = <_Frame>[];
  for (var k = 0; k < 3; k++) {
    final BusinessDate? start = k == 0
        ? t0
        : (pays.length >= k ? pays[k - 1].date : null);
    if (start == null) {
      frames.add(
        _Frame(k + 1, null, null, null, InsufficientReason.payDateMissing),
      );
      continue;
    }
    if (!start.isBefore(cap)) break;
    if (pays.length <= k) {
      frames.add(
        _Frame(k + 1, start, null, null, InsufficientReason.payDateMissing),
      );
      continue;
    }
    final pk = pays[k].date;
    final complete = !pk.isAfter(cap);
    frames.add(_Frame(k + 1, start, complete ? pk : cap, complete, null));
  }
  return frames;
}

/// 2026-10-23: 가상 소비 [item]의 현금 출금일과 귀속 구간을 정한다. 카드 승인일에는 출금하지 않는다.
ItemPlacement _placeItem(
  VirtualPurchase item,
  List<_Frame> frames,
  BusinessDate cap,
) {
  final cashDate = item.paymentMethod == PaymentMethod.immediate
      ? item.purchaseDate
      : item.plannedWithdrawalDate;
  if (cashDate == null) {
    return ItemPlacement(
      itemId: item.itemId,
      cashDate: null,
      periodIndex: null,
      status: ItemPlacementStatus.scheduleUnknown,
    );
  }
  if (!cashDate.isBefore(cap)) {
    return ItemPlacement(
      itemId: item.itemId,
      cashDate: cashDate,
      periodIndex: null,
      status: ItemPlacementStatus.outOfRange,
    );
  }
  int? index;
  for (final f in frames) {
    final start = f.start;
    final end = f.end;
    if (start != null &&
        end != null &&
        !cashDate.isBefore(start) &&
        cashDate.isBefore(end)) {
      index = f.index;
    }
  }
  return ItemPlacement(
    itemId: item.itemId,
    cashDate: cashDate,
    periodIndex: index,
    status: ItemPlacementStatus.reflected,
  );
}

/// 2026-10-23: [events]를 날짜순 일 마감으로 적용해 구간 결과를 만든다. [nulls]의 구간과 그 뒤는 값이 null이다.
ScenarioResult _simulate(
  _Start start,
  List<_Frame> frames,
  List<_CashEvent> events,
  Map<int, InsufficientReason> nulls,
) {
  var h = start.h;
  var r = start.r;
  final periods = <PeriodResult>[];
  final warnings = <DayOrderWarning>[];
  final stopReasons = <InsufficientReason>[];
  for (var k = 0; k < frames.length; k++) {
    final f = frames[k];
    final frameStart = f.start;
    final frameEnd = f.end;
    // 앞 구간 H를 모르면 뒤 구간도 이월 값을 알 수 없으므로 앞 사유를 이어받는다.
    for (final reason in [f.issue, nulls[k]]) {
      if (reason != null && !stopReasons.contains(reason)) {
        stopReasons.add(reason);
      }
    }
    if (stopReasons.isNotEmpty || frameStart == null || frameEnd == null) {
      periods.add(
        PeriodResult(
          index: f.index,
          start: frameStart,
          end: frameEnd,
          complete: f.complete,
          startH: null,
          endH: null,
          endA: null,
          minH: null,
          minA: null,
          insufficient: stopReasons,
        ),
      );
      continue;
    }
    final inFrame = events
        .where((e) => !e.date.isBefore(frameStart) && e.date.isBefore(frameEnd))
        .toList();
    final startH = h;
    int? minH;
    int? minA;
    var a = 0;
    for (var d = frameStart; d.isBefore(frameEnd); d = d.addDays(1)) {
      var inflow = 0;
      var outflow = 0;
      var release = 0;
      var pending = start.carriedKrw;
      var pendingOverlap = start.carriedOverlapKrw;
      for (final e in inFrame) {
        if (e.date == d) {
          inflow = addKrw(inflow, e.inflowKrw, 'inflow[$d]');
          outflow = addKrw(outflow, e.outflowKrw, 'outflow[$d]');
          release = addKrw(release, e.releaseKrw, 'release[$d]');
        } else if (e.date.isAfter(d)) {
          pending = addKrw(pending, e.outflowKrw, 'pending[$d]');
          pendingOverlap = addKrw(pendingOverlap, e.releaseKrw, 'pendingO[$d]');
        }
      }
      if (inflow > 0 && outflow > 0) {
        warnings.add(
          DayOrderWarning(d, subtractKrw(h, outflow, 'worst[$d]') < 0),
        );
      }
      h = subtractKrw(addKrw(h, inflow, 'H[$d]'), outflow, 'H[$d]');
      r = subtractKrw(r, release, 'R[$d]');
      final protection = subtractKrw(r, pendingOverlap, 'R-O[$d]');
      a = subtractKrw(subtractKrw(h, pending, 'A[$d]'), protection, 'A[$d]');
      if (minH == null || h < minH) minH = h;
      if (minA == null || a < minA) minA = a;
    }
    periods.add(
      PeriodResult(
        index: f.index,
        start: frameStart,
        end: frameEnd,
        complete: f.complete,
        startH: startH,
        endH: h,
        endA: a,
        minH: minH,
        minA: minA,
        insufficient: const [],
      ),
    );
  }
  return ScenarioResult(periods: periods, dayOrderWarnings: warnings);
}
