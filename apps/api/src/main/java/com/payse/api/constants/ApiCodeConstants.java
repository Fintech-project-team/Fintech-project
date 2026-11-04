package com.payse.api.constants;

/**
 * 공개 오류 코드와 업무 상태 값를 기능별 구간에서 관리한다.
 * @created 2026-11-02
 * @usedBy AllocationWrites, AnalysisController, AnalysisEvidence, AnalysisIdentity
 */
public final class ApiCodeConstants {
    /**
     * 비공개 AI 준비와 상태의 고정 규격이다.
     * @created 2026-11-04
     * @usedBy AnalysisReadiness, AnalysisRuntime, GammaDeployment
     */
    public static final class Readiness {
        public static final String DIRECT = "direct";
        public static final String READY = "READY";
        public static final String DIRECT_BUNDLED = "DIRECT_BUNDLED";
        public static final String PROVIDER_SUCCESS = "providerSuccess";
        public static final String PROVIDER_FAILURE = "providerFailure";
        public static final String ANALYSIS_VALIDATED = "analysisValidated";
        public static final String ANALYSIS_FAILURE = "analysisFailure";

        /**
         * 정적 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-04
         * @usedBy 없음: 정적 상수 전용
         */
        private Readiness() {
        }
    }

    /**
     * 분석 실행 구성·비용 경계의 고정 문자열이다.
     * @created 2026-11-03
     * @usedBy AnalysisSettings, AnalysisPricing, AnalysisCosts, AnalysisConfiguration
     */
    public static final class Execution {
        public static final String MODEL = "model";
        public static final String COUNTING = "counting";
        public static final String KMS = "kms";

        /**
         * 정적 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-03
         * @usedBy 없음: 정적 상수 전용
         */
        private Execution() {
        }
    }

    /**
     * 상수 컨테이너의 인스턴스 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private ApiCodeConstants() {
    }

    // 분석
    /**
     * 분석 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisController, AnalysisEvidence, AnalysisIdentity, AnalysisJobs
     */
    public static final class Analysis {
        // 오류 코드
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";
        public static final String INVALID_JSON = "INVALID_JSON";
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String INVALID_KMS_INPUT = "INVALID_KMS_INPUT";
        public static final String INVALID_KMS_RESPONSE = "INVALID_KMS_RESPONSE";
        public static final String RULE_VERSION_MISMATCH = "RULE_VERSION_MISMATCH";
        public static final String STALE_DATA = "STALE_DATA";
        public static final String RESOURCE_FORBIDDEN = "RESOURCE_FORBIDDEN";
        public static final String RATE_LIMITED = "RATE_LIMITED";
        public static final String DISPATCH_NOT_STARTED = "DISPATCH_NOT_STARTED";
        public static final String RESULT_NOT_STORED = "RESULT_NOT_STORED";
        public static final String EXECUTION_UNCONFIRMED = "EXECUTION_UNCONFIRMED";
        public static final String SESSION_INVALID = "SESSION_INVALID";
        public static final String RELATION_CONFLICT = "RELATION_CONFLICT";

        // 업무·프로토콜 값
        public static final String UNAVAILABLE = "unavailable";
        public static final String NOT_CONNECTED = "not_connected";
        public static final String OUTSIDE_RETENTION = "outside_retention";
        public static final String NOT_PROVIDED = "not_provided";
        public static final String ACCOUNT_ENTRY = "account_entry";
        public static final String TRANSACTION_MEANING = "transactionMeaning";
        public static final String TRIGGER_A = "A";
        public static final String TRIGGER_B = "B";
        public static final String RECOVERY = "recovery";
        public static final String INTAKE = "intake";
        public static final String AVAILABLE = "available";
        public static final String QUEUED = "queued";
        public static final String SUCCEEDED = "succeeded";
        public static final String RETRY = "retry";
        public static final String INPUT_OPERATION = "input";
        public static final String RUNNING = "running";
        public static final String CANCELLED = "cancelled";
        public static final String FAILED = "failed";
        public static final String OUTCOME_UNKNOWN = "outcomeUnknown";
        public static final String AWAITING_INPUT = "awaitingInput";
        public static final String WAIT = "wait";
        public static final String NOT_SENT = "notSent";
        public static final String SENT = "sent";
        public static final String SETTLED = "settled";
        public static final String DELETE = "delete";
        public static final String RECURRING_MEANING = "recurringMeaning";
        public static final String READ_RESULT = "readResult";
        public static final String EXPIRED = "expired";
        public static final String REFRESH_INPUT = "refreshInput";
        public static final String UNCHECKED = "unchecked";
        public static final String SUBMIT_INPUT = "submitInput";
        public static final String AI = "ai";
        public static final String MISSING = "missing";
        public static final String PARTIAL = "partial";
        public static final String DELETED = "deleted";
        public static final String INACTIVE = "inactive";
        public static final String STALE = "stale";
        public static final String DISABLED = "disabled";

        // 기간 조회·기억 관리
        public static final String RESTRICTED = "restricted";
        public static final String UNVERIFIED = "unverified";

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
     * @usedBy AuthController, AuthHttpResponse
     */
    public static final class Auth {
        // 오류 코드
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";
        public static final String INVALID_JSON_CODE = "INVALID_JSON";
        public static final String REQUEST_TOO_LARGE_CODE = "REQUEST_TOO_LARGE";
        public static final String AUTH_REJECTED_CODE = "AUTH_REJECTED";
        public static final String SESSION_INVALID_CODE = "SESSION_INVALID";
        public static final String RATE_LIMITED_CODE = "RATE_LIMITED";

        /**
         * 인증 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Auth() {
        }
    }

    // 금융
    /**
     * 금융 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AllocationWrites, FinancialController, FinancialCursor, FinancialHttpInput
     */
    public static final class Finance {
        // 오류 코드
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";
        public static final String INVALID_JSON = "INVALID_JSON";
        public static final String INVALID_CURSOR = "INVALID_CURSOR";
        public static final String REQUEST_TOO_LARGE = "REQUEST_TOO_LARGE";
        public static final String LIMIT_EXCEEDED = "LIMIT_EXCEEDED";
        public static final String IDEMPOTENCY_CONFLICT = "IDEMPOTENCY_CONFLICT";
        public static final String RESOURCE_FORBIDDEN = "RESOURCE_FORBIDDEN";
        public static final String RELATION_CONFLICT = "RELATION_CONFLICT";
        public static final String HISTORY_LOCKED = "HISTORY_LOCKED";
        public static final String STALE_DATA = "STALE_DATA";
        public static final String RULE_VERSION_MISMATCH = "RULE_VERSION_MISMATCH";
        public static final String SESSION_INVALID = "SESSION_INVALID";

        // 업무·프로토콜 값
        public static final String ACTIVE = "active";
        public static final String CANCELLED = "cancelled";
        public static final String ALLOCATION = "allocation";
        public static final String POST = "POST";
        public static final String PATCH = "PATCH";
        public static final String OBLIGATION = "obligation";
        public static final String RESERVE = "reserve";
        public static final String INSTITUTION_LINK = "institutionLink";
        public static final String ACCOUNT = "account";
        public static final String SETTINGS = "settings";
        public static final String ACCOUNT_ENTRY = "account_entry";
        public static final String BOOKING = "booking";
        public static final String CARD_PURCHASE = "card_purchase";
        public static final String PURCHASE = "purchase";
        public static final String CARD_REFUND = "card_refund";
        public static final String REFUND = "refund";
        public static final String CARD_CANCELLATION = "card_cancellation";
        public static final String CANCELLATION = "cancellation";
        public static final String TRANSACTION = "transaction";
        public static final String RESPONSE = "response";
        public static final String CARD = "card";
        public static final String STATEMENT = "statement";
        public static final String STATEMENT_ITEM = "statementItem";
        public static final String RECURRING_PLAN_REVISION = "recurringPlanRevision";
        public static final String RECURRING_PLAN = "recurringPlan";
        public static final String PLAN_REVISION = "planRevision";
        public static final String PLAN = "plan";
        public static final String UNKNOWN = "unknown";
        public static final String PARTIAL = "partial";
        public static final String CONFIRMED = "confirmed";
        public static final String IN = "in";
        public static final String POSTED = "posted";
        public static final String NOT_CONNECTED = "not_connected";

        /**
         * 금융 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Finance() {
        }
    }

    // 급여 안내
    /**
     * 급여 안내 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy SalaryMonth, SalaryNoticeController, SalaryNoticeService
     */
    public static final class Salary {
        // 오류 코드
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String SESSION_INVALID = "SESSION_INVALID";

        /**
         * 급여 안내 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Salary() {
        }
    }
}
