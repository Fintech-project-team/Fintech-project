package com.payse.api.constants;

/**
 * 설정·경로·HTTP·암호 알고리즘과 고정 규격를 기능별 구간에서 관리한다.
 * @created 2026-11-02
 * @usedBy AnalysisController, AnalysisEvidence, AnalysisJobs, AnalysisJson
 */
public final class ApiConfigConstants {
    /**
     * 비공개 AI 준비와 상태의 고정 규격이다.
     * @created 2026-11-04
     * @usedBy AnalysisReadiness
     */
    public static final class Readiness {
        public static final String LOCK_FILE = "ai.lock";
        public static final String STATUS_FILE = "ai-status.json";
        public static final String PROFILE_FILE = "ai-profile.json";
        public static final String PERFORMANCE_FORMAT = "payse-ai-performance-v1";
        public static final String READINESS_FORMAT = "payse-ai-readiness-v1";
        public static final String GIT_MARKER = ".git";
        public static final String NEXT_SUFFIX = ".next";

        /**
         * 정적 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-04
         * @usedBy 없음: 정적 상수 전용
         */
        private Readiness() {
        }
    }

    /**
     * 명시적인 폐기용 감마 배포의 설정 및 암호 규격이다.
     * @created 2026-11-04
     * @usedBy GammaDeployment, GammaLocalKeys, AnalysisReadiness
     */
    public static final class GammaLocal {
        public static final String KEY_REFERENCE = "gamma-local-v1:";
        public static final String HASH_ALGORITHM = "SHA-256";
        public static final String CIPHER_ALGORITHM = "AES/GCM/NoPadding";
        public static final String KEY_ALGORITHM = "AES";
        public static final String VERSION = "gamma-local-2";
        public static final String CONTROLLER_PACKAGE = "com.payse.api.analysis.controller";
        public static final String PERFORMANCE = "/com/payse/ai/rules/performance.json";
        public static final String IDENTITY = "/gamma-identity.json";

        /**
         * 정적 설정 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-04
         * @usedBy 없음: 정적 상수 전용
         */
        private GammaLocal() {
        }
    }

    /**
     * 분석 실행 구성·비용 경계의 고정 문자열이다.
     * @created 2026-11-03
     * @usedBy AnalysisSettings, AnalysisPricing, AnalysisCosts, AnalysisConfiguration
     * @modified 2026-11-04 - 프롬프트 버전의 중복 상수를 실제 지문으로 대체
     */
    public static final class Execution {
        public static final String SETTINGS_PROPERTY = "payse.analysis.settings-file";
        public static final String SETTINGS_BINDING = "${payse.analysis.settings-file:}";
        public static final String ENABLED = "enabled";
        public static final String LLM_FILE = "llmSettingsFile";
        public static final String KMS_FILE = "kmsTokenFile";
        public static final String KMS_KEY = "kmsKey";
        public static final String PROJECT = "projectId";
        public static final String PRICING = "pricingVersion";
        public static final String COUNT_PREFIX = "analysis-count:";
        public static final String RESPONSE_VERSION = "PAYSE-analysis-storage-1";

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
    private ApiConfigConstants() {
    }

    // 분석
    /**
     * 분석 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisController, AnalysisEvidence, AnalysisJobs, AnalysisJson
     */
    public static final class Analysis {
        // 업무·프로토콜 값
        public static final String NO_STORE = "no-store";
        public static final String PREFER = "Prefer";
        public static final String WAIT_PREFERENCE = "wait=5";
        public static final String ENCRYPT_ACTION = ":encrypt";
        public static final String DECRYPT_ACTION = ":decrypt";
        public static final String API_V4 = "PAYSE-API-0.6-4";
        public static final String DRAFT_V4 = "PAYSE-DRAFT-4";
        public static final String ANALYSIS_CONTRACT = "PAYSE-ANALYSIS-1";
        public static final String SHA256_PREFIX = "sha256:";
        public static final String MEMORY_CONTRACT = "PAYSE-MEMORY-1";
        public static final String MEANING_POLICY = "PAYSE-MEANING-1";

        // 설정 키
        public static final String CONTENT_ENCODING = "Content-Encoding";
        public static final String PAYSE_EXPECTED_DATA_VERSION = "Payse-Expected-Data-Version";
        public static final String PAYSE_RULE_VERSION = "Payse-Rule-Version";
        public static final String IDEMPOTENCY_KEY = "Idempotency-Key";
        public static final String CIPHER_ALGORITHM = "AES/GCM/NoPadding";
        public static final String KEY_ALGORITHM = "AES";
        public static final String KMS_ENDPOINT = "https://cloudkms.googleapis.com/v1/";
        public static final String DIGEST_ALGORITHM = "SHA-256";

        // 경로
        public static final String KEY_VERSION_PATH = "/cryptoKeyVersions/";
        public static final String JOBS_PATH = "/analysis-jobs";
        public static final String JOB_INPUT_PATH = "/analysis-jobs/{id}/input";
        public static final String JOB_RETRY_PATH = "/analysis-jobs/{id}/retry";
        public static final String RESULT_QUERY_PATH = "/analysis-results/query";
        public static final String JOB_PATH = "/analysis-jobs/{id}";
        public static final String MEMORY_PATH = "/analysis-memories/{id}";

        // 기간 조회·기억 관리
        public static final String MEMORIES_PATH = "/analysis-memories";
        public static final String MEMORIES_PURPOSE = "analysis-memories";

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
     * @usedBy AuthCrypto, AuthCryptoConfiguration, AuthHttpInput, AuthHttpResponse
     */
    public static final class Auth {
        // 설정 키
        public static final String PAYSE_AUTH_PEER_MODE = "PAYSE_AUTH_PEER_MODE";
        public static final String SERVER_FORWARD_HEADERS_STRATEGY =
            "server.forward-headers-strategy";
        public static final String SERVER_ADDRESS = "server.address";
        public static final String X_PAYSE_CLIENT_IP = "X-Payse-Client-IP";
        public static final String CONTENT_ENCODING = "Content-Encoding";
        public static final String DIGEST_ALGORITHM = "SHA-256";
        public static final String HMAC_ALGORITHM = "HmacSHA256";
        public static final String PAYSE_AUTH_CODE_KEY_BASE64 = "PAYSE_AUTH_CODE_KEY_BASE64";
        public static final String PAYSE_AUTH_LIMIT_KEY_BASE64 = "PAYSE_AUTH_LIMIT_KEY_BASE64";
        public static final String PAYSE_AUTH_CODE_KEY_ID = "PAYSE_AUTH_CODE_KEY_ID";

        // 업무·프로토콜 값
        public static final String LOOPBACK_PROXY = "loopback-proxy";
        public static final String DIRECT = "direct";
        public static final String NONE = "none";
        public static final String LOOPBACK_ADDRESS = "127.0.0.1";
        public static final String APPLICATION = "application";
        public static final String JSON = "json";
        public static final String AUTHORIZATION = "Authorization";
        public static final String BEARER_PREFIX = "Bearer ";
        public static final String BEARER = "Bearer";
        public static final String NO_STORE = "no-store";
        public static final String SHA256_PREFIX = "sha256:";
        public static final String CODE_DOMAIN = "payse-code-v1\n";
        public static final String HMAC_PREFIX = "hmac-sha256:";
        public static final String COMBINATION_DOMAIN = "payse-limit-combo-v1\n";
        public static final String PEER_DOMAIN = "payse-limit-ip-v1\n";

        // 경로
        public static final String SESSIONS_PATH = "/demo-sessions";
        public static final String REVERIFY_PATH = "/demo-sessions/current/reverify";
        public static final String CURRENT_SESSION_PATH = "/demo-sessions/current";

        /**
         * 인증 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Auth() {
        }
    }

    // 서버 설정
    /**
     * 서버 설정 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy BootstrapSecurityConfiguration, DatabaseConfiguration, HealthController,
     *     JpaConfiguration
     */
    public static final class Server {
        // 설정 키
        public static final String HEALTH_PATH = "/internal/health/live";
        public static final String AUTH_PROFILE = "database & auth";
        public static final String FINANCE_PROFILE = "database & auth & finance";
        public static final String ANALYSIS = "analysis";
        public static final String SALARY_NOTICES = "salary-notices";
        public static final String PAYSE_JDBC_URL = "PAYSE_JDBC_URL";
        public static final String POSTGRES_URL_PREFIX = "jdbc:postgresql:";
        public static final String JDBC_PREFIX = "jdbc:";
        public static final String POSTGRES_NETWORK_PREFIX = "jdbc:postgresql://";
        public static final String LOCALHOST = "localhost";
        public static final String LOOPBACK_IPV4 = "127.0.0.1";
        public static final String LOOPBACK_IPV6 = "[::1]";
        public static final String SSL_MODE = "sslmode";
        public static final String SSL_ROOT_CERT = "sslrootcert";
        public static final String SSL_CERT = "sslcert";
        public static final String SSL_KEY = "sslkey";
        public static final String SSL_VERIFY_FULL = "verify-full";
        public static final String PAYSE_DB_USER = "PAYSE_DB_USER";
        public static final String PAYSE_DB_PASSWORD = "PAYSE_DB_PASSWORD";
        public static final String PAYSE_DB_MAX_POOL_SIZE = "PAYSE_DB_MAX_POOL_SIZE";
        public static final String PAYSE_DB_CONNECTION_TIMEOUT_MS =
            "PAYSE_DB_CONNECTION_TIMEOUT_MS";
        public static final String PAYSE_DB_VALIDATION_TIMEOUT_MS =
            "PAYSE_DB_VALIDATION_TIMEOUT_MS";
        public static final String PAYSE = "payse";
        public static final String DIALECT_SETTING = "hibernate.dialect";
        public static final String POSTGRES_DIALECT = "org.hibernate.dialect.PostgreSQLDialect";
        public static final String METADATA_ACCESS = "hibernate.boot.allow_jdbc_metadata_access";
        public static final String DDL_ACTION = "hibernate.hbm2ddl.auto";
        public static final String NONE = "none";
        public static final String DATABASE_ACTION =
            "jakarta.persistence.schema-generation.database.action";
        public static final String SCRIPTS_ACTION =
            "jakarta.persistence.schema-generation.scripts.action";
        public static final String SHARED_CACHE_MODE = "jakarta.persistence.sharedCache.mode";
        public static final String NO_SHARED_CACHE = "NONE";
        public static final String SECOND_LEVEL_CACHE = "hibernate.cache.use_second_level_cache";
        public static final String QUERY_CACHE = "hibernate.cache.use_query_cache";
        public static final String CONNECTION_MODE = "hibernate.connection.handling_mode";
        public static final String DELAYED_ACQUISITION_AND_HOLD = "DELAYED_ACQUISITION_AND_HOLD";
        public static final String SHOW_SQL = "hibernate.show_sql";
        public static final String FORMAT_SQL = "hibernate.format_sql";
        public static final String SQL_COMMENTS = "hibernate.use_sql_comments";
        public static final String TIME_ZONE = "hibernate.jdbc.time_zone";
        public static final String UTC = "UTC";
        public static final String UP = "UP";

        /**
         * 서버 설정 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Server() {
        }
    }

    // 금융
    /**
     * 금융 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy BootstrapSecurityConfiguration, FinancialController, FinancialCursor,
     *     FinancialHttpInput
     */
    public static final class Finance {
        // 경로
        public static final String SNAPSHOT_PATH = "/snapshot";
        public static final String TRANSACTIONS_PATH = "/transactions";
        public static final String LINKS_PATH = "/institution-links";
        public static final String OBLIGATIONS_PATH = "/obligations";
        public static final String RECURRING_DECISIONS_PATH = "/recurring-decisions";
        public static final String RESERVES_PATH = "/reserves";
        public static final String CANCEL_OBLIGATION_PATH = "/obligations/{id}/cancel";
        public static final String CANCEL_RESERVE_PATH = "/reserves/{id}/cancel";
        public static final String SELECTION_PATH = "/account-selection";
        public static final String ACCOUNT_PATH = "/accounts/{id}";
        public static final String SETTINGS_PATH = "/settings";
        public static final String OBLIGATION_PATH = "/obligations/{id}";
        public static final String RESERVE_PATH = "/reserves/{id}";
        public static final String ACCOUNT_PATH_PREFIX = "/accounts/";
        public static final String CANCEL_SUFFIX = "/cancel";

        // 업무·프로토콜 값
        public static final String NO_STORE = "no-store";
        public static final String APPLICATION = "application";
        public static final String JSON = "json";
        public static final String DRAFT_V3 = "PAYSE-DRAFT-3";
        public static final String DRAFT_V4 = "PAYSE-DRAFT-4";
        public static final String KRW = "KRW";
        public static final String CONSTRAINT_STATE_PREFIX = "23";
        public static final String API_V3 = "PAYSE-API-0.6-3";
        public static final String API_V4 = "PAYSE-API-0.6-4";
        public static final String SHA256_PREFIX = "sha256:";
        public static final String DATE = "Date";
        public static final String ACCOUNT_REF_PREFIX = "account:";
        public static final String CARD_REF_PREFIX = "card:";
        public static final String INVALID_YEAR = "0000";
        public static final String ITEMS_SUFFIX = " items";
        public static final String SEOUL_ZONE = "Asia/Seoul";

        // 설정 키
        public static final String PAYSE_EXPECTED_DATA_VERSION = "Payse-Expected-Data-Version";
        public static final String PAYSE_RULE_VERSION = "Payse-Rule-Version";
        public static final String IDEMPOTENCY_HEADER = "Idempotency-Key";
        public static final String CONTENT_ENCODING = "Content-Encoding";
        public static final String POSTGRES_VALUE_CLASS = "org.postgresql.util.PGobject";
        public static final String AUTH_CONTEXT_SUFFIX = "|payse_runtime|read committed";
        public static final String PAYSE_FINANCE_CURSOR_KEY_BASE64 =
            "PAYSE_FINANCE_CURSOR_KEY_BASE64";
        public static final String KEY_ALGORITHM = "AES";
        public static final String CIPHER_ALGORITHM = "AES/GCM/NoPadding";
        public static final String DIGEST_ALGORITHM = "SHA-256";

        // 기간 조회·기억 관리
        public static final String PERIOD_PURPOSE = "financial-transactions-period";

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
     * @usedBy BootstrapSecurityConfiguration, SalaryMonth, SalaryNoticeController,
     *     SalaryNoticeService
     */
    public static final class Salary {
        // 경로
        public static final String SALARY_NOTICE_PATH = "/salary-notices/{payMonth}";
        public static final String DISMISSAL_PATH = "/salary-notices/{payMonth}/dismissal";

        // 설정 키
        public static final String CONTENT_ENCODING = "Content-Encoding";
        public static final String PAYSE_EXPECTED_DATA_VERSION = "Payse-Expected-Data-Version";
        public static final String PAYSE_RULE_VERSION = "Payse-Rule-Version";
        public static final String IDEMPOTENCY_KEY = "Idempotency-Key";

        // 업무·프로토콜 값
        public static final String NO_STORE = "no-store";
        public static final String NOTICE_CONTRACT = "PAYSE-SALARY-NOTICE-1";
        public static final String INVALID_YEAR = "0000";

        /**
         * 급여 안내 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Salary() {
        }
    }

    // 개발 도구
    /**
     * 개발 도구 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy PrepareDemo, VerifyApiDocs
     */
    public static final class Tools {
        // 설정 키
        public static final String PAYSE_AUTH_CODE_KEY_ID = "PAYSE_AUTH_CODE_KEY_ID";
        public static final String PAYSE_AUTH_CODE_KEY_BASE64 = "PAYSE_AUTH_CODE_KEY_BASE64";
        public static final String PAYSE_AUTH_LIMIT_KEY_BASE64 = "PAYSE_AUTH_LIMIT_KEY_BASE64";
        public static final String JAVA_EXTENSION = ".java";
        public static final String NO_PROCESSORS = "-proc:none";
        public static final String CREATED = "created";
        public static final String USED_BY = "usedBy";
        public static final String MODIFIED = "modified";

        /**
         * 개발 도구 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Tools() {
        }
    }
}
