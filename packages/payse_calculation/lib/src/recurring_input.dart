import 'business_date.dart';
import 'inputs.dart';
import 'money.dart';

/// 2026-11-04: 반복 탐지의 원천 종류. 카드 구매일은 계좌 출금일과 다르다.
enum RecurringEntryKind { accountOutflow, cardPurchase, reversal, other }

/// 2026-11-04: 확인된 원천 관계·기존 분류로 제외하는 이유다. 모델 추측을 넣지 않는다.
enum RecurringExclusion { internalTransfer, cardBillPayment, duplicate }

/// 2026-11-04: 같은 스냅샷의 실제 거래다. 날짜 미확인·미확정 상태를 보존한다.
class RecurringEntry {
  /// 2026-11-04: 원본 ID·거래 수단·명칭·실제 날짜·양의 원화와 확인 상태를 받는다.
  /// reversal의 [originalId]는 원거래 참조이며 없으면 확인 불가다.
  RecurringEntry({
    required this.id,
    required this.instrumentId,
    required this.kind,
    required this.name,
    required this.date,
    required int amountKrw,
    required this.confirmed,
    this.originalId,
    this.exclusion,
  }) : amountKrw = requireMoney(amountKrw, 'recurring.amountKrw') {
    requireId(id, 'recurring.id');
    requireId(instrumentId, 'recurring.instrumentId');
    if (originalId != null) requireId(originalId!, 'recurring.originalId');
  }

  final String id;
  final String instrumentId;
  final RecurringEntryKind kind;
  final String? name;
  final BusinessDate? date;
  final int amountKrw;
  final bool confirmed;
  final String? originalId;
  final RecurringExclusion? exclusion;
}

/// 2026-11-04: 거래 수단별 실제 조회 완료 구간. 실패·부분 구간은 complete=false다.
class RecurringCoverage {
  /// 2026-11-04: 양 끝 포함 조회 구간과 실제 완전성으로 만든다. 역전 구간은 거절한다.
  RecurringCoverage({
    required this.instrumentId,
    required this.from,
    required this.through,
    required this.complete,
  }) {
    requireId(instrumentId, 'coverage.instrumentId');
    if (from.isAfter(through)) {
      throw CalculationInputException(
        InputErrorCode.invalidValue,
        'coverage',
        '조회 구간 역전',
      );
    }
  }

  final String instrumentId;
  final BusinessDate from;
  final BusinessDate through;
  final bool complete;
}

/// 2026-11-04: 분석 전 동일 버전으로 조립된 원천과 이전 사용자 결정이다.
class RecurringInput {
  /// 2026-11-04: 연결·동의 범위 전체의 [instrumentIds]와 완료 구간을 받는다.
  /// [decidedCandidateKeys]는 승인·제외 이력으로 같은 근거의 재제안을 막는다.
  RecurringInput({
    required this.context,
    required Iterable<String> instrumentIds,
    required Iterable<RecurringEntry> entries,
    required Iterable<RecurringCoverage> coverage,
    Iterable<String> decidedCandidateKeys = const [],
  }) : instrumentIds = Set.unmodifiable(instrumentIds),
       entries = List.unmodifiable(entries),
       coverage = List.unmodifiable(coverage),
       decidedCandidateKeys = Set.unmodifiable(decidedCandidateKeys);

  final CalculationContext context;
  final Set<String> instrumentIds;
  final List<RecurringEntry> entries;
  final List<RecurringCoverage> coverage;
  final Set<String> decidedCandidateKeys;
}

/// 2026-11-04: 정상 후보 0개와 구분해야 하는 원천·월간 패턴의 미확정 이유다.
enum RecurringIssueKind {
  incompleteCoverage,
  unknownDate,
  unconfirmed,
  unknownName,
  reversal,
  multipleOccurrences,
  irregularDates,
  changedAmount,
}

/// 2026-11-04: 확인할 거래 수단·근거와 사유만 반환한다. 금융 값을 생성하지 않는다.
class RecurringIssue {
  /// 2026-11-04: 해당 문제의 사유와 원천 참조를 불변으로 보존한다.
  RecurringIssue(this.kind, this.instrumentId, Iterable<String> evidenceIds)
    : evidenceIds = List.unmodifiable(evidenceIds);

  final RecurringIssueKind kind;
  final String instrumentId;
  final List<String> evidenceIds;
}

/// 2026-11-04: 최근 3개월 수치 규칙을 통과한 로컬 후보다. 승인·확정 의무가 아니다.
class RecurringCandidate {
  /// 2026-11-04: 동일 근거 키·마지막 확인 금액·확인 가능한 월간 일자와 근거를 보존한다.
  RecurringCandidate({
    required this.key,
    required this.context,
    required this.instrumentId,
    required this.kind,
    required this.normalizedName,
    required Iterable<RecurringEntry> evidence,
    required this.suggestedAmountKrw,
    required this.suggestedDay,
    required this.amountVaries,
  }) : evidence = List.unmodifiable(evidence);

  final String key;
  final CalculationContext context;
  final String instrumentId;
  final RecurringEntryKind kind;
  final String normalizedName;
  final List<RecurringEntry> evidence;
  final int suggestedAmountKrw;
  final int? suggestedDay;
  final bool amountVaries;

  /// 2026-11-04: 실제 증거 ID만 반환한다. 응답 해석과 사용자 승인에서 재검증한다.
  List<String> get evidenceIds =>
      List.unmodifiable(evidence.map((row) => row.id));

  /// 2026-11-04: 모델 입력에 보낼 로컬 수치 규칙 결과다. 금액·날짜 자체는 별도 보존한다.
  Map<String, Object> get features => Map.unmodifiable({
    'occurrenceCount': evidence.length,
    'observedMonths': List.unmodifiable(
      evidence.map((row) => row.date!.toString().substring(0, 7)),
    ),
    'dayWithinRule': true,
    'amountWithinRule': true,
    'hasUnresolvedReversal': false,
  });
}

/// 2026-11-04: 정상 후보 목록과 원천/패턴 확인 목록을 분리한다. AI 실패 상태는 별도다.
class RecurringDetection {
  /// 2026-11-04: 계산 기준·기간과 불변 후보/확인 목록으로 탐지 결과를 만든다.
  RecurringDetection(
    this.context,
    this.startExclusive,
    Iterable<RecurringCandidate> candidates,
    Iterable<RecurringIssue> issues,
  ) : candidates = List.unmodifiable(candidates),
      issues = List.unmodifiable(issues);

  final CalculationContext context;
  final BusinessDate startExclusive;
  final List<RecurringCandidate> candidates;
  final List<RecurringIssue> issues;

  /// 2026-11-04: 자료가 충분하고 후보가 없는 경우만 정상 0개로 표시할 수 있다.
  bool get completeWithoutCandidates => candidates.isEmpty && issues.isEmpty;
}
