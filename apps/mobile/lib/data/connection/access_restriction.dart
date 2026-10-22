/// 2026-10-22: 부분 연결 제한 표식 규격(docs/api-response-models.md §2.1). 투영기와 화면 모델 파서가 같은 등록 표를 쓴다.
library;

/// 2026-10-22: 등록된 제한 조합('ownerType/field' → 허용 targetKind). 이 표 밖 조합은 계약 오류다.
const Map<String, Set<String>> registeredRestrictions = {
  'response/accounts': {'account'},
  'response/cards': {'card'},
  'response/statements': {'card'},
  'response/transactions': {'transaction'},
  'response/relatedTransactions': {'transaction'},
  'response/referenceResolutions': {'transaction'},
  'response/transactionRelations': {'transaction'},
  'response/coverage': {'account', 'card'},
  'response/obligations': {'account', 'plan', 'planRevision'},
  'response/reserves': {'account'},
  'response/allocations': {'reserve', 'obligation'},
  'response/settlements': {'obligation', 'transaction'},
  'response/recurringPlans': {'account'},
  'response/recurringPlanRevisions': {'plan', 'account'},
  'response/occurrenceOverrides': {'plan', 'planRevision', 'account'},
  'response/recurringDecisions': {'plan', 'transaction'},
  'response/occurrenceLinks': {
    'plan',
    'transaction',
    'statement',
    'obligation',
  },
  'settings/salary.salaryAccountId': {'account'},
  'settings/salary.receiptEvidence': {'account', 'transaction'},
  'settings/cardPlans': {'card'},
  'card/withdrawalAccountId': {'account'},
  'transaction/accountId': {'account'},
  'transaction/cardId': {'card'},
  'transaction/originalTransactionId': {'transaction'},
  'transaction/transactionRelations': {'transaction'},
  'statement/includedTransactionRefs': {'transaction'},
  'obligation/statementId': {'statement'},
  'obligation/settlements': {'transaction'},
  'allocation/releaseEvidence': {'transaction'},
  'recurringPlan/recurringPlanRevisions': {'planRevision'},
  'recurringPlanRevision/cardId': {'card'},
};

/// 2026-10-22: [ownerType]·[ownerId]·[field]·[targetKind]·[reason] 조합이 등록 표와 ownerId 규칙(response·settings는 null,
/// 그 외는 공개 자원 ID)에 맞으면 true를 반환한다.
bool isValidRestriction({
  required String ownerType,
  required String? ownerId,
  required String field,
  required String targetKind,
  required String reason,
}) {
  final allowed = registeredRestrictions['$ownerType/$field'];
  if (allowed == null || !allowed.contains(targetKind)) return false;
  if (reason != 'not_connected') return false;
  final rootOwner = ownerType == 'response' || ownerType == 'settings';
  return rootOwner ? ownerId == null : ownerId != null && ownerId.isNotEmpty;
}
