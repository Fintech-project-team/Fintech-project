package com.payse.ai;

/**
 * 테스트 기대값을 운영 상수에서 가져오지 않고 목적별 리터럴로 정의한다.
 * @created 2026-11-02
 * @usedBy AI 분석·설정·공급자·HTTP 테스트
 */
public final class AiTestConstants {
    /**
     * 테스트 값 참조 전용 클래스의 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private AiTestConstants() {
    }

    // 분석 입력·출력 필드 기대값
    /**
     * 분석 입력·출력 필드 기대값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisServiceTest, AnalysisStorageTest, AnalysisSubsetTest, ContractParityTest,
     * OpenAiGatewayTest
     */
    public static final class AnalysisFields {
        public static final String EXPECTED_BASIC_TYPE = "expectedBasicType";
        public static final String EXPECTED_MEANING = "expectedMeaning";
        public static final String COUNTEREXAMPLE = "counterexample";
        public static final String LABEL_ORIGIN = "labelOrigin";
        public static final String CONTEXT = "context";
        public static final String TRANSACTIONS = "transactions";
        public static final String TRANSACTION_ID = "transactionId";
        public static final String EXPECTED = "expected";
        public static final String ITEMS = "items";
        public static final String ITEM_KEY = "itemKey";
        public static final String EVIDENCE_TRANSACTION_IDS = "evidenceTransactionIds";
        public static final String CLASSIFICATION = "classification";
        public static final String STATUS = "status";
        public static final String VALUE = "value";
        public static final String REASON_CODE = "reasonCode";
        public static final String MEANING = "meaning";
        public static final String TARGET_TRANSACTION_ID = "targetTransactionId";
        public static final String MEANING_POLICY_VERSION = "meaningPolicyVersion";
        public static final String REASON = "reason";
        public static final String OUTPUT = "output";
        public static final String MEMORIES = "memories";
        public static final String IMPORTANT = "important";
        public static final String ACTIVE = "active";
        public static final String IS_REFERENCE = "isReference";
        public static final String REFERENCE_POLICY = "referencePolicy";
        public static final String CANDIDATE_KEY = "candidateKey";
        public static final String SUGGESTED_AMOUNT_KRW = "suggestedAmountKRW";
        public static final String INPUT = "input";
        public static final String SEMANTIC_TASK_KIND = "semanticTaskKind";
        public static final String NAME = "name";
        public static final String CURRENT_CLASSIFICATIONS = "currentClassifications";
        public static final String DIRECTION = "direction";
        public static final String RELATIONS = "relations";
        public static final String KIND = "kind";
        public static final String FROM_ID = "fromId";
        public static final String TO_ID = "toId";
        public static final String CANDIDATES = "candidates";
        public static final String NORMALIZED_NAME = "normalizedName";
        public static final String SUGGESTED_DAY = "suggestedDay";
        public static final String RULE_VERSION = "ruleVersion";
        public static final String SOURCE_VERSION = "sourceVersion";
        public static final String FEATURES = "features";
        public static final String OCCURRENCE_COUNT = "occurrenceCount";
        public static final String DAY_WITHIN_RULE = "dayWithinRule";
        public static final String AMOUNT_WITHIN_RULE = "amountWithinRule";
        public static final String HAS_UNRESOLVED_REVERSAL = "hasUnresolvedReversal";
        public static final String OBSERVED_MONTHS = "observedMonths";
        public static final String PROJECTED = "projected";
        public static final String CASE_ID = "caseId";
        public static final String SCHEMA = "schema";
        public static final String RESPONSE = "response";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisFields() {
        }
    }

    // 분석 업무·기억 정책 기대값
    /**
     * 분석 업무·기억 정책 기대값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisServiceTest, AnalysisStorageTest, AnalysisSubsetTest
     */
    public static final class AnalysisValues {
        public static final String MEANING_VERSION = "PAYSE-MEANING-1";
        public static final String CANDIDATE = "candidate";
        public static final String CARD_PAYMENT = "card_payment";
        public static final String SUPPORTED = "supported";
        public static final String SALARY = "salary";
        public static final String UNKNOWN = "unknown";
        public static final String MEMORY_VERSION = "PAYSE-MEMORY-1";
        public static final String REFERENCE_REQUIRED = "required";
        public static final String REDACTED_RESULT = "AnalysisResult[REDACTED]";
        public static final String REDACTED_MEMORY = "MemoryDecision[REDACTED]";
        public static final String OPTIONAL_REFERENCE = "optional";
        public static final String RECURRING_MEANING = "recurringMeaning";
        public static final String INCOME = "income";
        public static final String EXPENSE = "expense";
        public static final String OUT = "out";
        public static final String INTERNAL_TRANSFER = "internal_transfer";
        public static final String TRANSACTION_MEANING = "transactionMeaning";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisValues() {
        }
    }

    // JSON Schema 기대값
    /**
     * JSON Schema 기대값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisStorageTest, LlmSettingsTest, OpenAiGatewayTest
     */
    public static final class Schema {
        public static final String PROPERTIES = "properties";
        public static final String TYPE_KEY = "type";
        public static final String OBJECT_TYPE = "object";
        public static final String ADDITIONAL_PROPERTIES = "additionalProperties";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Schema() {
        }
    }

    // 분석 검증 자료 경로
    /**
     * 분석 검증 자료 경로을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisServiceTest, AnalysisStorageTest, AnalysisSubsetTest, ContractParityTest,
     * OpenAiGatewayTest
     */
    public static final class Files {
        public static final String TEST_DATA_PROPERTY = "payse.testData";
        public static final String INPUT_FILE = "service-input.json";
        public static final String PARITY_FILE = "parity.jsonl";
        public static final String INVALID_INPUTS_FILE = "invalid-inputs.json";
        public static final String DATE_INPUTS_FILE = "date-inputs.json";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Files() {
        }
    }

    // 공급자 실패 코드 기대값
    /**
     * 공급자 실패 코드 기대값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisServiceTest, AnalysisStorageTest, ModelContractTest, OpenAiGatewayTest,
     * ProviderHttpTest
     */
    public static final class ProviderCodes {
        public static final String INPUT_TOKENS_UNAVAILABLE = "INPUT_TOKENS_UNAVAILABLE";
        public static final String INVALID_TOKEN_COUNT = "INVALID_TOKEN_COUNT";
        public static final String INVALID_MODEL_OUTPUT = "INVALID_MODEL_OUTPUT";
        public static final String MODEL_REFUSAL = "MODEL_REFUSAL";
        public static final String TRANSMISSION_UNKNOWN = "TRANSMISSION_UNKNOWN";
        public static final String INCOMPLETE_RESPONSE = "INCOMPLETE_RESPONSE";
        public static final String INVALID_PROVIDER_RESPONSE = "INVALID_PROVIDER_RESPONSE";
        public static final String INPUT_TOKEN_LIMIT = "INPUT_TOKEN_LIMIT";
        public static final String CREDENTIAL_UNAVAILABLE = "CREDENTIAL_UNAVAILABLE";
        public static final String PROVIDER_HTTP_503 = "PROVIDER_HTTP_503";
        public static final String HTTP_FAILURE_PREFIX = "PROVIDER_HTTP_";
        public static final String INVALID_PROVIDER_JSON = "INVALID_PROVIDER_JSON";
        public static final String RESPONSE_TOO_LARGE = "RESPONSE_TOO_LARGE";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private ProviderCodes() {
        }
    }

    // 공급자 테스트 대역과 진단 기대값
    /**
     * 공급자 테스트 대역과 진단 기대값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisServiceTest, OpenAiGatewayTest, ProviderHttpTest, ProviderStub
     */
    public static final class ProviderValues {
        public static final String REDACTED_REPLY = "AnalysisReply[REDACTED]";
        public static final String LOOPBACK_HOST = "127.0.0.1";
        public static final String ROOT_PATH = "/";
        public static final String LOOPBACK_PREFIX = "http://127.0.0.1:";
        public static final String API_PATH = "/v1/";
        public static final String AUTHORIZATION = "Authorization";
        public static final String LOCATION = "Location";
        public static final String REDIRECT_PATH = "redirected";
        public static final String INPUT = "input";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private ProviderValues() {
        }
    }

    // LLM 설정 기대값
    /**
     * LLM 설정 기대값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy LlmSettingsTest
     */
    public static final class Llm {
        public static final String CONFIG_DIRECTORY = "config";
        public static final String EXAMPLE_FILE = "llm.properties.example";
        public static final String PROVIDER = "provider";
        public static final String MODEL = "model";
        public static final String API_KEY = "apiKey";
        public static final String REASONING_EFFORT = "reasoningEffort";
        public static final String REDACTED_SETTINGS = "LlmSettings[REDACTED]";
        public static final String INVALID_CONFIGURATION =
            "LLM configuration is invalid or unavailable";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Llm() {
        }
    }

    // OpenAI 요청·응답 필드 기대값
    /**
     * OpenAI 요청·응답 필드 기대값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy OpenAiGatewayTest
     */
    public static final class OpenAiFields {
        public static final String INSTRUCTIONS = "instructions";
        public static final String TEXT = "text";
        public static final String FORMAT = "format";
        public static final String SCHEMA = "schema";
        public static final String INPUT = "input";
        public static final String OUTPUT = "output";
        public static final String STATUS = "status";
        public static final String MODEL = "model";
        public static final String REASONING = "reasoning";
        public static final String TOOLS = "tools";
        public static final String EFFORT = "effort";
        public static final String TYPE_KEY = "type";
        public static final String STRICT = "strict";
        public static final String STORE = "store";
        public static final String BACKGROUND = "background";
        public static final String STREAM = "stream";
        public static final String MAX_OUTPUT_TOKENS = "max_output_tokens";
        public static final String USAGE_FIELD = "usage";
        public static final String ROLE = "role";
        public static final String CONTENT = "content";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private OpenAiFields() {
        }
    }

    // OpenAI 프로토콜과 합성 사례값
    /**
     * OpenAI 프로토콜과 합성 사례값을 독립적으로 제공한다.
     * @created 2026-11-02
     * @usedBy OpenAiGatewayTest
     */
    public static final class OpenAiValues {
        public static final String EFFORT_LOW = "low";
        public static final String INCOMPLETE = "incomplete";
        public static final String COUNT_PATH = "/v1/responses/input_tokens";
        public static final String RESPONSES_PATH = "/v1/responses";
        public static final String BEARER_PREFIX = "Bearer ";
        public static final String JSON_SCHEMA = "json_schema";
        public static final String COUNT_SUFFIX = "/input_tokens";
        public static final String COMPLETED = "completed";
        public static final String MESSAGE = "message";
        public static final String ASSISTANT = "assistant";
        public static final String OUTPUT_TEXT = "output_text";
        public static final String CREDENTIAL = "fixture-openai-secret";

        /**
         * 테스트 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private OpenAiValues() {
        }
    }
}
