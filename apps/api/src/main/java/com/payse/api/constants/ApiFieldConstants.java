package com.payse.api.constants;

/**
 * JSON 필드와 DB 바인딩 키를 기능별 구간에서 관리한다.
 * @created 2026-11-02
 * @usedBy AllocationWrites, AnalysisEvidence, AnalysisIdentity, AnalysisJobs
 */
public final class ApiFieldConstants {
    /**
     * 상수 컨테이너의 인스턴스 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private ApiFieldConstants() {
    }

    // 분석 DB
    /**
     * 분석 DB 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisJobs, AnalysisRepository, AnalysisResults
     */
    public static final class AnalysisDb {
        // DB 바인딩 키
        public static final String USER_ID = "user_id";
        public static final String ID = "id";
        public static final String JOB_ID = "job_id";
        public static final String GUARD_EXPIRES_AT = "guard_expires_at";
        public static final String DESCRIPTOR_HASH = "descriptor_hash";
        public static final String SEMANTIC_KIND = "semantic_kind";
        public static final String TRIGGER_KIND = "trigger_kind";
        public static final String ACCEPTED_AT = "accepted_at";
        public static final String ATTEMPT_COUNT = "attempt_count";
        public static final String EXECUTION_SESSION_ID = "execution_session_id";
        public static final String EXECUTION_EXPIRES_AT = "execution_expires_at";
        public static final String SELECTED_RESULT_ID = "selected_result_id";
        public static final String INPUT_HASH = "input_hash";
        public static final String FINISHED_AT = "finished_at";
        public static final String CANONICAL_JOB_ID = "canonical_job_id";
        public static final String PERMIT_HASH = "permit_hash";
        public static final String PERMIT_EXPIRES_AT = "permit_expires_at";
        public static final String ATTEMPT_NO = "attempt_no";
        public static final String DISPATCH_STATE = "dispatch_state";
        public static final String CREATED_AT = "created_at";
        public static final String REQUEST_KEY = "request_key";
        public static final String REQUEST_HASH = "request_hash";
        public static final String EXPIRES_AT = "expires_at";
        public static final String ATTEMPT_ID = "attempt_id";
        public static final String ITEM_ID = "item_id";
        public static final String COMMITTED_AT = "committed_at";
        public static final String ACCEPTED_MANIFEST = "accepted_manifest";
        public static final String STORED_AT = "stored_at";
        public static final String RESULT_ID = "result_id";
        public static final String ITEM_KEY = "item_key";
        public static final String MEMORY_KEY = "memory_key";
        public static final String EVIDENCE_HASH = "evidence_hash";
        public static final String NORMAL_EXPIRES_AT = "normal_expires_at";
        public static final String IS_REFERENCE = "is_reference";
        public static final String REFERENCE_POLICY = "reference_policy";
        public static final String METADATA_VERSION = "metadata_version";
        public static final String POLICY_VERSION = "policy_version";
        public static final String POLICY_ACTOR = "policy_actor";
        public static final String CRYPTO_META = "crypto_meta";
        public static final String DELETED_AT = "deleted_at";
        public static final String PURGE_REQUESTED_AT = "purge_requested_at";
        public static final String BLOCKED_AT = "blocked_at";

        // 기간 조회·기억 관리
        public static final String SOURCE_REFS = "source_refs";
        public static final String SOURCE_HASH = "source_hash";

        /**
         * 분석 DB 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisDb() {
        }
    }

    // 분석
    /**
     * 분석 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisEvidence, AnalysisIdentity, AnalysisJobs, AnalysisResults
     */
    public static final class Analysis {
        // JSON 필드
        public static final String PLAINTEXT = "plaintext";
        public static final String AUTHENTICATED_DATA = "additionalAuthenticatedData";
        public static final String NAME = "name";
        public static final String PLAINTEXT_VERIFIED = "verifiedPlaintextCrc32c";
        public static final String AAD_VERIFIED = "verifiedAdditionalAuthenticatedDataCrc32c";
        public static final String CIPHERTEXT = "ciphertext";
        public static final String CHECKSUM_SUFFIX = "Crc32c";
        public static final String USER_ID = "userId";
        public static final String CONTEXT = "context";
        public static final String SCHEMA_VERSION = "schemaVersion";
        public static final String DATA_VERSION = "dataVersion";
        public static final String SOURCE_VERSION = "sourceVersion";
        public static final String RULE_VERSION = "ruleVersion";
        public static final String AS_OF = "asOf";
        public static final String INPUT_REVISION = "inputRevision";
        public static final String LOCAL_SESSION_EPOCH = "localSessionEpoch";
        public static final String SELECTED_ACCOUNT_IDS = "selectedAccountIds";
        public static final String ITEMS = "items";
        public static final String EVIDENCE_TRANSACTION_IDS = "evidenceTransactionIds";
        public static final String TRANSACTIONS = "transactions";
        public static final String TRANSACTION_ID = "transactionId";
        public static final String UNAVAILABLE_REFERENCES = "unavailableReferences";
        public static final String CURRENT_CLASSIFICATIONS = "currentClassifications";
        public static final String ORIGINAL_TRANSACTION_ID = "originalTransactionId";
        public static final String STATUS = "status";
        public static final String REASON = "reason";
        public static final String PAYSE_TRANSACTION_TYPE = "payseTransactionType";
        public static final String VALUE = "value";
        public static final String TRANSACTION_RELATIONS = "transactionRelations";
        public static final String FROM_ID = "fromId";
        public static final String TO_ID = "toId";
        public static final String EVIDENCE_REF = "evidenceRef";
        public static final String RELATIONS = "relations";
        public static final String KIND = "kind";
        public static final String ACCOUNTS = "accounts";
        public static final String ACCOUNT_ID = "accountId";
        public static final String CARDS = "cards";
        public static final String CARD_ID = "cardId";
        public static final String RELATED_TRANSACTIONS = "relatedTransactions";
        public static final String REFERENCE_RESOLUTIONS = "referenceResolutions";
        public static final String INSTITUTION_LINKS = "institutionLinks";
        public static final String DISCONNECTED_AT = "disconnectedAt";
        public static final String INSTITUTION_CODE = "institutionCode";
        public static final String RECORD_KIND = "recordKind";
        public static final String SEMANTIC_TASK_KIND = "semanticTaskKind";
        public static final String TARGET = "target";
        public static final String TARGET_TRANSACTION_ID = "targetTransactionId";
        public static final String EVIDENCE = "evidence";
        public static final String CANDIDATES = "candidates";
        public static final String CANDIDATE_KEY = "candidateKey";
        public static final String FEATURES = "features";
        public static final String OBSERVED_MONTHS = "observedMonths";
        public static final String CANDIDATE = "candidate";
        public static final String ITEM_KEY = "itemKey";
        public static final String MEMORY_KEY = "memoryKey";
        public static final String EVIDENCE_HASH = "evidenceHash";
        public static final String INPUT = "input";
        public static final String VERSIONS = "versions";
        public static final String CONTRACT_VERSION = "contractVersion";
        public static final String MEANING_EVIDENCE = "meaningEvidence";
        public static final String SOURCE = "source";
        public static final String SOURCE_REF = "sourceRef";
        public static final String TRIGGER_KIND = "triggerKind";
        public static final String INPUT_HASH_HINT = "inputHashHint";
        public static final String REASON_CODES = "reasonCodes";
        public static final String IDEMPOTENCY_KEY = "idempotencyKey";
        public static final String PREVIOUS_JOB_ID = "previousJobId";
        public static final String STATE = "state";
        public static final String DETAIL = "detail";
        public static final String PERMIT = "permit";
        public static final String ACKNOWLEDGE_DUPLICATE_RISK = "acknowledgeDuplicateRisk";
        public static final String ACTION = "action";
        public static final String PERMIT_EXPIRES_AT = "permitExpiresAt";
        public static final String USAGE_KNOWN = "usageKnown";
        public static final String INPUT_TOKENS = "inputTokens";
        public static final String OUTPUT_TOKENS = "outputTokens";
        public static final String CACHED_TOKENS = "cachedTokens";
        public static final String RESULT_ID = "resultId";
        public static final String ITEM_ID = "itemId";
        public static final String CANDIDATE_IDS = "candidateIds";
        public static final String JOB_ID = "jobId";
        public static final String RESULT_AVAILABILITY = "resultAvailability";
        public static final String PROGRESS = "progress";
        public static final String ACCEPTED = "accepted";
        public static final String COMPLETED = "completed";
        public static final String UNRESOLVED = "unresolved";
        public static final String OPERATION = "operation";
        public static final String BODY = "body";
        public static final String RETENTION_REASON = "retentionReason";
        public static final String INTERPRETATION = "interpretation";
        public static final String ANALYSIS_INPUT_HASH = "analysisInputHash";
        public static final String PROVENANCE = "provenance";
        public static final String ACTIVE = "active";
        public static final String IMPORTANT = "important";
        public static final String KEY_REF = "keyRef";
        public static final String WRAPPED_KEY = "wrappedKey";
        public static final String NONCE = "nonce";
        public static final String RESULT = "result";
        public static final String MEANING_POLICY_VERSION = "meaningPolicyVersion";
        public static final String ITEM_AVAILABILITY = "itemAvailability";
        public static final String IS_REFERENCE = "isReference";
        public static final String REFERENCE_POLICY = "referencePolicy";
        public static final String STORED_AT = "storedAt";
        public static final String NORMAL_EXPIRES_AT = "normalExpiresAt";
        public static final String RUNTIME = "runtime";
        public static final String MODEL = "model";
        public static final String PROMPT = "prompt";
        public static final String RESPONSE = "response";
        public static final String POLICY = "policy";

        // 기간 조회·기억 관리
        public static final String PURPOSE = "purpose";
        public static final String FINANCE = "finance";
        public static final String MEMORIES = "memories";
        public static final String START_DATE = "startDate";
        public static final String END_DATE = "endDate";
        public static final String CONTENT_AVAILABILITY = "contentAvailability";
        public static final String METADATA_VERSION = "metadataVersion";
        public static final String SOURCE_CHANGED = "sourceChanged";
        public static final String PAGE_INFO = "pageInfo";
        public static final String HAS_MORE = "hasMore";

        /**
         * 분석 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Analysis() {
        }
    }

    // 인증
    /**
     * 인증 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AuthHttpInput, AuthRepository
     */
    public static final class Auth {
        // JSON 필드
        public static final String NAME = "name";
        public static final String PHONE = "phone";
        public static final String CODE = "code";
        public static final String ALLOWED = "allowed";
        public static final String ENDED = "ended";

        /**
         * 인증 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Auth() {
        }
    }

    // 인증 DB
    /**
     * 인증 DB 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AuthRepository
     */
    public static final class AuthDb {
        // DB 바인딩 키
        public static final String RETRY_AT = "retry_at";
        public static final String USER_ID = "user_id";
        public static final String CODE_VERIFIER = "code_verifier";
        public static final String SESSION_ID = "session_id";
        public static final String ISSUED_AT = "issued_at";

        /**
         * 인증 DB 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AuthDb() {
        }
    }

    // 금융
    /**
     * 금융 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AllocationWrites, FinancialCursor, FinancialHttpInput, FinancialInput
     * @modified 2026-11-02 - 원천 갱신의 기존 거래 날짜 필드를 금융 검증에서 공유
     */
    public static final class Finance {
        // JSON 필드
        public static final String EXPECTED_DATA_VERSION = "expectedDataVersion";
        public static final String RULE_VERSION = "ruleVersion";
        public static final String IDEMPOTENCY_KEY = "idempotencyKey";
        public static final String CURSOR = "cursor";
        public static final String CREATE = "create";
        public static final String OBLIGATION_ID = "obligationId";
        public static final String AMOUNT_KRW = "amountKRW";
        public static final String UPDATE = "update";
        public static final String ALLOCATION_ID = "allocationId";
        public static final String REMOVE = "remove";
        public static final String UNRELEASED_KRW = "unreleasedKRW";
        public static final String STATUS = "status";
        public static final String USER = "user";
        public static final String KEY = "key";
        public static final String RECEIPT_ID = "receiptId";
        public static final String OPERATION_KEY = "operationKey";
        public static final String RESULT_VERSION = "resultVersion";
        public static final String CREATED_AT = "createdAt";
        public static final String CHANGED_REFS = "changedRefs";
        public static final String SCHEMA_VERSION = "schemaVersion";
        public static final String CURRENCY = "currency";
        public static final String INSTITUTIONS = "institutions";
        public static final String INSTITUTION_LINKS = "institutionLinks";
        public static final String ACCOUNTS = "accounts";
        public static final String CARDS = "cards";
        public static final String TRANSACTIONS = "transactions";
        public static final String STATEMENTS = "statements";
        public static final String SETTINGS = "settings";
        public static final String RECEIPT_EVIDENCE = "receiptEvidence";
        public static final String OBLIGATIONS = "obligations";
        public static final String RESERVES = "reserves";
        public static final String ALLOCATIONS = "allocations";
        public static final String SETTLEMENTS = "settlements";
        public static final String RELATED_TRANSACTIONS = "relatedTransactions";
        public static final String REFERENCE_RESOLUTIONS = "referenceResolutions";
        public static final String TRANSACTION_RELATIONS = "transactionRelations";
        public static final String PAGE = "page";
        public static final String NEXT_CURSOR = "nextCursor";
        public static final String DATA_VERSION = "dataVersion";
        public static final String SOURCE_VERSION = "sourceVersion";
        public static final String STATEMENT_ID = "statementId";
        public static final String ITEMS = "items";
        public static final String USER_ID = "userId";
        public static final String CARD_ID = "cardId";
        public static final String TRANSACTION_ID = "transactionId";
        public static final String INCLUDED_TRANSACTION_REFS = "includedTransactionRefs";
        public static final String CARD_PLANS = "cardPlans";
        public static final String SALARY = "salary";
        public static final String RECURRING_PLANS = "recurringPlans";
        public static final String RECURRING_PLAN_REVISIONS = "recurringPlanRevisions";
        public static final String RECURRING_DECISIONS = "recurringDecisions";
        public static final String OCCURRENCE_OVERRIDES = "occurrenceOverrides";
        public static final String WITHDRAWAL_ACCOUNT_ID = "withdrawalAccountId";
        public static final String LABEL = "label";
        public static final String DUE_DATE = "dueDate";
        public static final String ACCOUNT_ID = "accountId";
        public static final String INCLUDED = "included";
        public static final String ALLOCATION_CHANGES = "allocationChanges";
        public static final String DETACH_ALLOCATIONS = "detachAllocations";
        public static final String INSTITUTION_CODES = "institutionCodes";
        public static final String CODE = "code";
        public static final String ACCOUNT_IDS = "accountIds";
        public static final String NICKNAME = "nickname";
        public static final String SALARY_ACCOUNT_ID = "salaryAccountId";
        public static final String SALARY_DAY = "salaryDay";
        public static final String SALARY_AMOUNT_KRW = "salaryAmountKRW";
        public static final String PLANNED_PAYMENT_DAY = "plannedPaymentDay";
        public static final String CHANGES = "changes";
        public static final String RESOURCE = "resource";
        public static final String BEFORE = "before";
        public static final String AFTER = "after";
        public static final String SESSION = "session";
        public static final String CONTEXT = "context";
        public static final String LAST = "last";
        public static final String SIZE = "size";
        public static final String API_SCHEMA = "apiSchema";
        public static final String AS_OF = "asOf";
        public static final String COVERAGE = "coverage";
        public static final String CONNECTIONS = "connections";
        public static final String METHOD = "method";
        public static final String PATH = "path";
        public static final String BODY = "body";
        public static final String TARGET_KIND = "targetKind";
        public static final String TARGET_ID = "targetId";
        public static final String FROM_ID = "fromId";
        public static final String TO_ID = "toId";
        public static final String OCCURRENCE_LINKS = "occurrenceLinks";
        public static final String PURCHASE_TRANSACTION_ID = "purchaseTransactionId";
        public static final String ACCESS_RESTRICTIONS = "accessRestrictions";
        public static final String RECORD_KIND = "recordKind";
        public static final String OCCURRED_AT = "occurredAt";
        public static final String OCCURRED_AT_BASIS = "occurredAtBasis";
        public static final String REQUESTED_START = "requestedStart";
        public static final String REQUESTED_END = "requestedEnd";
        public static final String COVERED_RANGES = "coveredRanges";
        public static final String START = "start";
        public static final String END = "end";
        public static final String EVIDENCE_TRANSACTION_IDS = "evidenceTransactionIds";
        public static final String TRANSACTION_IDS = "transactionIds";
        public static final String ORIGINAL_TRANSACTION_ID = "originalTransactionId";
        public static final String OWNER_TYPE = "ownerType";
        public static final String OWNER_ID = "ownerId";
        public static final String FIELD = "field";
        public static final String KIND = "kind";
        public static final String BANK = "bank";
        public static final String PLAN_ID = "planId";
        public static final String RECURRING_PLAN_ID = "recurringPlanId";
        public static final String PLAN_REVISION_ID = "planRevisionId";
        public static final String RESERVE_ID = "reserveId";
        public static final String RELEASE_EVIDENCE = "releaseEvidence";
        public static final String SETTLEMENT_LINK_ID = "settlementLinkId";
        public static final String INSTITUTION_CODE = "institutionCode";
        public static final String DISCONNECTED_AT = "disconnectedAt";
        public static final String ITEM_ID = "itemId";
        public static final String REVISION_ID = "revisionId";
        public static final String FIRST_OCCURRENCE_MONTH = "firstOccurrenceMonth";
        public static final String EVIDENCE_REF = "evidenceRef";
        public static final String RECURRENCE_KEY = "recurrenceKey";
        public static final String PAY_MONTH = "payMonth";
        public static final String EXPECTED_PAY_DATE = "expectedPayDate";
        public static final String CONFIRMATION = "confirmation";
        public static final String DIRECTION = "direction";
        public static final String BALANCE_REFLECTED = "balanceReflected";
        public static final String SALARY_ACCOUNT_PATH = "salary.salaryAccountId";
        public static final String SALARY_EVIDENCE_PATH = "salary.receiptEvidence";
        public static final String REASON = "reason";
        public static final String REPLAYED = "replayed";
        public static final String RECEIPT = "receipt";
        public static final String SNAPSHOT = "snapshot";
        public static final String LINK_ID = "linkId";
        public static final String CANCELLATION_DATE = "cancellationDate";
        public static final String SETTINGS_FIELDS = "salary cardPlans";
        public static final String SALARY_FIELDS =
            "salaryDay salaryAmountKRW salaryAccountId receiptEvidence";
        public static final String RECEIPT_FIELDS =
            "payMonth expectedPayDate transactionIds confirmation";
        public static final String CARD_PLAN_FIELDS = "cardId plannedPaymentDay";
        public static final String SCHEDULE_EVIDENCE = "scheduleEvidence";
        public static final String SCHEDULE_FIELDS = "dueDate evidenceRef periodEnd periodStart";
        public static final String SCHEDULE_OVERRIDES = "scheduleOverrides";
        public static final String OVERRIDE_FIELDS = "evidenceRef occurrenceMonth plannedDate";
        public static final String RELEASE_FIELDS = "amountKRW settlementLinkId writeReceiptId";
        public static final String PERIOD_FIELDS = "end start";
        public static final String MISSING_RANGES = "missingRanges";
        public static final String EVIDENCE_REFS = "evidenceRefs";
        public static final String SOURCE_REF = "sourceRef";
        public static final String MERCHANT_NAME = "merchantName";
        public static final String PURCHASE_DATE = "purchaseDate";
        public static final String WITHDRAWAL_DATE = "withdrawalDate";
        public static final String REFUND_DATE = "refundDate";
        public static final String BOOKING_DATE = "bookingDate";
        public static final String ORIGINAL_USED_AMOUNT_KRW = "originalUsedAmountKRW";
        public static final String BILLED_PRINCIPAL_KRW = "billedPrincipalKRW";
        public static final String FEE_OR_ADJUSTMENT_AMOUNT_KRW = "feeOrAdjustmentAmountKRW";
        public static final String BILLED_AMOUNT_KRW = "billedAmountKRW";
        public static final String INSTALLMENT_MONTHS = "installmentMonths";
        public static final String INSTALLMENT_ROUND = "installmentRound";
        public static final String ITEM_FIELDS =
            "itemId userId sourceRef sourceVersion transactionId label merchantName purchaseDate originalUsedAmountKRW billedPrincipalKRW feeOrAdjustmentAmountKRW billedAmountKRW installmentMonths installmentRound";
        public static final String TRANSACTION_FIELDS =
            "accountId amountKRW balanceReflected bookingDate cancellationDate cardId description direction installmentCurrent installmentTotal merchantName occurredAt occurredAtBasis originalTransactionId payseTransactionType purchaseDate recordKind reflectionReason refundDate sourceRef sourceVersion status transactionId userId withdrawalDate";

        // 기간 조회·기억 관리
        public static final String PURPOSE = "purpose";
        public static final String SOURCE_CONTEXT = "sourceContext";
        public static final String START_DATE = "startDate";
        public static final String END_DATE = "endDate";

        /**
         * 금융 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Finance() {
        }
    }

    // 금융 DB
    /**
     * 금융 DB 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AllocationWrites, FinancialService, PlanWrites, SettingsWrites
     */
    public static final class FinanceDb {
        // DB 바인딩 키
        public static final String RESERVE_ID = "reserve_id";
        public static final String OBLIGATION_ID = "obligation_id";
        public static final String RELEASED_KRW = "released_krw";
        public static final String RELEASE_EVIDENCE = "release_evidence";
        public static final String AMOUNT_KRW = "amount_krw";
        public static final String ID = "id";
        public static final String WITHDRAWAL_ACCOUNT_ID = "withdrawal_account_id";
        public static final String DUE_DATE = "due_date";
        public static final String STATEMENT_ID = "statement_id";
        public static final String CANCELLED_AT = "cancelled_at";
        public static final String ACCOUNT_ID = "account_id";
        public static final String BALANCE_KRW = "balance_krw";
        public static final String HAS_ACCOUNTS = "has_accounts";
        public static final String INSTITUTION_CODE = "institution_code";
        public static final String SALARY_DAY = "salary_day";
        public static final String SALARY_AMOUNT_KRW = "salary_amount_krw";
        public static final String SALARY_ACCOUNT_ID = "salary_account_id";
        public static final String CARD_PLAN_OVERRIDES = "card_plan_overrides";
        public static final String ORIGINAL_ID = "original_id";
        public static final String ORIGINAL_AMOUNT_KRW = "original_amount_krw";
        public static final String ORIGINAL_CARD_ID = "original_card_id";
        public static final String ORIGINAL_KIND = "original_kind";
        public static final String ORIGINAL_PURCHASE_DATE = "original_purchase_date";
        public static final String ORIGINAL_SOURCE_VERSION = "original_source_version";
        public static final String CANCELLATION_DATE = "cancellation_date";
        public static final String ORIGINAL_TRANSACTION_ID = "original_transaction_id";
        public static final String ORIGINAL_STATE = "original_state";
        public static final String PLAN_REVISION_ID = "plan_revision_id";

        /**
         * 금융 DB 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private FinanceDb() {
        }
    }
}
