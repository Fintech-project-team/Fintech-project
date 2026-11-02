package com.payse.api;

/**
 * API 테스트의 계약 기대값을 목적별로 구분하고 운영 구현 상수와 독립적으로 유지한다.
 * 합성 사례값·날짜·금액·SQL 본문은 이 모음으로 옮기지 않는다.
 * @created 2026-11-02
 * @usedBy API JUnit 테스트의 요청·응답·설정·문서 검사
 */
public final class ApiTestConstants {
    /**
     * 테스트 계약만 제공하며 인스턴스 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private ApiTestConstants() {
    }

    // ---------------- 인증 ----------------

    /**
     * 버전·오류 코드를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AuthHttpTest
     */
    public static final class AuthCodes {
        public static final String AUTH_REJECTED = "AUTH_REJECTED";
        public static final String INVALID_JSON = "INVALID_JSON";
        public static final String RATE_LIMITED = "RATE_LIMITED";
        public static final String REQUEST_TOO_LARGE = "REQUEST_TOO_LARGE";
        public static final String SESSION_INVALID = "SESSION_INVALID";
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AuthCodes() {
        }
    }

    /**
     * DB 조회 결과의 컬럼·별칭 이름을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AuthJdbcTest, AuthRepositoryTest
     */
    public static final class AuthColumns {
        public static final String ALLOWED = "allowed";
        public static final String CODE_VERIFIER = "code_verifier";
        public static final String RETRY_AT = "retry_at";
        public static final String SESSION_ID = "session_id";
        public static final String USER_ID = "user_id";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AuthColumns() {
        }
    }

    /**
     * 테스트 서버 설정 키를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AuthCryptoConfigurationTest, AuthHttpInputTest, AuthHttpTest, AuthServiceTest
     */
    public static final class AuthConfig {
        public static final String BANNER_MODE = "spring.main.banner-mode";
        public static final String FORWARD_HEADERS_STRATEGY = "server.forward-headers-strategy";
        public static final String PAYSE_AUTH_CODE_KEY_BASE64 = "PAYSE_AUTH_CODE_KEY_BASE64";
        public static final String PAYSE_AUTH_CODE_KEY_ID = "PAYSE_AUTH_CODE_KEY_ID";
        public static final String PAYSE_AUTH_LIMIT_KEY_BASE64 = "PAYSE_AUTH_LIMIT_KEY_BASE64";
        public static final String PAYSE_AUTH_PEER_MODE = "PAYSE_AUTH_PEER_MODE";
        public static final String PAYSE_DB_CONNECTION_TIMEOUT_MS =
            "PAYSE_DB_CONNECTION_TIMEOUT_MS";
        public static final String PAYSE_DB_MAX_POOL_SIZE = "PAYSE_DB_MAX_POOL_SIZE";
        public static final String PAYSE_DB_PASSWORD = "PAYSE_DB_PASSWORD";
        public static final String PAYSE_DB_USER = "PAYSE_DB_USER";
        public static final String PAYSE_DB_VALIDATION_TIMEOUT_MS =
            "PAYSE_DB_VALIDATION_TIMEOUT_MS";
        public static final String PAYSE_JDBC_URL = "PAYSE_JDBC_URL";
        public static final String SERVER_ADDRESS = "server.address";
        public static final String SERVER_PORT = "server.port";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AuthConfig() {
        }
    }

    /**
     * 요청·응답 및 저장 조회 필드 이름을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AuthHttpTest
     */
    public static final class AuthFields {
        public static final String ACCESS_TOKEN = "accessToken";
        public static final String CODE = "code";
        public static final String DETAILS = "details";
        public static final String ERROR = "error";
        public static final String NAME = "name";
        public static final String PHONE = "phone";
        public static final String REQUEST_ID = "requestId";
        public static final String TOKEN_TYPE = "tokenType";
        public static final String USER_ID = "userId";
        public static final String VERIFIED = "verified";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AuthFields() {
        }
    }

    /**
     * HTTP 메서드·헤더·전송 형식을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AuthCryptoConfigurationTest, AuthHttpInputTest, AuthHttpTest, AuthServiceTest
     */
    public static final class AuthHttp {
        public static final String AUTHORIZATION = "Authorization";
        public static final String BEARER_PREFIX = "Bearer ";
        public static final String BEARER_SCHEME = "Bearer";
        public static final String CACHE_CONTROL = "Cache-Control";
        public static final String CLIENT_IP_HEADER = "X-Payse-Client-IP";
        public static final String CONTENT_ENCODING = "Content-Encoding";
        public static final String CONTENT_TYPE = "Content-Type";
        public static final String DELETE = "DELETE";
        public static final String FORWARDED = "Forwarded";
        public static final String FORWARDED_FOR = "X-Forwarded-For";
        public static final String GET = "GET";
        public static final String JSON_TYPE = "application/json";
        public static final String JSON_UTF8 = "application/json; charset=utf-8";
        public static final String LOWER_SET_COOKIE = "set-cookie";
        public static final String NO_STORE = "no-store";
        public static final String POST = "POST";
        public static final String REAL_IP_HEADER = "X-Real-IP";
        public static final String RETRY_AFTER = "Retry-After";
        public static final String SET_COOKIE = "Set-Cookie";
        public static final String WWW_AUTHENTICATE = "WWW-Authenticate";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AuthHttp() {
        }
    }

    /**
     * API 및 응답 필드 경로을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AuthCryptoConfigurationTest, AuthHttpTest
     */
    public static final class AuthPaths {
        public static final String CURRENT_SESSION_PATH = "/demo-sessions/current";
        public static final String INSTITUTION_LINKS_PATH = "/institution-links";
        public static final String LIVE_PATH = "/internal/health/live";
        public static final String REVERIFY_PATH = "/demo-sessions/current/reverify";
        public static final String SESSIONS_PATH = "/demo-sessions";
        public static final String SNAPSHOT_PATH = "/snapshot";
        public static final String TRANSACTIONS_PATH = "/transactions";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AuthPaths() {
        }
    }

    // ---------------- 금융 ----------------

    /**
     * 버전·오류 코드를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AccountStatusTest, BillingProjectionTest, FinancialCursorTest,
     * FinancialHttpInputTest, FinancialHttpTest, FinancialProjectionTest, FinancialShapeTest
     */
    public static final class FinanceCodes {
        public static final String API_V3 = "PAYSE-API-0.6-3";
        public static final String API_V4 = "PAYSE-API-0.6-4";
        public static final String CALCULATION_RULES = "PAYSE-CALC-1";
        public static final String DRAFT_V3 = "PAYSE-DRAFT-3";
        public static final String DRAFT_V4 = "PAYSE-DRAFT-4";
        public static final String HISTORY_LOCKED = "HISTORY_LOCKED";
        public static final String IDEMPOTENCY_CONFLICT = "IDEMPOTENCY_CONFLICT";
        public static final String INVALID_CURSOR = "INVALID_CURSOR";
        public static final String INVALID_JSON = "INVALID_JSON";
        public static final String LIMIT_EXCEEDED = "LIMIT_EXCEEDED";
        public static final String RELATION_CONFLICT = "RELATION_CONFLICT";
        public static final String REQUEST_TOO_LARGE = "REQUEST_TOO_LARGE";
        public static final String RESOURCE_FORBIDDEN = "RESOURCE_FORBIDDEN";
        public static final String RULE_VERSION_MISMATCH = "RULE_VERSION_MISMATCH";
        public static final String SESSION_INVALID = "SESSION_INVALID";
        public static final String STALE_DATA = "STALE_DATA";
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private FinanceCodes() {
        }
    }

    /**
     * 테스트 서버 설정 키를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy FinancialCursorTest, FinancialHttpTest
     */
    public static final class FinanceConfig {
        public static final String BANNER_MODE = "spring.main.banner-mode";
        public static final String PAYSE_AUTH_CODE_KEY_BASE64 = "PAYSE_AUTH_CODE_KEY_BASE64";
        public static final String PAYSE_AUTH_CODE_KEY_ID = "PAYSE_AUTH_CODE_KEY_ID";
        public static final String PAYSE_AUTH_LIMIT_KEY_BASE64 = "PAYSE_AUTH_LIMIT_KEY_BASE64";
        public static final String PAYSE_AUTH_PEER_MODE = "PAYSE_AUTH_PEER_MODE";
        public static final String PAYSE_DB_CONNECTION_TIMEOUT_MS =
            "PAYSE_DB_CONNECTION_TIMEOUT_MS";
        public static final String PAYSE_DB_MAX_POOL_SIZE = "PAYSE_DB_MAX_POOL_SIZE";
        public static final String PAYSE_DB_PASSWORD = "PAYSE_DB_PASSWORD";
        public static final String PAYSE_DB_USER = "PAYSE_DB_USER";
        public static final String PAYSE_DB_VALIDATION_TIMEOUT_MS =
            "PAYSE_DB_VALIDATION_TIMEOUT_MS";
        public static final String PAYSE_FINANCE_CURSOR_KEY_BASE64 =
            "PAYSE_FINANCE_CURSOR_KEY_BASE64";
        public static final String PAYSE_JDBC_URL = "PAYSE_JDBC_URL";
        public static final String SERVER_ADDRESS = "server.address";
        public static final String SERVER_PORT = "server.port";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private FinanceConfig() {
        }
    }

    /**
     * 요청·응답 및 저장 조회 필드 이름을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AccountStatusTest, BillingProjectionTest, FinancialCursorTest,
     * FinancialHttpInputTest, FinancialHttpTest, FinancialInputTest, FinancialProjectionTest,
     * FinancialShapeTest, FinancialTupleTest
     */
    public static final class FinanceFields {
        public static final String ACCESS_RESTRICTIONS = "accessRestrictions";
        public static final String ACCESS_TOKEN = "accessToken";
        public static final String ACCOUNTS = "accounts";
        public static final String ACCOUNT_ID = "accountId";
        public static final String ACCOUNT_IDS = "accountIds";
        public static final String ALLOCATIONS = "allocations";
        public static final String ALLOCATION_CHANGES = "allocationChanges";
        public static final String ALLOCATION_ID = "allocationId";
        public static final String AMOUNT_KRW = "amountKRW";
        public static final String AS_OF = "asOf";
        public static final String BALANCE_KRW = "balanceKRW";
        public static final String BALANCE_REFLECTED = "balanceReflected";
        public static final String BILLED_AMOUNT_KRW = "billedAmountKRW";
        public static final String BILLED_PRINCIPAL_KRW = "billedPrincipalKRW";
        public static final String BOOKING_DATE = "bookingDate";
        public static final String CARDS = "cards";
        public static final String CARD_ID = "cardId";
        public static final String CARD_PLANS = "cardPlans";
        public static final String CARD_TYPE = "cardType";
        public static final String CHANGED_REFS = "changedRefs";
        public static final String CODE = "code";
        public static final String COVERAGE = "coverage";
        public static final String CURRENCY = "currency";
        public static final String CURSOR = "cursor";
        public static final String DATA_VERSION = "dataVersion";
        public static final String DESCRIPTION = "description";
        public static final String DETACH_ALLOCATIONS = "detachAllocations";
        public static final String DETAILS = "details";
        public static final String DUE_DATE = "dueDate";
        public static final String ERROR = "error";
        public static final String EVIDENCE_REF = "evidenceRef";
        public static final String EXPECTED_DATA_VERSION = "expectedDataVersion";
        public static final String FEE_OR_ADJUSTMENT_AMOUNT_KRW = "feeOrAdjustmentAmountKRW";
        public static final String FIELD = "field";
        public static final String ID = "id";
        public static final String IDEMPOTENCY_KEY = "idempotencyKey";
        public static final String INCLUDED = "included";
        public static final String INCLUDED_TRANSACTION_REFS = "includedTransactionRefs";
        public static final String INSTALLMENT_MONTHS = "installmentMonths";
        public static final String INSTALLMENT_ROUND = "installmentRound";
        public static final String INSTITUTIONS = "institutions";
        public static final String INSTITUTION_CODE = "institutionCode";
        public static final String INSTITUTION_CODES = "institutionCodes";
        public static final String INSTITUTION_LINKS = "institutionLinks";
        public static final String ITEMS = "items";
        public static final String ITEM_ID = "itemId";
        public static final String LABEL = "label";
        public static final String MERCHANT_NAME = "merchantName";
        public static final String NAME = "name";
        public static final String NEXT_CURSOR = "nextCursor";
        public static final String NICKNAME = "nickname";
        public static final String OBLIGATIONS = "obligations";
        public static final String OBLIGATION_ID = "obligationId";
        public static final String OCCURRENCE_LINKS = "occurrenceLinks";
        public static final String ORIGINAL_TRANSACTION_ID = "originalTransactionId";
        public static final String ORIGINAL_USED_AMOUNT_KRW = "originalUsedAmountKRW";
        public static final String OWNER_ID = "ownerId";
        public static final String OWNER_TYPE = "ownerType";
        public static final String PAGE = "page";
        public static final String PHONE = "phone";
        public static final String PLANNED_PAYMENT_DAY = "plannedPaymentDay";
        public static final String PURCHASE_DATE = "purchaseDate";
        public static final String REASON = "reason";
        public static final String RECEIPT = "receipt";
        public static final String RECEIPT_EVIDENCE = "receiptEvidence";
        public static final String RECEIPT_ID = "receiptId";
        public static final String RECORD_KIND = "recordKind";
        public static final String REFERENCE_RESOLUTIONS = "referenceResolutions";
        public static final String RELATED_TRANSACTIONS = "relatedTransactions";
        public static final String RELEASED_KRW = "releasedKRW";
        public static final String REPLAYED = "replayed";
        public static final String REQUESTED_START = "requestedStart";
        public static final String REQUEST_ID = "requestId";
        public static final String RESERVE_ID = "reserveId";
        public static final String RESOURCE = "resource";
        public static final String RESPONSE = "response";
        public static final String RULE_VERSION = "ruleVersion";
        public static final String SALARY = "salary";
        public static final String SALARY_ACCOUNT_ID = "salaryAccountId";
        public static final String SALARY_AMOUNT_KRW = "salaryAmountKRW";
        public static final String SALARY_DAY = "salaryDay";
        public static final String SCHEDULE_EVIDENCE = "scheduleEvidence";
        public static final String SCHEMA_VERSION = "schemaVersion";
        public static final String SETTINGS = "settings";
        public static final String SNAPSHOT = "snapshot";
        public static final String SOURCE_REF = "sourceRef";
        public static final String SOURCE_VERSION = "sourceVersion";
        public static final String STATEMENTS = "statements";
        public static final String STATEMENT_ID = "statementId";
        public static final String STATUS = "status";
        public static final String TARGET_KIND = "targetKind";
        public static final String TRANSACTIONS = "transactions";
        public static final String TRANSACTION_ID = "transactionId";
        public static final String TRANSACTION_RELATIONS = "transactionRelations";
        public static final String UNRELEASED_KRW = "unreleasedKRW";
        public static final String USERS = "users";
        public static final String USER_ID = "userId";
        public static final String WITHDRAWAL_ACCOUNT_ID = "withdrawalAccountId";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private FinanceFields() {
        }
    }

    /**
     * HTTP 메서드·헤더·전송 형식을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy FinancialCursorTest, FinancialHttpInputTest, FinancialHttpTest, FinancialInputTest
     */
    public static final class FinanceHttp {
        public static final String AUTHORIZATION = "Authorization";
        public static final String BEARER_PREFIX = "Bearer ";
        public static final String BEARER_SCHEME = "Bearer";
        public static final String CACHE_CONTROL = "Cache-Control";
        public static final String CONTENT_ENCODING = "Content-Encoding";
        public static final String CONTENT_TYPE = "Content-Type";
        public static final String DATA_VERSION_HEADER = "Payse-Expected-Data-Version";
        public static final String DELETE = "DELETE";
        public static final String GET = "GET";
        public static final String IDEMPOTENCY_HEADER = "Idempotency-Key";
        public static final String JSON_TYPE = "application/json";
        public static final String JSON_UTF8 = "application/json; charset=utf-8";
        public static final String NO_STORE = "no-store";
        public static final String PATCH = "PATCH";
        public static final String POST = "POST";
        public static final String RULE_VERSION_HEADER = "Payse-Rule-Version";
        public static final String SET_COOKIE = "Set-Cookie";
        public static final String WWW_AUTHENTICATE = "WWW-Authenticate";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private FinanceHttp() {
        }
    }

    /**
     * API 및 응답 필드 경로을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy BillingProjectionTest, FinancialCursorTest, FinancialHttpInputTest,
     * FinancialHttpTest, FinancialInputTest, FinancialProjectionTest
     */
    public static final class FinancePaths {
        public static final String ACCOUNT_PATH = "/accounts/";
        public static final String ACCOUNT_SELECTION_PATH = "/account-selection";
        public static final String CANCEL_SUFFIX = "/cancel";
        public static final String CURRENT_SESSION_PATH = "/demo-sessions/current";
        public static final String INSTITUTION_LINKS_PATH = "/institution-links";
        public static final String OBLIGATIONS_PATH = "/obligations";
        public static final String OBLIGATION_PATH = "/obligations/";
        public static final String RESERVES_PATH = "/reserves";
        public static final String RESERVE_PATH = "/reserves/";
        public static final String SALARY_ACCOUNT_POINTER = "/settings/salary/salaryAccountId";
        public static final String SALARY_EVIDENCE_POINTER = "/settings/salary/receiptEvidence";
        public static final String SALARY_POINTER = "/settings/salary";
        public static final String SESSIONS_PATH = "/demo-sessions";
        public static final String SETTINGS_PATH = "/settings";
        public static final String SNAPSHOT_PATH = "/snapshot";
        public static final String TRANSACTIONS_PATH = "/transactions";
        public static final String TRANSACTION_CURSOR_PATH = "/transactions?cursor=";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private FinancePaths() {
        }
    }

    // ---------------- 분석 ----------------

    /**
     * 버전·오류 코드를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AnalysisEvidenceTest, AnalysisHttpTest, AnalysisIdentityTest
     */
    public static final class AnalysisCodes {
        public static final String ANALYSIS_CONTRACT = "PAYSE-ANALYSIS-1";
        public static final String API_V4 = "PAYSE-API-0.6-4";
        public static final String DRAFT_V4 = "PAYSE-DRAFT-4";
        public static final String INCOMPLETE_RESPONSE = "INCOMPLETE_RESPONSE";
        public static final String MEANING_POLICY = "PAYSE-MEANING-1";
        public static final String PROMPT_VERSION = "PAYSE-PROMPT-1";
        public static final String RESOURCE_FORBIDDEN = "RESOURCE_FORBIDDEN";
        public static final String RULE_VERSION_MISMATCH = "RULE_VERSION_MISMATCH";
        public static final String STALE_DATA = "STALE_DATA";
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String TRANSMISSION_UNKNOWN = "TRANSMISSION_UNKNOWN";
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisCodes() {
        }
    }

    /**
     * DB 조회 결과의 컬럼·별칭 이름을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AnalysisHttpTest
     */
    public static final class AnalysisColumns {
        public static final String DISPATCH_STATE = "dispatch_state";
        public static final String EXECUTION_EXPIRES_AT = "execution_expires_at";
        public static final String GUARD_EXPIRES_AT = "guard_expires_at";
        public static final String NORMAL_EXPIRES_AT_FIELD = "normal_expires_at";
        public static final String STORED_AT_FIELD = "stored_at";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisColumns() {
        }
    }

    /**
     * 테스트 서버 설정 키를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AnalysisHttpTest
     */
    public static final class AnalysisConfig {
        public static final String BANNER_MODE = "spring.main.banner-mode";
        public static final String PAYSE_AUTH_CODE_KEY_BASE64 = "PAYSE_AUTH_CODE_KEY_BASE64";
        public static final String PAYSE_AUTH_CODE_KEY_ID = "PAYSE_AUTH_CODE_KEY_ID";
        public static final String PAYSE_AUTH_LIMIT_KEY_BASE64 = "PAYSE_AUTH_LIMIT_KEY_BASE64";
        public static final String PAYSE_AUTH_PEER_MODE = "PAYSE_AUTH_PEER_MODE";
        public static final String PAYSE_DB_CONNECTION_TIMEOUT_MS =
            "PAYSE_DB_CONNECTION_TIMEOUT_MS";
        public static final String PAYSE_DB_MAX_POOL_SIZE = "PAYSE_DB_MAX_POOL_SIZE";
        public static final String PAYSE_DB_PASSWORD = "PAYSE_DB_PASSWORD";
        public static final String PAYSE_DB_USER = "PAYSE_DB_USER";
        public static final String PAYSE_DB_VALIDATION_TIMEOUT_MS =
            "PAYSE_DB_VALIDATION_TIMEOUT_MS";
        public static final String PAYSE_FINANCE_CURSOR_KEY_BASE64 =
            "PAYSE_FINANCE_CURSOR_KEY_BASE64";
        public static final String PAYSE_JDBC_URL = "PAYSE_JDBC_URL";
        public static final String SERVER_ADDRESS = "server.address";
        public static final String SERVER_PORT = "server.port";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisConfig() {
        }
    }

    /**
     * 요청·응답 및 저장 조회 필드 이름을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AnalysisEvidenceTest, AnalysisHttpTest, AnalysisIdentityTest
     */
    public static final class AnalysisFields {
        public static final String ACCESS_TOKEN = "accessToken";
        public static final String ACCOUNTS = "accounts";
        public static final String ACCOUNT_ID = "accountId";
        public static final String ACKNOWLEDGE_DUPLICATE_RISK = "acknowledgeDuplicateRisk";
        public static final String ACTION = "action";
        public static final String ACTIVE = "active";
        public static final String AMOUNT_KRW = "amountKRW";
        public static final String AMOUNT_WITHIN_RULE = "amountWithinRule";
        public static final String ANALYSIS_INPUT_HASH = "analysisInputHash";
        public static final String AS_OF = "asOf";
        public static final String CANDIDATES = "candidates";
        public static final String CANDIDATE_IDS = "candidateIds";
        public static final String CANDIDATE_KEY = "candidateKey";
        public static final String CARDS = "cards";
        public static final String CARD_ID = "cardId";
        public static final String CLASSIFICATION = "classification";
        public static final String CODE = "code";
        public static final String CONTEXT = "context";
        public static final String CONTRACT_VERSION = "contractVersion";
        public static final String CURRENT_CLASSIFICATIONS = "currentClassifications";
        public static final String DATA_VERSION = "dataVersion";
        public static final String DAY_WITHIN_RULE = "dayWithinRule";
        public static final String DESCRIPTION = "description";
        public static final String DETAIL = "detail";
        public static final String DIRECTION = "direction";
        public static final String DISCONNECTED_AT = "disconnectedAt";
        public static final String ERROR = "error";
        public static final String EVIDENCE_TRANSACTION_IDS = "evidenceTransactionIds";
        public static final String FEATURES = "features";
        public static final String FROM_ID = "fromId";
        public static final String HAS_UNRESOLVED_REVERSAL = "hasUnresolvedReversal";
        public static final String ID = "id";
        public static final String IDEMPOTENCY_KEY = "idempotencyKey";
        public static final String IMPORTANT = "important";
        public static final String INPUT = "input";
        public static final String INPUT_HASH_HINT = "inputHashHint";
        public static final String INPUT_REVISION = "inputRevision";
        public static final String INPUT_TOKENS = "inputTokens";
        public static final String INSTITUTION_CODE = "institutionCode";
        public static final String INSTITUTION_LINKS = "institutionLinks";
        public static final String INTERPRETATION = "interpretation";
        public static final String IS_REFERENCE = "isReference";
        public static final String ITEMS = "items";
        public static final String ITEM_AVAILABILITY = "itemAvailability";
        public static final String ITEM_ID = "itemId";
        public static final String ITEM_KEY = "itemKey";
        public static final String JOB_ID = "jobId";
        public static final String KIND = "kind";
        public static final String LOCAL_SESSION_EPOCH = "localSessionEpoch";
        public static final String MEANING = "meaning";
        public static final String MEANING_POLICY_VERSION = "meaningPolicyVersion";
        public static final String MEMORIES = "memories";
        public static final String MERCHANT_NAME = "merchantName";
        public static final String MODEL = "model";
        public static final String NAME = "name";
        public static final String NORMALIZED_NAME = "normalizedName";
        public static final String NORMAL_EXPIRES_AT = "normalExpiresAt";
        public static final String OBLIGATIONS = "obligations";
        public static final String OBSERVED_MONTHS = "observedMonths";
        public static final String OCCURRENCE_COUNT = "occurrenceCount";
        public static final String ORIGINAL_TRANSACTION_ID = "originalTransactionId";
        public static final String OUTPUT = "output";
        public static final String OUTPUT_TOKENS = "outputTokens";
        public static final String PAYSE_TRANSACTION_TYPE = "payseTransactionType";
        public static final String PERMIT = "permit";
        public static final String PERMIT_EXPIRES_AT = "permitExpiresAt";
        public static final String PHONE = "phone";
        public static final String POLICY = "policy";
        public static final String POSTED_DATE = "postedDate";
        public static final String PREVIOUS_JOB_ID = "previousJobId";
        public static final String PROMPT = "prompt";
        public static final String PROPERTIES = "properties";
        public static final String PROVENANCE = "provenance";
        public static final String PURCHASE_DATE = "purchaseDate";
        public static final String REASON = "reason";
        public static final String REASON_CODE = "reasonCode";
        public static final String REASON_CODES = "reasonCodes";
        public static final String RECORD_KIND = "recordKind";
        public static final String REFERENCE_POLICY = "referencePolicy";
        public static final String REFERENCE_RESOLUTIONS = "referenceResolutions";
        public static final String REFLECTION_REASON = "reflectionReason";
        public static final String RELATIONS = "relations";
        public static final String RESPONSE = "response";
        public static final String RESULT = "result";
        public static final String RESULT_AVAILABILITY = "resultAvailability";
        public static final String RESULT_ID = "resultId";
        public static final String RULE_VERSION = "ruleVersion";
        public static final String SCHEMA_VERSION = "schemaVersion";
        public static final String SELECTED_ACCOUNT_IDS = "selectedAccountIds";
        public static final String SEMANTIC_TASK_KIND = "semanticTaskKind";
        public static final String SOURCE_REF = "sourceRef";
        public static final String SOURCE_VERSION = "sourceVersion";
        public static final String STATE = "state";
        public static final String STATUS = "status";
        public static final String STORED_AT = "storedAt";
        public static final String SUGGESTED_AMOUNT_KRW = "suggestedAmountKRW";
        public static final String SUGGESTED_DAY = "suggestedDay";
        public static final String TARGET_TRANSACTION_ID = "targetTransactionId";
        public static final String TO_ID = "toId";
        public static final String TRANSACTIONS = "transactions";
        public static final String TRANSACTION_ID = "transactionId";
        public static final String TRANSACTION_RELATIONS = "transactionRelations";
        public static final String TRIGGER_KIND = "triggerKind";
        public static final String UNAVAILABLE_REFERENCES = "unavailableReferences";
        public static final String USAGE_KNOWN = "usageKnown";
        public static final String USERS = "users";
        public static final String USER_ID = "userId";
        public static final String VALUE = "value";
        public static final String VERIFIED = "verified";
        public static final String VERSIONS = "versions";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisFields() {
        }
    }

    /**
     * HTTP 메서드·헤더·전송 형식을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AnalysisHttpTest
     */
    public static final class AnalysisHttp {
        public static final String AUTHORIZATION = "Authorization";
        public static final String BEARER_PREFIX = "Bearer ";
        public static final String CACHE_CONTROL = "Cache-Control";
        public static final String CONTENT_TYPE = "Content-Type";
        public static final String DELETE = "DELETE";
        public static final String GET = "GET";
        public static final String IDEMPOTENCY_HEADER = "Idempotency-Key";
        public static final String JSON_UTF8 = "application/json; charset=utf-8";
        public static final String NO_STORE = "no-store";
        public static final String POST = "POST";
        public static final String SET_COOKIE = "Set-Cookie";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisHttp() {
        }
    }

    /**
     * API 및 응답 필드 경로을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy AnalysisHttpTest
     */
    public static final class AnalysisPaths {
        public static final String ANALYSIS_JOBS_PATH = "/analysis-jobs";
        public static final String ANALYSIS_JOB_PATH = "/analysis-jobs/";
        public static final String ANALYSIS_MEMORY_PATH = "/analysis-memories/";
        public static final String ANALYSIS_QUERY_PATH = "/analysis-results/query";
        public static final String CURRENT_SESSION_PATH = "/demo-sessions/current";
        public static final String INPUT_SUFFIX = "/input";
        public static final String RETRY_SUFFIX = "/retry";
        public static final String SESSIONS_PATH = "/demo-sessions";
        public static final String SNAPSHOT_PATH = "/snapshot";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private AnalysisPaths() {
        }
    }

    // ---------------- KMS ----------------

    /**
     * KMS 요청·응답 필드와 검증 오류 코드를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy GoogleKmsTest
     */
    public static final class KmsContract {
        public static final String AAD_CRC32C = "additionalAuthenticatedDataCrc32c";
        public static final String AAD_FIELD = "additionalAuthenticatedData";
        public static final String CIPHERTEXT_CRC32C = "ciphertextCrc32c";
        public static final String CIPHERTEXT_FIELD = "ciphertext";
        public static final String INVALID_KMS_RESPONSE = "INVALID_KMS_RESPONSE";
        public static final String NAME = "name";
        public static final String PLAINTEXT_CRC32C = "plaintextCrc32c";
        public static final String PLAINTEXT_FIELD = "plaintext";
        public static final String VERIFIED_AAD_CRC32C =
            "verifiedAdditionalAuthenticatedDataCrc32c";
        public static final String VERIFIED_PLAINTEXT_CRC32C = "verifiedPlaintextCrc32c";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private KmsContract() {
        }
    }

    /**
     * KMS HTTP 경로·동작 접미사·헤더을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy GoogleKmsTest, ProviderStub
     */
    public static final class KmsTransport {
        public static final String AUTHORIZATION = "Authorization";
        public static final String DECRYPT_SUFFIX = ":decrypt";
        public static final String ENCRYPT_SUFFIX = ":encrypt";
        public static final String LOCATION = "Location";
        public static final String PROVIDER_API_PATH = "/v1/";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private KmsTransport() {
        }
    }

    // ---------------- 급여 안내 ----------------

    /**
     * 버전·오류 코드를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy SalaryMonthTest, SalaryNoticeHttpTest
     */
    public static final class SalaryCodes {
        public static final String API_V3 = "PAYSE-API-0.6-3";
        public static final String REQUEST_TOO_LARGE = "REQUEST_TOO_LARGE";
        public static final String SALARY_NOTICE_CONTRACT = "PAYSE-SALARY-NOTICE-1";
        public static final String SESSION_INVALID = "SESSION_INVALID";
        public static final String TEMPORARILY_UNAVAILABLE = "TEMPORARILY_UNAVAILABLE";
        public static final String VALIDATION_FAILED = "VALIDATION_FAILED";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private SalaryCodes() {
        }
    }

    /**
     * 테스트 서버 설정 키를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy SalaryNoticeHttpTest
     */
    public static final class SalaryConfig {
        public static final String BANNER_MODE = "spring.main.banner-mode";
        public static final String PAYSE_AUTH_CODE_KEY_BASE64 = "PAYSE_AUTH_CODE_KEY_BASE64";
        public static final String PAYSE_AUTH_CODE_KEY_ID = "PAYSE_AUTH_CODE_KEY_ID";
        public static final String PAYSE_AUTH_LIMIT_KEY_BASE64 = "PAYSE_AUTH_LIMIT_KEY_BASE64";
        public static final String PAYSE_AUTH_PEER_MODE = "PAYSE_AUTH_PEER_MODE";
        public static final String PAYSE_DB_CONNECTION_TIMEOUT_MS =
            "PAYSE_DB_CONNECTION_TIMEOUT_MS";
        public static final String PAYSE_DB_MAX_POOL_SIZE = "PAYSE_DB_MAX_POOL_SIZE";
        public static final String PAYSE_DB_PASSWORD = "PAYSE_DB_PASSWORD";
        public static final String PAYSE_DB_USER = "PAYSE_DB_USER";
        public static final String PAYSE_DB_VALIDATION_TIMEOUT_MS =
            "PAYSE_DB_VALIDATION_TIMEOUT_MS";
        public static final String PAYSE_FINANCE_CURSOR_KEY_BASE64 =
            "PAYSE_FINANCE_CURSOR_KEY_BASE64";
        public static final String PAYSE_JDBC_URL = "PAYSE_JDBC_URL";
        public static final String SERVER_ADDRESS = "server.address";
        public static final String SERVER_PORT = "server.port";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private SalaryConfig() {
        }
    }

    /**
     * 요청·응답 및 저장 조회 필드 이름을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy SalaryNoticeHttpTest
     */
    public static final class SalaryFields {
        public static final String ACCESS_TOKEN = "accessToken";
        public static final String CODE = "code";
        public static final String CONTRACT_VERSION = "contractVersion";
        public static final String DISMISSED = "dismissed";
        public static final String DISMISSED_AT = "dismissedAt";
        public static final String ERROR = "error";
        public static final String NAME = "name";
        public static final String NEXT_CURSOR = "nextCursor";
        public static final String OBLIGATIONS = "obligations";
        public static final String PAGE = "page";
        public static final String PHONE = "phone";
        public static final String RECEIPT_EVIDENCE = "receiptEvidence";
        public static final String SALARY = "salary";
        public static final String SCHEMA_VERSION = "schemaVersion";
        public static final String SETTINGS = "settings";
        public static final String USERS = "users";
        public static final String USER_ID = "userId";
        public static final String VERSIONS = "versions";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private SalaryFields() {
        }
    }

    /**
     * HTTP 메서드·헤더·전송 형식을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy SalaryNoticeHttpTest
     */
    public static final class SalaryHttp {
        public static final String AUTHORIZATION = "Authorization";
        public static final String BEARER_PREFIX = "Bearer ";
        public static final String CACHE_CONTROL = "Cache-Control";
        public static final String CONTENT_TYPE = "Content-Type";
        public static final String DELETE = "DELETE";
        public static final String GET = "GET";
        public static final String JSON_UTF8 = "application/json; charset=utf-8";
        public static final String NO_STORE = "no-store";
        public static final String POST = "POST";
        public static final String PUT = "PUT";
        public static final String SET_COOKIE = "Set-Cookie";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private SalaryHttp() {
        }
    }

    /**
     * API 및 응답 필드 경로을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy SalaryNoticeHttpTest
     */
    public static final class SalaryPaths {
        public static final String CURRENT_SESSION_PATH = "/demo-sessions/current";
        public static final String DISMISSAL_SUFFIX = "/dismissal";
        public static final String SALARY_NOTICE_PATH = "/salary-notices/";
        public static final String SESSIONS_PATH = "/demo-sessions";
        public static final String SNAPSHOT_PATH = "/snapshot";
        public static final String TRANSACTION_CURSOR_PATH = "/transactions?cursor=";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private SalaryPaths() {
        }
    }

    // ---------------- 생존 확인 ----------------

    /**
     * HTTP 메서드·헤더·전송 형식을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy BootstrapHttpTest
     */
    public static final class HealthHttp {
        public static final String AUTHORIZATION = "Authorization";
        public static final String CONTENT_TYPE = "Content-Type";
        public static final String JSON_TYPE = "application/json";
        public static final String LOWER_CONTENT_TYPE = "content-type";
        public static final String LOWER_SET_COOKIE = "set-cookie";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private HealthHttp() {
        }
    }

    /**
     * API 및 응답 필드 경로을 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy BootstrapHttpTest
     */
    public static final class HealthPaths {
        public static final String ACTUATOR_ENV_PATH = "/actuator/env";
        public static final String LIVE_PATH = "/internal/health/live";
        public static final String SESSIONS_PATH = "/demo-sessions";
        public static final String SNAPSHOT_PATH = "/snapshot";
        public static final String TRANSACTIONS_PATH = "/transactions";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private HealthPaths() {
        }
    }

    // ---------------- DB 설정 ----------------

    /**
     * 테스트 서버 설정 키를 운영 상수와 독립적으로 유지한다.
     * @created 2026-11-02
     * @usedBy DatabaseConfigurationTest, PostgresTransactionTest
     */
    public static final class DatabaseConfig {
        public static final String PAYSE_DB_CONNECTION_TIMEOUT_MS =
            "PAYSE_DB_CONNECTION_TIMEOUT_MS";
        public static final String PAYSE_DB_MAX_POOL_SIZE = "PAYSE_DB_MAX_POOL_SIZE";
        public static final String PAYSE_DB_PASSWORD = "PAYSE_DB_PASSWORD";
        public static final String PAYSE_DB_USER = "PAYSE_DB_USER";
        public static final String PAYSE_DB_VALIDATION_TIMEOUT_MS =
            "PAYSE_DB_VALIDATION_TIMEOUT_MS";
        public static final String PAYSE_JDBC_URL = "PAYSE_JDBC_URL";

        /**
         * 정적 테스트 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private DatabaseConfig() {
        }
    }

    // ---------------- 문서 검사 ----------------

    /**
     * 문서 검사 실행에 필요한 테스트 속성과 클래스 이름을 보존한다.
     * @created 2026-11-02
     * @usedBy ApiDocRulesTest.check
     */
    public static final class DocTool {
        public static final String TOOL_CLASSPATH_PROPERTY = "payse.docToolClasspath";
        public static final String CHECKER_CLASS = "VerifyApiDocs";

        /**
         * 정적 문서 검사 계약만 제공하며 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private DocTool() {
        }
    }
}
