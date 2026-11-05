import 'business_date.dart';
import 'inputs.dart';
import 'money.dart';
import 'recurring_input.dart';

/// 2026-11-04: 의미 분석의 정상·유보·실패·진행 상태. 빈 후보와 혼동하지 않는다.
enum RecurringMeaningState { candidate, unknown, failed, pending }

/// 2026-11-04: 서버 검증을 통과한 의미 결과 또는 명시 실행 상태다. 금액·일정 필드는 없다.
class RecurringMeaning {
  /// 2026-11-04: 현재 응답 문맥·후보 키·근거를 보존한다. provenance를 현재 문맥으로 쓰지 않는다.
  RecurringMeaning({
    required this.context,
    required this.candidateKey,
    required this.state,
    required Iterable<String> evidenceIds,
    this.name,
    this.value,
    this.reason,
    this.reasonCode,
  }) : evidenceIds = List.unmodifiable(evidenceIds);

  final CalculationContext context;
  final String candidateKey;
  final RecurringMeaningState state;
  final List<String> evidenceIds;
  final String? name;
  final String? value;
  final String? reason;
  final String? reasonCode;
}

/// 2026-11-04: 예상 지출을 확정하기 전에 필요한 사용자 확인이다.
enum RecurringReviewReason {
  userConfirmation,
  amountVaries,
  scheduleUnknown,
  cardBillDate,
  elapsedDate,
  meaningUnknown,
  analysisFailed,
  analysisPending,
}

/// 2026-11-04: 원천 금액/일정과 AI 설명을 분리한 화면 후보. 의무나 U 입력으로 자동 변환하지 않는다.
class RecurringSuggestion {
  /// 2026-11-04: 로컬 후보·의미 상태·이번 달 확인 사항을 불변으로 묶는다.
  RecurringSuggestion(
    this.candidate,
    this.meaning,
    this.thisMonthDate,
    this.alreadyObservedThisMonth,
    Iterable<RecurringReviewReason> reviews,
  ) : reviews = List.unmodifiable(reviews);

  final RecurringCandidate candidate;
  final RecurringMeaning? meaning;
  final BusinessDate? thisMonthDate;
  final bool alreadyObservedThisMonth;
  final List<RecurringReviewReason> reviews;

  /// 2026-11-04: 현재 달의 아직 관측되지 않은 계좌 출금 후보인지 나타낸다. 출금 보증은 아니다.
  bool get isThisMonthCashCandidate =>
      candidate.kind == RecurringEntryKind.accountOutflow &&
      thisMonthDate != null &&
      !alreadyObservedThisMonth &&
      !reviews.contains(RecurringReviewReason.elapsedDate);

  /// 2026-11-04: 일정·금액이 일정하고 AI 의미도 확인된 우선 제안. 사용자 승인은 별도로 필요하다.
  bool get isThisMonthRecommendation =>
      isThisMonthCashCandidate &&
      !candidate.amountVaries &&
      meaning?.state == RecurringMeaningState.candidate;
}

/// 2026-11-04: 최신 로컬 후보에 같은 문맥의 AI 해석만 결합한다. 모든 후보는 사용자 확인 대상이다.
/// 카드 구매일·과거 날짜를 현금 예정 출금으로 바꾸지 않고 실패를 정상 0개로 숨기지 않는다.
List<RecurringSuggestion> reviewRecurring(
  RecurringDetection detection,
  Iterable<RecurringMeaning> meanings,
) {
  final byKey = <String, RecurringMeaning>{};
  final allowed = detection.candidates
      .map((candidate) => candidate.key)
      .toSet();
  for (final meaning in meanings) {
    final context = detection.context;
    final current = meaning.context;
    if (!allowed.contains(meaning.candidateKey) ||
        byKey.containsKey(meaning.candidateKey) ||
        current.dataVersion != context.dataVersion ||
        current.sourceVersion != context.sourceVersion ||
        current.ruleVersion != context.ruleVersion ||
        current.asOf != context.asOf ||
        current.inputRevision != context.inputRevision) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'recurring.meanings',
        '다른 후보·중복·구문맥 응답',
      );
    }
    final decisionValid = switch (meaning.state) {
      RecurringMeaningState.candidate =>
        meaning.value != null &&
            meaning.value!.trim().isNotEmpty &&
            meaning.reasonCode == 'supported',
      RecurringMeaningState.unknown =>
        meaning.value == null &&
            const {
              'insufficient_evidence',
              'conflicting_evidence',
              'outside_taxonomy',
            }.contains(meaning.reasonCode),
      RecurringMeaningState.failed || RecurringMeaningState.pending => true,
    };
    if (!decisionValid) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'recurring.meaning',
        '의미 상태·값·사유 불일치',
      );
    }
    byKey[meaning.candidateKey] = meaning;
  }
  final today = detection.context.businessDate;
  final result = <RecurringSuggestion>[];
  for (final candidate in detection.candidates) {
    final meaning = byKey[candidate.key];
    if (meaning != null &&
        (meaning.state == RecurringMeaningState.candidate ||
            meaning.state == RecurringMeaningState.unknown)) {
      final refs = meaning.evidenceIds.toSet();
      if (refs.length != meaning.evidenceIds.length ||
          refs.length != candidate.evidence.length ||
          !refs.containsAll(candidate.evidenceIds)) {
        throw CalculationInputException(
          InputErrorCode.invalidValue,
          'recurring.evidence',
          '누락·다른 후보·중복 근거',
        );
      }
    }
    final reviews = <RecurringReviewReason>[
      RecurringReviewReason.userConfirmation,
    ];
    if (candidate.amountVaries) reviews.add(RecurringReviewReason.amountVaries);
    final day = candidate.suggestedDay;
    BusinessDate? date;
    if (day == null) {
      reviews.add(RecurringReviewReason.scheduleUnknown);
    } else {
      date = BusinessDate.monthly(today.year, today.month, day).date;
      if (date.isBefore(today)) reviews.add(RecurringReviewReason.elapsedDate);
    }
    if (candidate.kind == RecurringEntryKind.cardPurchase) {
      reviews.add(RecurringReviewReason.cardBillDate);
      date = null;
    }
    switch (meaning?.state) {
      case RecurringMeaningState.candidate:
        break;
      case RecurringMeaningState.unknown:
        reviews.add(RecurringReviewReason.meaningUnknown);
      case RecurringMeaningState.failed:
        reviews.add(RecurringReviewReason.analysisFailed);
      case RecurringMeaningState.pending || null:
        reviews.add(RecurringReviewReason.analysisPending);
    }
    final observed = candidate.evidence.any(
      (row) => row.date!.year == today.year && row.date!.month == today.month,
    );
    result.add(
      RecurringSuggestion(candidate, meaning, date, observed, reviews),
    );
  }
  result.sort((a, b) {
    if (a.isThisMonthRecommendation != b.isThisMonthRecommendation) {
      return a.isThisMonthRecommendation ? -1 : 1;
    }
    if (a.isThisMonthCashCandidate != b.isThisMonthCashCandidate) {
      return a.isThisMonthCashCandidate ? -1 : 1;
    }
    if (a.thisMonthDate != null && b.thisMonthDate != null) {
      final order = a.thisMonthDate!.compareTo(b.thisMonthDate!);
      if (order != 0) return order;
    }
    return a.candidate.key.compareTo(b.candidate.key);
  });
  return List.unmodifiable(result);
}
