package com.payse.api.constants;

/**
 * 검증과 실패 진단 문구를 기능별 구간에서 관리한다.
 * @created 2026-11-02
 * @usedBy AnalysisIdentity, AnalysisJobs, AnalysisJson, AnalysisRepository
 */
public final class ApiMessageConstants {
    /**
     * 상수 컨테이너의 인스턴스 생성을 막는다.
     * @created 2026-11-02
     * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
     */
    private ApiMessageConstants() {
    }

    // 분석
    /**
     * 분석 호출부의 고정 문자열을 제공한다.
     * @created 2026-11-02
     * @usedBy AnalysisIdentity, AnalysisJobs, AnalysisJson, AnalysisRepository
     */
    public static final class Analysis {
        // 진단 문구
        public static final String INCOMPLETE_MEMORY = "Encrypted memory is incomplete";
        public static final String PROTECTOR = "protector";
        public static final String PLAINTEXT = "plaintext";
        public static final String WRAPPED = "wrapped";
        public static final String ENCRYPTION_FAILED = "Memory encryption failed";
        public static final String ENCRYPTED = "encrypted";
        public static final String INVALID_MEMORY_KEY = "Invalid memory key";
        public static final String MEMORY_AUTH_FAILED = "Memory authentication failed";
        public static final String USER_ID = "userId";
        public static final String ITEM_ID = "itemId";
        public static final String INCOMPLETE_WRAPPED_KEY = "Wrapped key is incomplete";
        public static final String DUPLICATE_IDENTITY = "Analysis identity is not unique";
        public static final String OWNER_MISMATCH = "Analysis owner differs";
        public static final String INSERT_FAILED = "Analysis insert did not complete";
        public static final String MISSING_CHANGES = "Analysis changes are required";
        public static final String IMMUTABLE_IDENTITY = "Analysis identity is immutable";
        public static final String UPDATE_FAILED = "Analysis update did not complete";
        public static final String UNKNOWN_COLUMN = "Unknown analysis column";
        public static final String AUTH_TRANSACTION_REQUIRED =
            "Analysis requires an authenticated transaction";
        public static final String HTTP = "http";
        public static final String TOKENS = "tokens";
        public static final String INVALID_KEY_PATH = "One approved CryptoKey path is required";
        public static final String ENDPOINT = "endpoint";
        public static final String MISSING_KEY_CONTEXT = "Memory key and context are required";
        public static final String MISSING_ITEM = "Missing analysis item";
        public static final String COMPLETION_UNRECORDED =
            "Analysis completion was not recorded; persisted dispatch remains unresolved";
        public static final String DIGEST_UNAVAILABLE = "Required digest unavailable";
        public static final String INCOMPLETE_RESULT = "Analysis result is incomplete";
        public static final String DUPLICATE_RESULT = "Repeated result identity";
        public static final String MEMORY_CHANGED = "Memory changed during result delivery";
        public static final String VERSIONS_REQUIRED = "Explicit analysis versions required";
        public static final String STORED_AT = "storedAt";
        public static final String MEMORY = "memory";
        public static final String NOW = "now";
        public static final String TIME_BEFORE_STORAGE = "Current time precedes the stored memory";
        public static final String ACCESS = "access";
        public static final String REFERENCE_REQUIRED = "Important memory must be reference data";
        public static final String DELETION_BEFORE_STORAGE = "Deletion precedes storage";

        // 기간 조회·기억 관리
        public static final String MISSING_MEMORY_BODY = "Missing authorized memory body";
        public static final String MEMORY_ENTRY_REDACTED = "Entry[REDACTED]";
        public static final String MEMORY_PAGE_REDACTED = "Page[REDACTED]";
        public static final String MEMORY_QUERY_REDACTED = "MemoryQuery[REDACTED]";

        // 기간 조회·기억 관리
        public static final String INVALID_MEMORY_PERIOD =
            "Valid memory period and clock are required";
        public static final String INVALID_MEMORY_PAGE = "Valid memory page bounds are required";

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
     * @usedBy AuthCredentials, AuthCrypto, AuthCryptoConfiguration, AuthHttpInput
     */
    public static final class Auth {
        // 진단 문구
        public static final String INVALID_PEER_MODE =
            "Authentication requires an explicit supported peer mode and forwarding disabled";
        public static final String LOOPBACK_BINDING_REQUIRED =
            "Loopback proxy authentication requires an explicit loopback binding";
        public static final String REQUEST_FAILED_MESSAGE = "요청을 처리하지 못했습니다.";
        public static final String SECRETS_REQUIRED = "Authentication secrets are required";
        public static final String INVALID_TOKEN_FORMAT = "Invalid session token format";
        public static final String ALGORITHM_UNAVAILABLE =
            "Required authentication algorithm unavailable";
        public static final String USER_ID_REQUIRED = "Authentication user ID is required";
        public static final String PEER_ADDRESS_REQUIRED =
            "Authentication peer address is required";
        public static final String INVALID_AUTH_KEYS = "Invalid authentication key configuration";
        public static final String DISTINCT_KEYS_REQUIRED = "Authentication keys must be distinct";
        public static final String INVALID_FAILURE = "Invalid authentication failure result";
        public static final String INPUT_REJECTED = "Authentication input rejected";
        public static final String UNKNOWN_FAILURE = "Unexpected input failure kind";
        public static final String STORAGE_FAILED = "Authentication storage failed";
        public static final String ENTITY_FACTORY_REQUIRED =
            "Authentication EntityManagerFactory is required";
        public static final String WRITE_TRANSACTION_REQUIRED =
            "Authentication storage requires a read/write READ COMMITTED transaction";
        public static final String SHARED_STORE_REQUIRED =
            "Authentication storage must use one EntityManagerFactory and DataSource";
        public static final String WORK_REQUIRED = "Authentication work is required";
        public static final String NESTED_TRANSACTION =
            "Authentication transactions cannot be nested";
        public static final String INVALID_NAME = "Invalid authentication name";
        public static final String INVALID_PHONE = "Invalid authentication phone";
        public static final String INVALID_CODE = "Invalid authentication code";
        public static final String INVALID_REQUIRED_KEYS =
            "Invalid required authentication key configuration";

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
     * @usedBy DatabaseConfiguration
     */
    public static final class Server {
        // 진단 문구
        public static final String INVALID_JDBC_URL = "PAYSE_JDBC_URL must use PostgreSQL";
        public static final String INVALID_VALIDATION_TIMEOUT =
            "PAYSE_DB_VALIDATION_TIMEOUT_MS must be at least 250 and less than PAYSE_DB_CONNECTION_TIMEOUT_MS";
        public static final String UNRESOLVED_SETTING = " could not be resolved";
        public static final String REQUIRED_SETTING = " is required and must not be blank";
        public static final String INVALID_INTEGER_SETTING =
            " must be an ASCII integer between 1 and 2147483647";

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
     * @usedBy FinancialCursor, FinancialJson, FinancialRepository, TransactionRepository
     */
    public static final class Finance {
        // 진단 문구
        public static final String STORAGE_FAILED = "Transaction storage failed";
        public static final String ENTITY_MANAGER_REQUIRED = "Financial EntityManager is required";
        public static final String AUTH_TRANSACTION_REQUIRED =
            "Financial read requires the authenticated transaction";
        public static final String SHARED_MANAGER_REQUIRED =
            "Financial read requires the same EntityManager";
        public static final String OWNER_MISMATCH = "Financial owner context does not match";
        public static final String ENTITY_FACTORY_REQUIRED =
            "Transaction EntityManagerFactory is required";
        public static final String TRANSACTION_ID_REQUIRED = "Transaction ID is required";
        public static final String READ_COMMITTED_REQUIRED =
            "Transaction read requires the authenticated READ COMMITTED transaction";
        public static final String OWNER_CONTEXT_REQUIRED =
            "Transaction read requires an authorized user context";
        public static final String INVALID_CURSOR_KEY =
            "Invalid required financial cursor key configuration";
        public static final String DIGEST_UNAVAILABLE = "Required financial digest unavailable";

        // 기간 조회·기억 관리
        public static final String INVALID_PAGE_SIZE = "Invalid page size";

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
     * @usedBy SalaryNoticeRepository
     */
    public static final class Salary {
        // 진단 문구
        public static final String DUPLICATE_NOTICE = "Salary notice identity is not unique";
        public static final String INVALID_NOTICE_TIME = "Salary notice time is invalid";
        public static final String INVALID_WRITE_COUNT = "Unexpected salary notice write count";
        public static final String NOTICE_NOT_STORED = "Salary notice was not stored";
        public static final String NOTICE_SETUP_REQUIRED =
            "Salary notice migration and permissions are required";
        public static final String AUTH_TRANSACTION_REQUIRED =
            "Salary notices require an authenticated transaction";
        public static final String TRANSACTION_MISMATCH = "Salary notice transaction differs";
        public static final String OWNER_MISMATCH = "Salary notice owner differs";

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
        // 진단 문구
        public static final String ARGUMENTS_UNSUPPORTED = "Arguments are not supported";
        public static final String INVALID_PROVISION_INPUT = "Invalid provisioning input";
        public static final String SOURCE_DIRECTORIES_REQUIRED = "Expected Java source directories";
        public static final String JDK_REQUIRED = "JDK 21 compiler required";
        public static final String SOURCE_NOT_FOUND = "No API Java source";
        public static final String MISSING_JAVADOC = " missing purpose/Javadoc";
        public static final String INVALID_CREATED_TAG = " expected exactly one @created";
        public static final String INVALID_DATE_FORMAT = "Invalid date format";
        public static final String INVALID_CREATED_DATE =
            " invalid @created date or unknown reason";
        public static final String INVALID_USED_BY_TAG = " missing or empty @usedBy";
        public static final String INVALID_MODIFIED_TAG = " invalid @modified date/reason";
        public static final String MODIFIED_BEFORE_CREATION = " modification precedes creation";
        public static final String INVALID_MODIFIED_DATE = " invalid modification date";

        /**
         * 개발 도구 상수 구간의 인스턴스 생성을 막는다.
         * @created 2026-11-02
         * @usedBy 없음: 정적 상수 전용 타입의 인스턴스화 차단
         */
        private Tools() {
        }
    }
}
