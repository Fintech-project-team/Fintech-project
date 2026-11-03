package com.payse.ai.constants;

/**
 * AI 업무 규격·리소스·공급자 설정 값을 책임별로 구분한다.
 * @created 2026-11-02
 * @usedBy AnalysisContract, InputMapper, LlmSettings, MemoryDecision, OpenAiGateway, ProviderHttp,
 * StorageContract
 */
public final class AiConfigConstants {
    /**
     * 값 참조 전용 클래스의 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private AiConfigConstants() {
    }

    // 분석 업무
    /**
     * 분석 업무에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisContract, InputMapper
     */
    public static final class Analysis {
        public static final String ACCOUNT_PREFIX = "a";
        public static final String CARD_PREFIX = "b";
        public static final String INPUT_SIDE = "input";
        public static final String OUTPUT_SIDE = "output";
        public static final String SCHEMA_SUFFIX = ".schema.json";
        public static final String INSTRUCTIONS_FILE = "instructions.txt";
        public static final String CRITERIA_FILE = "criteria.json";
        public static final String RULES_PATH = "/com/payse/ai/rules/";
        public static final String TRANSACTION_PREFIX = "t";
        public static final String ITEM_PREFIX = "i";
        public static final String CANDIDATE_PREFIX = "c";
        public static final String TRANSACTION_MEANING = "transactionMeaning";
        public static final String RECURRING_MEANING = "recurringMeaning";
        public static final String TIMESTAMP_PATTERN =
            "^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})(?:(?::([0-9]{2})(?::([0-9]{2}))?)|([0-9]{2})([0-9]{2})?)?(?:[.,][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$";
        public static final String UTC_MARKER = "Z";
        public static final String ACCOUNT_ENTRY = "account_entry";
        public static final String POSTED = "posted";
        public static final String UNKNOWN = "unknown";
        public static final String INTERNAL_TRANSFER = "internal_transfer";
        public static final String CARD_PURCHASE = "card_purchase";
        public static final String CARD_PAYMENT = "card_payment";
        public static final String CANDIDATE = "candidate";
        public static final String SUPPORTED = "supported";

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
     * @usedBy MemoryDecision, StorageContract
     */
    public static final class Memory {
        public static final String OPTIONAL_REFERENCE = "optional";
        public static final String REFERENCE_REQUIRED = "required";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Memory() {
        }
    }

    // LLM 연결 설정
    /**
     * LLM 연결 설정에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy LlmSettings
     */
    public static final class Llm {
        public static final String ENABLED = "enabled";
        public static final String PROVIDER = "provider";
        public static final String MODEL = "model";
        public static final String API_KEY = "apiKey";
        public static final String REASONING_EFFORT = "reasoningEffort";
        public static final String EFFORT_NONE = "none";
        public static final String EFFORT_LOW = "low";
        public static final String EFFORT_MEDIUM = "medium";
        public static final String EFFORT_HIGH = "high";
        public static final String EFFORT_XHIGH = "xhigh";
        public static final String EFFORT_MAX = "max";
        public static final String TRUE_VALUE = "true";
        public static final String FALSE_VALUE = "false";
        public static final String OPENAI = "openai";
        public static final String MODEL_PATTERN = "[A-Za-z0-9][A-Za-z0-9._:-]*";
        public static final String BEARER_PATTERN = "[-A-Za-z0-9._~+/]+=*";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Llm() {
        }
    }

    // OpenAI 전용
    /**
     * OpenAI 전용에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy OpenAiGateway
     */
    public static final class OpenAi {
        public static final String API_ENDPOINT = "https://api.openai.com/v1/";
        public static final String EFFORT_NONE = "none";
        public static final String EFFORT_LOW = "low";
        public static final String EFFORT_MEDIUM = "medium";
        public static final String EFFORT_HIGH = "high";
        public static final String EFFORT_XHIGH = "xhigh";
        public static final String EFFORT_MAX = "max";
        public static final String COUNT_PATH = "responses/input_tokens";
        public static final String COUNT_OBJECT = "response.input_tokens";
        public static final String RESPONSES_PATH = "responses";
        public static final String COMPLETED = "completed";
        public static final String MESSAGE = "message";
        public static final String ASSISTANT = "assistant";
        public static final String REFUSAL = "refusal";
        public static final String OUTPUT_TEXT = "output_text";
        public static final String JSON_SCHEMA = "json_schema";
        public static final String PAYSE_ANALYSIS = "payse_analysis";

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
        public static final String BEARER_PATTERN = "[-A-Za-z0-9._~+/]+=*";
        public static final String BEARER_PREFIX = "Bearer ";
        public static final String JSON_MEDIA_TYPE = "application/json";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Http() {
        }
    }
}
