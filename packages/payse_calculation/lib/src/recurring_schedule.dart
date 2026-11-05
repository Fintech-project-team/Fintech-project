import 'business_date.dart';
import 'inputs.dart';
import 'money.dart';

/// 2026-11-04: 서버에서 재조회한 사용자 확정 월간 계획. 후보를 이 타입으로 자동 변환하지 않는다.
class RecurringPlan {
  /// 2026-11-04: 저장된 식별자와 사용자가 승인한 첫 회차월을 받는다.
  RecurringPlan({required this.planId, required String firstOccurrenceMonth})
    : firstMonth = PayMonth.parse(firstOccurrenceMonth, 'plan.firstMonth') {
    requireId(planId, 'plan.planId');
  }

  final String planId;
  final PayMonth firstMonth;
}

/// 2026-11-04: 신용카드 구매 회차는 직접 출금 의무로 바꾸지 않는다.
enum RecurringPaymentTiming { immediate, cardBill }

/// 2026-11-04: 반복 일자의 의미를 구매와 출금으로 구분한다.
enum RecurringScheduleBasis { withdrawal, purchase }

/// 2026-11-04: 해당 명목 회차만 우선하는 확인 일정. 휴일 추정은 입력할 수 없다.
class RecurringScheduleOverride {
  /// 2026-11-04: 원천 또는 사용자 확인 근거를 포함한 개별 일정을 받는다.
  RecurringScheduleOverride({
    required String occurrenceMonth,
    required String plannedDate,
    required this.evidenceRef,
  }) : month = PayMonth.parse(occurrenceMonth, 'scheduleOverride.month'),
       date = BusinessDate.parse(plannedDate, 'scheduleOverride.date') {
    requireId(evidenceRef, 'scheduleOverride.evidenceRef');
  }

  final PayMonth month;
  final BusinessDate date;
  final String evidenceRef;
}

/// 2026-11-04: 확정 계획의 저장 버전. 과거 버전도 고정 회차 참조를 위해 보존한다.
class RecurringPlanRevision {
  /// 2026-11-04: 원래 월간 일자·출금 계좌·일정 의미를 그대로 받는다.
  RecurringPlanRevision({
    required this.revisionId,
    required this.planId,
    required String effectiveFromMonth,
    required this.isCurrent,
    required int amountKrw,
    required this.monthlyDay,
    required this.withdrawalAccountId,
    required this.paymentTiming,
    required this.scheduleBasis,
    required this.status,
    this.cardId,
    Iterable<RecurringScheduleOverride> scheduleOverrides = const [],
  }) : effectiveMonth = PayMonth.parse(effectiveFromMonth, 'revision.month'),
       amountKrw = requireMoney(amountKrw, 'revision.amountKrw'),
       scheduleOverrides = List.unmodifiable(scheduleOverrides) {
    requireId(revisionId, 'revision.id');
    requireId(planId, 'revision.planId');
    requireId(withdrawalAccountId, 'revision.withdrawalAccountId');
    if (monthlyDay < 1 || monthlyDay > 31) _invalid('revision.monthlyDay');
    if (paymentTiming == RecurringPaymentTiming.immediate &&
        (cardId != null ||
            scheduleBasis != RecurringScheduleBasis.withdrawal)) {
      _invalid('revision.scheduleBasis');
    }
    if (paymentTiming == RecurringPaymentTiming.cardBill) {
      requireId(cardId ?? '', 'revision.cardId');
    }
    final months = <PayMonth>{};
    for (final override in this.scheduleOverrides) {
      if (!months.add(override.month)) _invalid('revision.scheduleOverrides');
    }
  }

  final String revisionId;
  final String planId;
  final PayMonth effectiveMonth;
  final bool isCurrent;
  final int amountKrw;
  final int monthlyDay;
  final String withdrawalAccountId;
  final RecurringPaymentTiming paymentTiming;
  final RecurringScheduleBasis scheduleBasis;
  final ObligationStatus status;
  final String? cardId;
  final List<RecurringScheduleOverride> scheduleOverrides;
}

/// 2026-11-04: 저장된 현금 회차 또는 개별 수정. 실제 의무 ID와 고정 버전을 유지한다.
class FixedRecurringOccurrence {
  /// 2026-11-04: 같은 스냅샷의 회차·버전·의무를 받는다. 개별 수정은 로컬 회차 ID를 쓸 수 있다.
  FixedRecurringOccurrence({
    required this.planId,
    required String occurrenceMonth,
    required this.revisionId,
    required this.obligation,
  }) : month = PayMonth.parse(occurrenceMonth, 'fixedOccurrence.month') {
    requireId(planId, 'fixedOccurrence.planId');
    requireId(revisionId, 'fixedOccurrence.revisionId');
  }

  final String planId;
  final PayMonth month;
  final String revisionId;
  final Obligation obligation;
  String get key => '$planId:$month';
}

/// 2026-11-04: 직접 현금 의무로 변환할 수 없는 카드 회차의 확인 요청이다.
class RecurringScheduleIssue {
  /// 2026-11-04: 카드 청구 연결·일정이 필요한 회차를 식별한다.
  const RecurringScheduleIssue(this.recurrenceKey, this.cardId);
  final String recurrenceKey;
  final String cardId;
}

/// 2026-11-04: 한 달의 확정 계획 투영. 정보 부족은 빈 지출 목록으로 반환하지 않는다.
class RecurringSchedule {
  /// 2026-11-04: 입력 문맥과 의무/제한 목록을 불변으로 보존한다.
  RecurringSchedule(
    this.context,
    this.month,
    Iterable<Obligation> cash,
    Iterable<RecurringScheduleIssue> issues,
    Map<String, String> revisionIds,
  ) : _cash = List.unmodifiable(cash),
      issues = List.unmodifiable(issues),
      revisionIds = Map.unmodifiable(revisionIds);

  final CalculationContext context;
  final PayMonth month;
  final List<Obligation> _cash;
  final List<RecurringScheduleIssue> issues;
  final Map<String, String> revisionIds;

  /// 2026-11-04: 카드 청구 연결 미확인은 null. 기존 의무와 ID로 합쳐 같은 의무를 두 번 넣지 않는다.
  List<Obligation>? get cashObligations => issues.isEmpty ? _cash : null;
}

/// 2026-11-04: 필요한 한 달만 순수 계산한다. 저장된 회차는 고정 버전/수정/ID를 유지한다.
/// [coveredCardKeys]는 같은 버전의 occurrenceLinks→청구 대표 의무가 확인된 회차만 포함한다.
/// 그 청구 의무는 호출자가 기존 장부에 한 번 포함한다. 미확인 청구는 계산 제한으로 반환한다.
RecurringSchedule expandRecurring({
  required CalculationContext context,
  required PayMonth month,
  required Iterable<RecurringPlan> plans,
  required Iterable<RecurringPlanRevision> revisions,
  Iterable<FixedRecurringOccurrence> fixedOccurrences = const [],
  Set<String> coveredCardKeys = const {},
}) {
  final byPlan = <String, RecurringPlan>{};
  for (final plan in plans) {
    if (byPlan.containsKey(plan.planId)) _invalid('plans.duplicate');
    byPlan[plan.planId] = plan;
  }
  final byRevision = <String, RecurringPlanRevision>{};
  final currentKeys = <String>{};
  for (final revision in revisions) {
    final plan = byPlan[revision.planId];
    if (plan == null ||
        revision.effectiveMonth.compareTo(plan.firstMonth) < 0 ||
        byRevision.containsKey(revision.revisionId)) {
      _invalid('revisions');
    }
    if (revision.isCurrent &&
        !currentKeys.add('${revision.planId}:${revision.effectiveMonth}')) {
      _invalid('revisions.current');
    }
    byRevision[revision.revisionId] = revision;
  }
  final fixed = <String, FixedRecurringOccurrence>{};
  final fixedIds = <String>{};
  for (final item in fixedOccurrences) {
    final plan = byPlan[item.planId];
    final revision = byRevision[item.revisionId];
    if (plan == null ||
        revision == null ||
        revision.planId != item.planId ||
        revision.paymentTiming != RecurringPaymentTiming.immediate ||
        item.month.compareTo(plan.firstMonth) < 0 ||
        item.month.compareTo(revision.effectiveMonth) < 0 ||
        fixed.containsKey(item.key) ||
        !fixedIds.add(item.obligation.obligationId)) {
      _invalid('fixedOccurrences');
    }
    fixed[item.key] = item;
  }
  final recognizedCardKeys = <String>{};
  final cash = <Obligation>[];
  final issues = <RecurringScheduleIssue>[];
  final selectedRevisions = <String, String>{};
  for (final plan in byPlan.values) {
    final all = byRevision.values
        .where((r) => r.planId == plan.planId)
        .toList();
    if (!all.any((r) => r.effectiveMonth == plan.firstMonth)) {
      _invalid('revisions.firstMonth');
    }
    if (month.compareTo(plan.firstMonth) < 0) continue;
    final key = '${plan.planId}:$month';
    final pinned = fixed[key];
    if (pinned != null) {
      cash.add(pinned.obligation);
      selectedRevisions[key] = pinned.revisionId;
      continue;
    }
    final eligible =
        all
            .where((r) => r.isCurrent && r.effectiveMonth.compareTo(month) <= 0)
            .toList()
          ..sort((a, b) => a.effectiveMonth.compareTo(b.effectiveMonth));
    if (eligible.isEmpty) _invalid('revisions.missingCurrent');
    final revision = eligible.last;
    selectedRevisions[key] = revision.revisionId;
    if (revision.status == ObligationStatus.cancelled) continue;
    if (revision.paymentTiming == RecurringPaymentTiming.cardBill) {
      recognizedCardKeys.add(key);
      if (!coveredCardKeys.contains(key)) {
        issues.add(RecurringScheduleIssue(key, revision.cardId!));
      }
      continue;
    }
    var due = BusinessDate.monthly(
      month.year,
      month.month,
      revision.monthlyDay,
    ).date;
    for (final override in revision.scheduleOverrides) {
      if (override.month == month) due = override.date;
    }
    cash.add(
      Obligation(
        obligationId: key,
        withdrawalAccountId: revision.withdrawalAccountId,
        amountKrw: revision.amountKrw,
        dueDate: due.toString(),
        status: revision.status,
      ),
    );
  }
  if (!recognizedCardKeys.containsAll(coveredCardKeys)) {
    _invalid('coveredCardKeys');
  }
  cash.sort((a, b) => a.obligationId.compareTo(b.obligationId));
  return RecurringSchedule(context, month, cash, issues, selectedRevisions);
}

/// 2026-11-04: 잘못된 저장 구조를 지출 0원으로 해석하지 않는다.
Never _invalid(String path) => throw CalculationInputException(
  InputErrorCode.invalidValue,
  'recurringSchedule.$path',
  '불일치하거나 중복된 계획 자료',
);
