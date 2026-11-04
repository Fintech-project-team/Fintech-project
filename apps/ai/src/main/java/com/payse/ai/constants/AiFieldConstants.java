package com.payse.ai.constants;

/**
 * AI 계약의 필드 이름을 업무·스키마·공급자별로 구분한다.
 * @created 2026-11-02
 * @usedBy AnalysisContract, InputMapper, OpenAiGateway, ProviderHttp, SchemaRules, StorageContract
 */
public final class AiFieldConstants {
    /**
     * 공급자 공통 프롬프트 교육 자료의 키다. 공개 금융 응답 필드가 아니다.
     * @created 2026-11-04
     * @usedBy PromptGuide, AnalysisContract, InputMapper
     */
    public static final class Guide {
        public static final String VERSION = "version";
        public static final String RULES = "rules";
        public static final String SECTIONS = "sections";
        public static final String ID = "id";
        public static final String TASKS = "tasks";
        public static final String RECORD_KINDS = "recordKinds";
        public static final String DIRECTIONS = "directions";
        public static final String RULE = "rule";
        public static final String EXAMPLES = "examples";
        public static final String TARGET = "target";
        public static final String CANDIDATE = "candidate";
        public static final String COMMON_EVIDENCE = "commonEvidence";
        public static final String REQUIRED_EVIDENCE = "requiredEvidence";
        public static final String INSUFFICIENT_EVIDENCE = "insufficientEvidence";

        /**
         * 정적 키 구간의 생성을 막는다.
         * @created 2026-11-04
         * @usedBy 없음: 정적 상수 전용
         */
        private Guide() {
        }
    }

    /**
     * 값 참조 전용 클래스의 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private AiFieldConstants() {
    }

    // 분석 업무
    /**
     * 분석 업무에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisContract, InputMapper, StorageContract
     */
    public static final class Analysis {
        public static final String MEANINGS = "meanings";
        public static final String COLUMNS = "columns";
        public static final String ROWS = "rows";
        public static final String ACCOUNT_ID = "accountId";
        public static final String CARD_ID = "cardId";
        public static final String AMOUNT_KRW = "amountKRW";
        public static final String PURCHASE_DATE = "purchaseDate";
        public static final String WITHDRAWAL_DATE = "withdrawalDate";
        public static final String REFUND_DATE = "refundDate";
        public static final String CANCELLATION_DATE = "cancellationDate";
        public static final String BOOKING_DATE = "bookingDate";
        public static final String OCCURRED_AT = "occurredAt";
        public static final String OCCURRED_AT_BASIS = "occurredAtBasis";
        public static final String SEMANTIC_TASK_KIND = "semanticTaskKind";
        public static final String ITEMS = "items";
        public static final String TRANSACTIONS = "transactions";
        public static final String RELATIONS = "relations";
        public static final String UNAVAILABLE_REFERENCES = "unavailableReferences";
        public static final String EXISTING_CLASSIFICATIONS = "existingClassifications";
        public static final String CURRENT_CLASSIFICATIONS = "currentClassifications";
        public static final String CANDIDATES = "candidates";
        public static final String CANDIDATE_KEY = "candidateKey";
        public static final String EVIDENCE_TRANSACTION_IDS = "evidenceTransactionIds";
        public static final String NORMALIZED_NAME = "normalizedName";
        public static final String FEATURES = "features";
        public static final String OUTPUT = "output";
        public static final String MEMORIES = "memories";
        public static final String ITEM_KEY = "itemKey";
        public static final String TRANSACTION_ID = "transactionId";
        public static final String TARGET_TRANSACTION_ID = "targetTransactionId";
        public static final String ORIGINAL_TRANSACTION_ID = "originalTransactionId";
        public static final String FROM_ID = "fromId";
        public static final String TO_ID = "toId";
        public static final String CONTEXT = "context";
        public static final String DATA_VERSION = "dataVersion";
        public static final String AS_OF = "asOf";
        public static final String SELECTED_ACCOUNT_IDS = "selectedAccountIds";
        public static final String RECORD_KIND = "recordKind";
        public static final String STATUS = "status";
        public static final String KIND = "kind";
        public static final String DIRECTION = "direction";
        public static final String RULE_VERSION = "ruleVersion";
        public static final String SOURCE_VERSION = "sourceVersion";
        public static final String OCCURRENCE_COUNT = "occurrenceCount";
        public static final String OBSERVED_MONTHS = "observedMonths";
        public static final String DAY_WITHIN_RULE = "dayWithinRule";
        public static final String AMOUNT_WITHIN_RULE = "amountWithinRule";
        public static final String HAS_UNRESOLVED_REVERSAL = "hasUnresolvedReversal";
        public static final String MEANING = "meaning";
        public static final String CLASSIFICATION = "classification";
        public static final String VALUE = "value";
        public static final String REASON_CODE = "reasonCode";
        public static final String ACTIVE = "active";
        public static final String IS_REFERENCE = "isReference";
        public static final String IMPORTANT = "important";
        public static final String REFERENCE_POLICY = "referencePolicy";
        public static final String REASON = "reason";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Analysis() {
        }
    }

    // JSON Schema
    /**
     * JSON Schema에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy InputMapper, SchemaRules, StorageContract
     */
    public static final class Schema {
        public static final String TYPE_KEY = "type";
        public static final String STRING_TYPE = "string";
        public static final String ENUM = "enum";
        public static final String ARRAY_TYPE = "array";
        public static final String PROPERTIES = "properties";
        public static final String SCHEMA_URI = "$schema";
        public static final String TITLE = "title";
        public static final String DESCRIPTION = "description";
        public static final String REQUIRED_FIELDS = "required";
        public static final String ADDITIONAL_PROPERTIES = "additionalProperties";
        public static final String ITEMS = "items";
        public static final String MIN_ITEMS = "minItems";
        public static final String MAX_ITEMS = "maxItems";
        public static final String UNIQUE_ITEMS = "uniqueItems";
        public static final String MINIMUM = "minimum";
        public static final String MAXIMUM = "maximum";
        public static final String MIN_LENGTH = "minLength";
        public static final String MAX_LENGTH = "maxLength";
        public static final String PATTERN = "pattern";
        public static final String OBJECT_TYPE = "object";
        public static final String INTEGER_TYPE = "integer";
        public static final String BOOLEAN_TYPE = "boolean";
        public static final String NULL_TYPE = "null";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Schema() {
        }
    }

    // OpenAI 전용
    /**
     * OpenAI 전용에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy OpenAiGateway
     */
    public static final class OpenAi {
        public static final String OBJECT = "object";
        public static final String INPUT_TOKENS = "input_tokens";
        public static final String STORE = "store";
        public static final String BACKGROUND = "background";
        public static final String STREAM = "stream";
        public static final String MAX_OUTPUT_TOKENS = "max_output_tokens";
        public static final String USAGE_FIELD = "usage";
        public static final String STATUS = "status";
        public static final String OUTPUT = "output";
        public static final String TYPE_KEY = "type";
        public static final String ROLE = "role";
        public static final String CONTENT = "content";
        public static final String TEXT = "text";
        public static final String INPUT = "input";
        public static final String MODEL = "model";
        public static final String INSTRUCTIONS = "instructions";
        public static final String REASONING = "reasoning";
        public static final String EFFORT = "effort";
        public static final String TOOLS = "tools";
        public static final String FORMAT = "format";
        public static final String NAME = "name";
        public static final String STRICT = "strict";
        public static final String SCHEMA = "schema";
        public static final String OUTPUT_TOKENS = "output_tokens";
        public static final String INPUT_TOKENS_DETAILS = "input_tokens_details";
        public static final String CACHED_TOKENS = "cached_tokens";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private OpenAi() {
        }
    }

    // 공급자 HTTP 전송
    /**
     * 공급자 HTTP 전송에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy ProviderHttp
     */
    public static final class Http {
        public static final String AUTHORIZATION = "Authorization";
        public static final String CONTENT_TYPE = "Content-Type";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Http() {
        }
    }
}
