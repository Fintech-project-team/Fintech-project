package com.payse.api.salary.controller;

import com.payse.api.ApiTestConstants.SalaryCodes;
import com.payse.api.ApiTestConstants.SalaryConfig;
import com.payse.api.ApiTestConstants.SalaryFields;
import com.payse.api.ApiTestConstants.SalaryHttp;
import com.payse.api.ApiTestConstants.SalaryPaths;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.payse.api.PayseApiApplication;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.salary.mapper.SalaryNoticeRepository;
import com.payse.api.salary.vo.SalaryMonth;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 격리 PostgreSQL과 실제 HTTP에서 회차별 안내 저장·재로그인·원천 보존·실패를 검증한다.
 * @created 2026-10-30
 * @usedBy test_salary_notice_service.py의 Gradle JUnit
 */
class SalaryNoticeHttpTest {
    private final JsonMapper json = JsonMapper.builder().build();
    private ConfigurableApplicationContext context;
    private HikariDataSource adminPool;
    private JdbcTemplate admin;
    private HttpClient client;
    private Map<String, Object> properties;
    private String base;
    private String token;
    private String code;
    private UUID owner;
    private String month;
    private JsonNode source;
    private JsonNode credentials;
    private Map<String, String> financialBefore;

    /**
     * 기존 서버 주소를 허용하지 않고 전용 실행기가 만든 폐기 DB 환경만 받는다.
     * @created 2026-10-30
     * @usedBy JUnit BeforeAll
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     */
    @BeforeAll
    static void requireDatabase() {
        boolean missingEnvironment = System.getenv()
            .keySet()
            .stream()
            .noneMatch(key -> key.startsWith("PAYSE_SALARY_TEST_"));
        assumeFalse(
            missingEnvironment,
            "Run test_salary_notice_service.py with a new isolated PostgreSQL directory"
        );
        assertTrue(
            setting("JDBC_URL")
                .matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_salary")
        );
        assertTrue(setting("DB_USER").matches("payse_salary_[0-9a-f]{32}"));
        assertTrue(setting("ADMIN_USER").matches("payse_salary_setup_[0-9a-f]{32}"));
    }

    /**
     * 일부 환경만 전달된 검사를 건너뛰지 않고 준비 오류로 표시한다.
     * @created 2026-10-30
     * @usedBy requireDatabase, start
     */
    private static String setting(String name) {
        String value = System.getenv("PAYSE_SALARY_TEST_" + name);
        assertTrue(value != null && !value.isBlank(), "Missing isolated salary setting: " + name);
        return value;
    }

    /**
     * 준비 fixture의 사용자·회차 관계를 확인하고 별도 DB·서버·합성 인증을 준비한다.
     * @created 2026-10-30
     * @usedBy JUnit BeforeEach
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리
     */
    @BeforeEach
    void start() throws Exception {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(setting("JDBC_URL"));
        config.setUsername(setting("ADMIN_USER"));
        config.setPassword(setting("ADMIN_PASSWORD"));
        config.setMaximumPoolSize(3);
        adminPool = new HikariDataSource(config);
        admin = new JdbcTemplate(adminPool);
        assertEquals(
            "payse_auth_test_salary",
            admin.queryForObject("SELECT current_database()", String.class)
        );
        admin.execute("TRUNCATE payse.users CASCADE");
        admin.execute("TRUNCATE payse.auth_rate_limits");
        admin.execute(Files.readString(Path.of(setting("SEED_FILE"))));
        source = json
            .readTree(Files.readString(Path.of("fixtures/generated/snapshots/alpha-ready.json")));
        owner = UUID.fromString(source.path(SalaryFields.USER_ID).asString());
        // 회차는 명시한 검사 입력이다. 비어 있을 수 있는 원천에서 날짜로 추정하지 않는다.
        month = "2026-10";
        assertTrue(
            source.path(SalaryFields.SETTINGS)
                .path(SalaryFields.SALARY)
                .path(SalaryFields.RECEIPT_EVIDENCE)
                .isArray()
        );
        assertEquals(
            1,
            admin
                .queryForObject("SELECT count(*) FROM payse.users WHERE id=?", Integer.class, owner)
        );
        credentials = credentials(owner);
        SecureRandom random = new SecureRandom();
        properties = new HashMap<>();
        properties.put(SalaryConfig.SERVER_PORT, "0");
        properties.put(SalaryConfig.SERVER_ADDRESS, "127.0.0.1");
        properties.put(SalaryConfig.BANNER_MODE, "off");
        properties.put(SalaryConfig.PAYSE_AUTH_PEER_MODE, "direct");
        properties.put(SalaryConfig.PAYSE_JDBC_URL, setting("JDBC_URL"));
        properties.put(SalaryConfig.PAYSE_DB_USER, setting("DB_USER"));
        properties.put(SalaryConfig.PAYSE_DB_PASSWORD, setting("DB_PASSWORD"));
        properties.put(SalaryConfig.PAYSE_DB_MAX_POOL_SIZE, "6");
        properties.put(SalaryConfig.PAYSE_DB_CONNECTION_TIMEOUT_MS, "5000");
        properties.put(SalaryConfig.PAYSE_DB_VALIDATION_TIMEOUT_MS, "1000");
        properties.put(SalaryConfig.PAYSE_AUTH_CODE_KEY_ID, "salary-test");
        var secretProperties = List.of(
            SalaryConfig.PAYSE_AUTH_CODE_KEY_BASE64,
            SalaryConfig.PAYSE_AUTH_LIMIT_KEY_BASE64,
            SalaryConfig.PAYSE_FINANCE_CURSOR_KEY_BASE64
        );
        for (String key : secretProperties) {
            byte[] bytes = new byte[32];
            random.nextBytes(bytes);
            properties.put(key, Base64.getEncoder().encodeToString(bytes));
        }
        launch(true);
        code = String.format(java.util.Locale.ROOT, "%06d", random.nextInt(1_000_000));
        setCode(owner, code);
        client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
        token = login(credentials, code);
        financialBefore = fingerprint();
    }

    /**
     * 같은 설정으로 서버를 재시작해도 DB 안내 기록을 초기화하지 않는다.
     * @created 2026-10-30
     * @usedBy start, persistenceAndRestart, disabledProfile
     */
    private void launch(boolean notices) {
        SpringApplication app = new SpringApplication(PayseApiApplication.class);
        app.setAdditionalProfiles(
            notices ? new String[] {
                "database",
                "auth",
                "finance",
                "salary-notices"
            }
                : new String[] {
                    "database",
                    "auth",
                    "finance"
                }
        );
        app.setDefaultProperties(properties);
        context = app.run();
        base = "http://127.0.0.1:"
            + ((WebServerApplicationContext) context).getWebServer().getPort();
    }

    /**
     * 테스트 대상 사용자 ID에 정확히 대응하는 합성 로그인 자료 한 건을 찾는다.
     * @created 2026-10-30
     * @usedBy start, isolatesUsers
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private JsonNode credentials(UUID user) throws Exception {
        JsonNode users = json
            .readTree(Files.readString(Path.of("fixtures/generated/server-seeds.json")))
            .path(SalaryFields.USERS);
        List<JsonNode> matches = new ArrayList<>();
        users.forEach(
            value -> {
                if (user.toString().equals(value.path(SalaryFields.USER_ID).asString())) {
                    matches.add(value);
                }
            }
        );
        assertEquals(1, matches.size(), "Fixture owner relation must be unique");
        return matches.getFirst();
    }

    /**
     * 폐기 DB에서만 계정별 임시 인증 코드를 설정한다.
     * @created 2026-10-30
     * @usedBy start, isolatesUsers
     */
    private void setCode(UUID user, String value) {
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.users SET code_verifier=? WHERE id=?",
                context.getBean(AuthCrypto.class).codeVerifier(user, value),
                user
            )
        );
    }

    /**
     * 준비된 합성 정보로 실제 로그인 API를 호출하며 토큰을 파일에 저장하지 않는다.
     * @created 2026-10-30
     * @usedBy start, persistenceAndRestart, isolatesUsers
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private String login(JsonNode account, String value) throws Exception {
        String body = json.createObjectNode()
            .put(SalaryFields.NAME, account.path(SalaryFields.NAME).asString())
            .put(SalaryFields.PHONE, account.path(SalaryFields.PHONE).asString())
            .put(SalaryFields.CODE, value)
            .toString();
        var response = send(SalaryHttp.POST, SalaryPaths.SESSIONS_PATH, body, null);
        assertEquals(201, response.statusCode());
        return json.readTree(response.body())
            .path(SalaryFields.ACCESS_TOKEN)
            .asString();
    }

    /**
     * 원천·설정·금융 버전과 금융 영수증을 모두 보존하는지 확인할 지문을 만든다.
     * @created 2026-10-30
     * @usedBy start, stop, lateSourceAndSettingChange
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private Map<String, String> fingerprint() {
        Map<String, String> hashes = new HashMap<>();
        for (String table : List.of(
            "source_contexts",
            "financial_accounts",
            "financial_cards",
            "financial_transactions",
            "card_statements",
            "statement_items",
            "user_attributes",
            "institution_links",
            SalaryFields.OBLIGATIONS,
            "reserves",
            "reserve_allocations",
            "write_receipts"
        )) {
            hashes.put(
                table,
                admin.queryForObject(
                    "SELECT md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
                        + "FROM (SELECT to_jsonb(record)::text value FROM payse." + table
                        + " record) rows",
                    String.class
                )
            );
        }
        hashes.put(
            SalaryFields.VERSIONS,
            admin.queryForObject(
                "SELECT string_agg(id::text||':'||data_version::text,',' ORDER BY id) FROM payse.users",
                String.class
            )
        );
        return hashes;
    }

    /**
     * 모든 HTTP 검사에서 금융 데이터 불변을 확인하고 직접 만든 자원만 닫는다.
     * @created 2026-10-30
     * @usedBy JUnit AfterEach
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @AfterEach
    void stop() throws Exception {
        try {
            if (financialBefore != null) {
                assertEquals(financialBefore, fingerprint(), "Financial data changed");
            }
        } finally {
            if (client != null) {
                client.close();
            }
            if (context != null) {
                context.close();
            }
            if (adminPool != null) {
                try {
                    // 검사별 불변 대조 이후 준비용 코드·명시 원천 변경만 원래 합성 시드로 복원한다.
                    admin.execute("TRUNCATE payse.users CASCADE");
                    admin.execute("TRUNCATE payse.auth_rate_limits");
                    admin.execute(Files.readString(Path.of(setting("SEED_FILE"))));
                } finally {
                    adminPool.close();
                }
            }
        }
    }

    /**
     * 실제 loopback HTTP 응답에서 캐시 금지·쿠키 미발급을 함께 확인한다.
     * @created 2026-10-30
     * @usedBy login 및 모든 HTTP 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private HttpResponse<String> send(String method, String path, String body, String bearer)
        throws Exception {
        var request = HttpRequest.newBuilder(URI.create(base + path))
            .timeout(Duration.ofSeconds(20));
        if (bearer != null) {
            request.header(SalaryHttp.AUTHORIZATION, SalaryHttp.BEARER_PREFIX + bearer);
        }
        request.header(SalaryHttp.CONTENT_TYPE, SalaryHttp.JSON_UTF8);
        request.method(
            method,
            body == null ? HttpRequest.BodyPublishers.noBody()
                : HttpRequest.BodyPublishers.ofString(body)
        );
        var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertTrue(
            response.headers()
                .allValues(SalaryHttp.SET_COOKIE)
                .isEmpty()
        );
        return response;
    }

    /**
     * 성공 본문과 보안 헤더를 확인하고 반환한다.
     * @created 2026-10-30
     * @usedBy 정상 상태·중복·재로그인 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private JsonNode ok(String method, String path) throws Exception {
        var response = send(method, path, null, token);
        assertEquals(200, response.statusCode(), response.body());
        assertEquals(
            SalaryHttp.NO_STORE,
            response.headers()
                .firstValue(SalaryHttp.CACHE_CONTROL)
                .orElse("")
        );
        return json.readTree(response.body());
    }

    /**
     * 오류 봉투와 상태를 검사하며 내부 SQL이나 세션 토큰이 노출되지 않는지 확인한다.
     * @created 2026-10-30
     * @usedBy inputAndAuthentication, rollbackAndFailure
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private void error(HttpResponse<String> response, int status, String errorCode) {
        assertEquals(status, response.statusCode(), response.body());
        assertEquals(
            errorCode,
            json.readTree(response.body())
                .path(SalaryFields.ERROR)
                .path(SalaryFields.CODE)
                .asString()
        );
        assertEquals(
            SalaryHttp.NO_STORE,
            response.headers()
                .firstValue(SalaryHttp.CACHE_CONTROL)
                .orElse("")
        );
        assertFalse(response.body().contains(token));
        assertFalse(response.body().contains("SELECT "));
    }

    /**
     * 안내 닫기 전후 전체 Snapshot·기존 cursor·원천·버전이 그대로인지 검사한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void preservesFinancialContract() throws Exception {
        JsonNode before = ok(SalaryHttp.GET, SalaryPaths.SNAPSHOT_PATH);
        JsonNode initial = ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month);
        assertFalse(initial.path(SalaryFields.DISMISSED).asBoolean());
        assertTrue(initial.path(SalaryFields.DISMISSED_AT).isNull());
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.salary_notice_dismissals",
                Integer.class
            )
        );
        JsonNode saved = ok(
            SalaryHttp.PUT,
            SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX
        );
        assertEquals(
            SalaryCodes.SALARY_NOTICE_CONTRACT,
            saved.path(SalaryFields.CONTRACT_VERSION).asString()
        );
        assertEquals(owner.toString(), saved.path(SalaryFields.USER_ID).asString());
        assertTrue(saved.path(SalaryFields.DISMISSED).asBoolean());
        assertEquals(saved, ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month));
        assertEquals(
            saved,
            ok(
                SalaryHttp.PUT,
                SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX
            )
        );
        ObjectNode beforeComparable = (ObjectNode) before.deepCopy();
        ObjectNode afterComparable = (ObjectNode) ok(SalaryHttp.GET, SalaryPaths.SNAPSHOT_PATH)
            .deepCopy();
        // cursor 암호화 nonce만 매 조회 달라진다. 금융 내용은 동일하고 기존 cursor는 계속 유효해야 한다.
        ((ObjectNode) beforeComparable.get(SalaryFields.PAGE)).remove(SalaryFields.NEXT_CURSOR);
        ((ObjectNode) afterComparable.get(SalaryFields.PAGE)).remove(SalaryFields.NEXT_CURSOR);
        assertEquals(beforeComparable, afterComparable);
        JsonNode cursor = before.path(SalaryFields.PAGE).path(SalaryFields.NEXT_CURSOR);
        assertTrue(cursor.isString(), "Fixture must include a following transaction page");
        assertEquals(
            200,
            send(
                SalaryHttp.GET,
                SalaryPaths.TRANSACTION_CURSOR_PATH + cursor.asString(),
                null,
                token
            ).statusCode()
        );
    }

    /**
     * 응답을 받지 못한 재전송·로그아웃·재로그인·서버 재시작 후 최초 저장을 유지한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void persistenceAndRestart() throws Exception {
        assertEquals(
            200,
            send(
                SalaryHttp.PUT,
                SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX,
                null,
                token
            ).statusCode()
        );
        JsonNode saved = ok(
            SalaryHttp.PUT,
            SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX
        );
        String previousToken = token;
        assertEquals(
            204,
            send(SalaryHttp.DELETE, SalaryPaths.CURRENT_SESSION_PATH, null, token).statusCode()
        );
        error(
            send(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month, null, previousToken),
            401,
            SalaryCodes.SESSION_INVALID
        );
        token = login(credentials, code);
        assertEquals(saved, ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month));
        context.close();
        context = null;
        launch(true);
        assertEquals(saved, ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month));
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.salary_notice_dismissals",
                Integer.class
            )
        );
    }

    /**
     * 원천 없는 회차도 저장하되 이후 근거·설정 변화로 같은 회차의 닫기를 취소하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void lateSourceAndSettingChange() throws Exception {
        String laterMonth = "2026-11";
        assertEquals(
            0,
            admin.queryForObject(
                """
            SELECT count(*)
            FROM payse.source_contexts c, jsonb_array_elements(c.salary_evidence) proof
            WHERE c.user_id = ? AND proof->>'payMonth' = ?
            """,
                Integer.class,
                owner,
                laterMonth
            )
        );
        JsonNode saved = ok(
            SalaryHttp.PUT,
            SalaryPaths.SALARY_NOTICE_PATH + laterMonth + SalaryPaths.DISMISSAL_SUFFIX
        );
        assertFalse(
            ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month)
                .path(SalaryFields.DISMISSED)
                .asBoolean()
        );
        // 날짜가 이전 달이어도 명목 회차를 그대로 연결한다. 이는 명시한 합성 원천 준비다.
        String proof = """
            [{"payMonth":"2026-11","expectedPayDate":"2026-10-30","confirmation":"unknown","transactionIds":[]}]
            """;
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.source_contexts SET salary_evidence=salary_evidence||?::jsonb WHERE user_id=?",
                proof,
                owner
            )
        );
        assertEquals(
            1,
            admin.update("UPDATE payse.user_attributes SET salary_day=27 WHERE user_id=?", owner)
        );
        financialBefore = fingerprint();
        assertEquals(saved, ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + laterMonth));
        assertEquals(
            saved,
            ok(
                SalaryHttp.PUT,
                SalaryPaths.SALARY_NOTICE_PATH + laterMonth + SalaryPaths.DISMISSAL_SUFFIX
            )
        );
        assertFalse(
            ok(SalaryHttp.GET, "/salary-notices/2026-12")
                .path(SalaryFields.DISMISSED)
                .asBoolean()
        );
    }

    /**
     * 동일한 예정일을 가진 서로 다른 명목 급여 회차의 안내는 독립적으로 유지한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void separatesMonthsWithSameDate() throws Exception {
        String proofs = """
            [{"payMonth":"2027-01","expectedPayDate":"2027-01-25","confirmation":"unknown","transactionIds":[]},
             {"payMonth":"2027-02","expectedPayDate":"2027-01-25","confirmation":"unknown","transactionIds":[]}]
            """;
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.source_contexts SET salary_evidence=salary_evidence||?::jsonb WHERE user_id=?",
                proofs,
                owner
            )
        );
        financialBefore = fingerprint();
        ok(SalaryHttp.PUT, "/salary-notices/2027-01/dismissal");
        assertFalse(
            ok(SalaryHttp.GET, "/salary-notices/2027-02")
                .path(SalaryFields.DISMISSED)
                .asBoolean()
        );
        assertTrue(
            ok(SalaryHttp.GET, "/salary-notices/2027-01")
                .path(SalaryFields.DISMISSED)
                .asBoolean()
        );
    }

    /**
     * 다른 계정은 같은 회차도 접지 않은 상태이며 클라이언트 사용자 ID 주입을 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void isolatesUsers() throws Exception {
        ok(SalaryHttp.PUT, SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX);
        JsonNode foreign = json
            .readTree(Files.readString(Path.of("fixtures/generated/snapshots/beta-ready.json")));
        UUID other = UUID.fromString(foreign.path(SalaryFields.USER_ID).asString());
        assertNotEquals(owner, other);
        setCode(other, code);
        String foreignToken = login(credentials(other), code);
        var response = send(
            SalaryHttp.GET,
            SalaryPaths.SALARY_NOTICE_PATH + month,
            null,
            foreignToken
        );
        assertEquals(200, response.statusCode());
        assertFalse(
            json.readTree(response.body())
                .path(SalaryFields.DISMISSED)
                .asBoolean()
        );
        assertEquals(
            other.toString(),
            json.readTree(response.body())
                .path(SalaryFields.USER_ID)
                .asString()
        );
        error(
            send(
                SalaryHttp.GET,
                SalaryPaths.SALARY_NOTICE_PATH + month + "?userId=" + owner,
                null,
                foreignToken
            ),
            422,
            SalaryCodes.VALIDATION_FAILED
        );
        error(
            send(
                SalaryHttp.PUT,
                SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX,
                "{\"userId\":\"" + owner + "\"}",
                foreignToken
            ),
            422,
            SalaryCodes.VALIDATION_FAILED
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.salary_notice_dismissals WHERE user_id=?",
                Integer.class,
                other
            )
        );
    }

    /**
     * 인증을 입력보다 먼저 검사하고 형식·본문·허용되지 않은 날짜/키를 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void inputAndAuthentication() throws Exception {
        error(
            send(SalaryHttp.PUT, "/salary-notices/invalid/dismissal", "{}", null),
            401,
            SalaryCodes.SESSION_INVALID
        );
        for (String value : List.of(
            "2026-13",
            "0000-01",
            "2026-1",
            "2026-10-25"
        )) {
            error(
                send(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + value, null, token),
                422,
                SalaryCodes.VALIDATION_FAILED
            );
        }
        error(
            send(
                SalaryHttp.PUT,
                SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX,
                "{}",
                token
            ),
            422,
            SalaryCodes.VALIDATION_FAILED
        );
        error(
            send(
                SalaryHttp.PUT,
                SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX,
                "x".repeat(65537),
                token
            ),
            413,
            SalaryCodes.REQUEST_TOO_LARGE
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.salary_notice_dismissals",
                Integer.class
            )
        );
    }

    /**
     * 동시 닫기는 하나의 최초 기록만 남기고 모든 정상 응답의 시각이 일치한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void concurrentDismissals() throws Exception {
        CountDownLatch start = new CountDownLatch(1);
        try (var pool = Executors.newFixedThreadPool(4)) {
            List<java.util.concurrent.Future<JsonNode>> calls = new ArrayList<>();
            for (int index = 0; index < 4; index++) {
                calls.add(
                    pool.submit(
                        () -> {
                            assertTrue(start.await(5, TimeUnit.SECONDS));
                            return ok(
                                SalaryHttp.PUT,
                                SalaryPaths.SALARY_NOTICE_PATH + month
                                    + SalaryPaths.DISMISSAL_SUFFIX
                            );
                        }
                    )
                );
            }
            start.countDown();
            JsonNode expected = calls.getFirst().get(20, TimeUnit.SECONDS);
            for (var call : calls) {
                assertEquals(expected, call.get(20, TimeUnit.SECONDS));
            }
        }
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.salary_notice_dismissals",
                Integer.class
            )
        );
    }

    /**
     * 저장 후 예외는 롤백하고 DB 쓰기 거절도 HTTP 성공으로 숨기지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rollbackAndFailure() throws Exception {
        AuthTransactions transactions = context.getBean(AuthTransactions.class);
        AuthRepository auth = context.getBean(AuthRepository.class);
        AuthCrypto crypto = context.getBean(AuthCrypto.class);
        SalaryNoticeRepository notices = context.getBean(SalaryNoticeRepository.class);
        assertThrows(
            IllegalStateException.class,
            () -> transactions.run(
                () -> {
                    assertEquals(
                        owner,
                        auth.authorize(crypto.tokenDigest(token))
                            .orElseThrow()
                            .userId()
                    );
                    notices.dismiss(owner, new SalaryMonth(month));
                    throw new IllegalStateException("Intentional isolated rollback");
                }
            )
        );
        assertFalse(
            ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month)
                .path(SalaryFields.DISMISSED)
                .asBoolean()
        );
        admin.execute(
            "ALTER TABLE payse.salary_notice_dismissals ADD CONSTRAINT isolated_reject CHECK (false) NOT VALID"
        );
        try {
            error(
                send(
                    SalaryHttp.PUT,
                    SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX,
                    null,
                    token
                ),
                503,
                SalaryCodes.TEMPORARILY_UNAVAILABLE
            );
            assertFalse(
                ok(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month)
                    .path(SalaryFields.DISMISSED)
                    .asBoolean()
            );
        } finally {
            admin.execute(
                "ALTER TABLE payse.salary_notice_dismissals DROP CONSTRAINT isolated_reject"
            );
        }
        assertTrue(
            ok(
                SalaryHttp.PUT,
                SalaryPaths.SALARY_NOTICE_PATH + month + SalaryPaths.DISMISSAL_SUFFIX
            )
                .path(SalaryFields.DISMISSED)
                .asBoolean()
        );
    }

    /**
     * 새 기능을 켜지 않은 서버는 새 경로를 열지 않으며 기존 금융 조회는 계속 제공한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void disabledProfile() throws Exception {
        context.close();
        context = null;
        launch(false);
        assertEquals(
            401,
            send(SalaryHttp.GET, SalaryPaths.SALARY_NOTICE_PATH + month, null, token).statusCode()
        );
        assertEquals(
            SalaryCodes.API_V3,
            ok(SalaryHttp.GET, SalaryPaths.SNAPSHOT_PATH)
                .path(SalaryFields.SCHEMA_VERSION)
                .asString()
        );
    }
}
