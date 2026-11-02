package com.payse.ai.constants;

/**
 * AI 검증과 공급자 호출의 실패 코드를 책임별로 구분한다.
 * @created 2026-11-02
 * @usedBy AnalysisContract, AnalysisService, InputMapper, ModelFailure, ModelReply, OpenAiGateway,
 * ProviderHttp, SchemaRules, StorageContract
 */
public final class AiCodeConstants {
    /**
     * 값 참조 전용 클래스의 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private AiCodeConstants() {
    }

    // 분석 업무
    /**
     * 분석 업무에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisContract, InputMapper, SchemaRules
     */
    public static final class Analysis {
        public static final String INVALID_INPUT = "INVALID_INPUT";
        public static final String UNKNOWN_RESPONSE_ID = "UNKNOWN_RESPONSE_ID";
        public static final String INVALID_CONTEXT = "INVALID_CONTEXT";
        public static final String CONFLICTING_AVAILABILITY = "CONFLICTING_AVAILABILITY";
        public static final String CLASSIFICATION_OUTSIDE_EVIDENCE =
            "CLASSIFICATION_OUTSIDE_EVIDENCE";
        public static final String UNSUPPORTED_ACCOUNT_STATUS = "UNSUPPORTED_ACCOUNT_STATUS";
        public static final String UNRESOLVED_ORIGINAL = "UNRESOLVED_ORIGINAL";
        public static final String CYCLIC_ORIGINAL = "CYCLIC_ORIGINAL";
        public static final String DUPLICATE_RELATION = "DUPLICATE_RELATION";
        public static final String RELATION_OUTSIDE_EVIDENCE = "RELATION_OUTSIDE_EVIDENCE";
        public static final String INVALID_TRANSFER = "INVALID_TRANSFER";
        public static final String INVALID_CARD_PAIR = "INVALID_CARD_PAIR";
        public static final String ITEM_OUTSIDE_EVIDENCE = "ITEM_OUTSIDE_EVIDENCE";
        public static final String TARGET_MISMATCH = "TARGET_MISMATCH";
        public static final String CANDIDATE_MISMATCH = "CANDIDATE_MISMATCH";
        public static final String CANDIDATE_EVIDENCE_MISMATCH = "CANDIDATE_EVIDENCE_MISMATCH";
        public static final String CANDIDATE_VERSION_MISMATCH = "CANDIDATE_VERSION_MISMATCH";
        public static final String LOCAL_CANDIDATE_NOT_READY = "LOCAL_CANDIDATE_NOT_READY";
        public static final String DUPLICATE_TARGET = "DUPLICATE_TARGET";
        public static final String UNUSED_CANDIDATE = "UNUSED_CANDIDATE";
        public static final String UNUSED_EVIDENCE = "UNUSED_EVIDENCE";
        public static final String UNUSED_UNAVAILABLE_REFERENCE = "UNUSED_UNAVAILABLE_REFERENCE";
        public static final String INCOMPLETE_ITEMS = "INCOMPLETE_ITEMS";
        public static final String OUTPUT_OUTSIDE_ITEMS = "OUTPUT_OUTSIDE_ITEMS";
        public static final String OUTPUT_OUTSIDE_EVIDENCE = "OUTPUT_OUTSIDE_EVIDENCE";
        public static final String INVENTED_CANDIDATE = "INVENTED_CANDIDATE";
        public static final String EXISTING_CLASSIFICATION_CONFLICT =
            "EXISTING_CLASSIFICATION_CONFLICT";
        public static final String MISSING_BILL_SETTLEMENT_EVIDENCE =
            "MISSING_BILL_SETTLEMENT_EVIDENCE";
        public static final String MISSING_TRANSFER_EVIDENCE = "MISSING_TRANSFER_EVIDENCE";
        public static final String DECISION_MISMATCH = "DECISION_MISMATCH";
        public static final String UNKNOWN_TASK = "UNKNOWN_TASK";
        public static final String DUPLICATE_ID = "DUPLICATE_ID";
        public static final String DUPLICATE_REFERENCE = "DUPLICATE_REFERENCE";
        public static final String UNSUPPORTED_SCHEMA = "UNSUPPORTED_SCHEMA";
        public static final String UNSUPPORTED_TYPE = "UNSUPPORTED_TYPE";
        public static final String MISSING_VALUE = "MISSING_VALUE";
        public static final String INVALID_TYPE = "INVALID_TYPE";
        public static final String INVALID_ENUM = "INVALID_ENUM";
        public static final String MISSING_FIELD = "MISSING_FIELD";
        public static final String UNEXPECTED_FIELD = "UNEXPECTED_FIELD";
        public static final String DUPLICATE_VALUE = "DUPLICATE_VALUE";
        public static final String INVALID_PATTERN = "INVALID_PATTERN";
        public static final String BELOW_MINIMUM = "BELOW_MINIMUM";
        public static final String ABOVE_MAXIMUM = "ABOVE_MAXIMUM";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Analysis() {
        }
    }

    // 기억 보존·참조
    /**
     * 기억 보존·참조에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy StorageContract
     */
    public static final class Memory {
        public static final String EMPTY_ITEMS = "EMPTY_ITEMS";
        public static final String MEMORY_ITEM_MISMATCH = "MEMORY_ITEM_MISMATCH";
        public static final String INVALID_RETENTION_FLAGS = "INVALID_RETENTION_FLAGS";
        public static final String EMPTY_MEMORY_REASON = "EMPTY_MEMORY_REASON";
        public static final String INCOMPLETE_MEMORIES = "INCOMPLETE_MEMORIES";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Memory() {
        }
    }

    // 공급자 공통
    /**
     * 공급자 공통에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisService, ModelFailure, ModelReply, OpenAiGateway, ProviderHttp
     */
    public static final class Provider {
        public static final String INVALID_MODEL_OUTPUT = "INVALID_MODEL_OUTPUT";
        public static final String INVALID_TOKEN_COUNT = "INVALID_TOKEN_COUNT";
        public static final String INPUT_TOKEN_LIMIT = "INPUT_TOKEN_LIMIT";
        public static final String INVALID_PROVIDER_RESPONSE = "INVALID_PROVIDER_RESPONSE";
        public static final String MODEL_REFUSAL = "MODEL_REFUSAL";
        public static final String INCOMPLETE_RESPONSE = "INCOMPLETE_RESPONSE";
        public static final String CREDENTIAL_UNAVAILABLE = "CREDENTIAL_UNAVAILABLE";
        public static final String INPUT_TOKENS_UNAVAILABLE = "INPUT_TOKENS_UNAVAILABLE";
        public static final String INVALID_PROVIDER_JSON = "INVALID_PROVIDER_JSON";
        public static final String TRANSMISSION_UNKNOWN = "TRANSMISSION_UNKNOWN";
        public static final String RESPONSE_TOO_LARGE = "RESPONSE_TOO_LARGE";
        public static final String HTTP_FAILURE_PATTERN = "PROVIDER_HTTP_[1-5][0-9]{2}";
        public static final String HTTP_FAILURE_PREFIX = "PROVIDER_HTTP_";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Provider() {
        }
    }
}
