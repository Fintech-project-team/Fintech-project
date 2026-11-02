package com.payse.ai.constants;

/**
 * AI 객체와 연결 구성의 고정 진단 문구를 책임별로 구분한다.
 * @created 2026-11-02
 * @usedBy AnalysisContract, AnalysisResult, AnalysisService, LlmSettings, MemoryDecision,
 * ModelFailure, ModelReply, OpenAiGateway, ProviderHttp, TokenUsage
 */
public final class AiMessageConstants {
    /**
     * 값 참조 전용 클래스의 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private AiMessageConstants() {
    }

    // 분석 업무
    /**
     * 분석 업무에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisContract, AnalysisResult, AnalysisService, MemoryDecision
     */
    public static final class Analysis {
        public static final String MODEL_PARAMETER = "model";
        public static final String MISSING_MEMORIES = "Memory decisions required";
        public static final String INCOMPLETE_ANALYSIS = "Complete analysis required";
        public static final String FAILED_ANALYSIS_RESULT = "Failed analysis has no result";
        public static final String REDACTED_RESULT = "AnalysisResult[REDACTED]";
        public static final String INVALID_MEMORY = "Valid memory decision required";
        public static final String REDACTED_MEMORY = "MemoryDecision[REDACTED]";
        public static final String MODELS_PARAMETER = "models";
        public static final String MISSING_INPUT_LIMIT = "Explicit input limit required";
        public static final String MISSING_RESOURCE = "AI public resource missing";
        public static final String UNAVAILABLE_RESOURCE = "AI public resource unavailable";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Analysis() {
        }
    }

    // 공급자 공통
    /**
     * 공급자 공통에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy ModelFailure, ModelReply, TokenUsage
     */
    public static final class Provider {
        public static final String UNKNOWN_REPLY_FAILURE = "Known model reply failure required";
        public static final String REDACTED_REPLY = "AnalysisReply[REDACTED]";
        public static final String INVALID_USAGE = "Valid token usage required";
        public static final String STAGE_PARAMETER = "stage";
        public static final String UNKNOWN_FAILURE = "Known model failure code required";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Provider() {
        }
    }

    // LLM 연결 설정
    /**
     * LLM 연결 설정에 속하는 값만 제공한다.
     * @created 2026-11-02
     * @usedBy LlmSettings
     */
    public static final class Llm {
        public static final String DISABLED_PROVIDER = "LLM provider is disabled";
        public static final String HTTP_PARAMETER = "http";
        public static final String MISSING_LIMITS = "LLM limits are required";
        public static final String REDACTED_SETTINGS = "LlmSettings[REDACTED]";
        public static final String INVALID_CONFIGURATION =
            "LLM configuration is invalid or unavailable";

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
        public static final String HTTP_PARAMETER = "http";
        public static final String CREDENTIALS_PARAMETER = "credentials";
        public static final String INVALID_PROFILE =
            "Approved analysis provider profile is required";
        public static final String ENDPOINT_PARAMETER = "endpoint";

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
        public static final String CLIENT_PARAMETER = "client";
        public static final String INVALID_HTTP_SETTINGS =
            "Bounded provider HTTP settings are required";

        /**
         * 값 참조 전용 구간의 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Http() {
        }
    }
}
