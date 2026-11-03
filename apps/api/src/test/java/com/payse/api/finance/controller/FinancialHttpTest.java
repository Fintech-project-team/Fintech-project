package com.payse.api.finance.controller;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.payse.api.ApiTestConstants.FinanceCodes;
import com.payse.api.ApiTestConstants.FinanceConfig;
import com.payse.api.ApiTestConstants.FinanceFields;
import com.payse.api.ApiTestConstants.FinanceHttp;
import com.payse.api.ApiTestConstants.FinancePaths;
import com.payse.api.PayseApiApplication;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.entity.AccountEntity;
import com.payse.api.finance.mapper.FinancialRepository;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import jakarta.persistence.EntityManager;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.function.Predicate;
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
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 HTTP·최소 권한 PostgreSQL로 금융 조회·설정·경합·롤백과 원천 보존을 확인한다.
 * @created 2026-10-29
 * @usedBy test_financial_service.py가 실행하는 Gradle JUnit
 */
class FinancialHttpTest {
    private final JsonMapper json = JsonMapper.builder().build();
    private ConfigurableApplicationContext context;
    private HikariDataSource adminPool;
    private JdbcTemplate admin;
    private HttpClient client;
    private String base;
    private String token;
    private String code;
    private UUID owner;
    private JsonNode source;
    private JsonNode foreignSource;
    private JsonNode credentials;
    private Map<String, String> sourceBefore;

    /**
     * 전용 실행기가 만든 금융 테스트 DB와 분리된 역할 외 연결은 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit BeforeAll
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     */
    @BeforeAll
    static void requireDatabase() {
        boolean missingEnvironment = System.getenv()
            .keySet()
            .stream()
            .noneMatch(key -> key.startsWith("PAYSE_FINANCIAL_TEST_"));
        assumeFalse(
            missingEnvironment,
            "Run test_financial_service.py with a new isolated PostgreSQL directory"
        );
        assertTrue(
            setting("JDBC_URL")
                .matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_financial")
        );
        assertTrue(setting("DB_USER").matches("payse_financial_[0-9a-f]{32}"));
        assertTrue(setting("ADMIN_USER").matches("payse_financial_setup_[0-9a-f]{32}"));
    }

    /**
     * 부분 지정된 검사 자격은 건너뛰지 않고 실패시킨다.
     * @created 2026-10-29
     * @usedBy requireDatabase, start
     */
    private static String setting(String name) {
        String value = System.getenv("PAYSE_FINANCIAL_TEST_" + name);
        assertTrue(
            value != null && !value.isBlank(),
            "Missing isolated financial setting: " + name
        );
        return value;
    }

    /**
     * 폐기용 DB만 초기화하고 실제 원천·설정 시나리오와 임시 서버를 준비한다.
     * @created 2026-10-29
     * @usedBy JUnit BeforeEach
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리
     * @modified 2026-11-03 - 합성 원천 준비에만 별도 제한과 통계 갱신 적용; 준비 파일 명시
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
            "payse_auth_test_financial",
            admin.queryForObject("SELECT current_database()", String.class)
        );
        // 전용 실행기가 만든 DB에서만 각 검사를 독립 준비한다. 기관 기준정보는 유지한다.
        admin.execute("TRUNCATE payse.users CASCADE");
        admin.execute("TRUNCATE payse.auth_rate_limits");
        prepareSeed("SEED_FILE");
        source = json
            .readTree(Files.readString(Path.of("fixtures/generated/snapshots/alpha-ready.json")));
        foreignSource = json
            .readTree(Files.readString(Path.of("fixtures/generated/snapshots/beta-ready.json")));
        owner = UUID.fromString(source.get(FinanceFields.USER_ID).asString());
        JsonNode users = json
            .readTree(Files.readString(Path.of("fixtures/generated/server-seeds.json")))
            .get(FinanceFields.USERS);
        credentials = single(
            users,
            entry -> entry.get(FinanceFields.USER_ID).equals(source.get(FinanceFields.USER_ID))
        );
        assertEquals(
            1,
            admin
                .queryForObject("SELECT count(*) FROM payse.users WHERE id=?", Integer.class, owner)
        );
        assertEquals(
            source.get(FinanceFields.ACCOUNTS).size(),
            admin.queryForObject(
                "SELECT count(*) FROM payse.financial_accounts WHERE user_id=?",
                Integer.class,
                owner
            )
        );

        SecureRandom random = new SecureRandom();
        Map<String, Object> properties = new HashMap<>();
        properties.put(FinanceConfig.SERVER_PORT, "0");
        properties.put(FinanceConfig.SERVER_ADDRESS, "127.0.0.1");
        properties.put(FinanceConfig.BANNER_MODE, "off");
        properties.put(FinanceConfig.PAYSE_AUTH_PEER_MODE, "direct");
        properties.put(FinanceConfig.PAYSE_JDBC_URL, setting("JDBC_URL"));
        properties.put(FinanceConfig.PAYSE_DB_USER, setting("DB_USER"));
        properties.put(FinanceConfig.PAYSE_DB_PASSWORD, setting("DB_PASSWORD"));
        properties.put(FinanceConfig.PAYSE_DB_MAX_POOL_SIZE, "6");
        properties.put(FinanceConfig.PAYSE_DB_CONNECTION_TIMEOUT_MS, "5000");
        properties.put(FinanceConfig.PAYSE_DB_VALIDATION_TIMEOUT_MS, "1000");
        properties.put(FinanceConfig.PAYSE_AUTH_CODE_KEY_ID, "financial-test");
        var secretProperties = List.of(
            FinanceConfig.PAYSE_AUTH_CODE_KEY_BASE64,
            FinanceConfig.PAYSE_AUTH_LIMIT_KEY_BASE64,
            FinanceConfig.PAYSE_FINANCE_CURSOR_KEY_BASE64
        );
        for (String key : secretProperties) {
            byte[] bytes = new byte[32];
            random.nextBytes(bytes);
            properties.put(key, Base64.getEncoder().encodeToString(bytes));
        }

        SpringApplication app = new SpringApplication(PayseApiApplication.class);
        app.setAdditionalProfiles("database", "auth", "finance");
        app.setDefaultProperties(properties);
        context = app.run();
        base = "http://127.0.0.1:"
            + ((WebServerApplicationContext) context).getWebServer().getPort();
        code = String.format(java.util.Locale.ROOT, "%06d", random.nextInt(1_000_000));
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.users SET code_verifier=? WHERE id=?",
                context.getBean(AuthCrypto.class).codeVerifier(owner, code),
                owner
            )
        );
        client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();
        token = login();
        sourceBefore = fingerprint();
    }

    /**
     * 연간 자료 준비의 통계·제약 검사를 마친 뒤 제품 요청 제한으로 복구한다.
     * @created 2026-11-03
     * @usedBy start, gammaImport
     * @modified 2026-11-03 - 일반 사례와 감마 미연결 원천의 준비 파일을 명시 선택
     */
    private void prepareSeed(String fileSetting) throws Exception {
        String seed = Files.readString(Path.of(setting(fileSetting)));
        var boundary = java.util.regex.Pattern.compile("(?m)^SET CONSTRAINTS ALL IMMEDIATE;\\r?$");
        assertEquals(
            1L,
            boundary.matcher(seed)
                .results()
                .count(),
            "Expected one final seed validation boundary"
        );
        String prepared = boundary.matcher(seed).replaceFirst("ANALYZE;\n$0");
        admin.execute(
            (org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
                try (var statement = connection.createStatement()) {
                    statement.execute("SET statement_timeout = '120s'");
                    try {
                        statement.execute(prepared);
                    } finally {
                        statement.execute("ROLLBACK");
                        statement.execute("SET statement_timeout = '12s'");
                    }
                }

                return null;
            }
        );
    }

    /**
     * 모든 검사에서 원천 불변을 확인하고 자신이 만든 연결·서버만 닫는다.
     * @created 2026-10-29
     * @usedBy JUnit AfterEach
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @AfterEach
    void stop() {
        try {
            if (sourceBefore != null) {
                assertEquals(sourceBefore, fingerprint(), "Financial source facts changed");
            }
        } finally {
            if (client != null) {
                client.close();
            }
            if (context != null) {
                context.close();
            }
            if (adminPool != null) {
                adminPool.close();
            }
        }
    }

    /**
     * 표기명·첫 행 대신 검증된 단일 관계로 검사 대상을 찾는다.
     * @created 2026-10-29
     * @usedBy start, account, changed, historyProtection
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private JsonNode single(JsonNode array, Predicate<JsonNode> matches) {
        List<JsonNode> found = new ArrayList<>();
        array.forEach(
            value -> {
                if (matches.test(value)) {
                    found.add(value);
                }
            }
        );
        assertEquals(1, found.size(), "Fixture relationship must identify exactly one object");
        return found.getFirst();
    }

    /**
     * 급여 설정이 가리키는 실제 소유 계좌 관계를 확인한다.
     * @created 2026-10-29
     * @usedBy 설정·의무·보호금 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private JsonNode account() {
        JsonNode id = source.get(FinanceFields.SETTINGS)
            .get(FinanceFields.SALARY)
            .get(FinanceFields.SALARY_ACCOUNT_ID);
        return single(
            source.get(FinanceFields.ACCOUNTS),
            value -> value.get(FinanceFields.ACCOUNT_ID).equals(id)
        );
    }

    /**
     * 명시한 성공 영수증의 대상 하나를 확인하고 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy createObligation, createReserve
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private String changed(JsonNode result, String resource) {
        return single(
            result.get(FinanceFields.RECEIPT).get(FinanceFields.CHANGED_REFS),
            ref -> resource.equals(ref.path(FinanceFields.RESOURCE).asString())
        )
            .get(FinanceFields.ID)
            .asString();
    }

    /**
     * 원천 테이블과 계좌 원천 열의 지문을 만들며 허용 설정 열은 제외한다.
     * @created 2026-10-29
     * @usedBy start, stop
     */
    private Map<String, String> fingerprint() {
        Map<String, String> result = new HashMap<>();
        for (String table : List.of(
            "source_contexts",
            "financial_accounts",
            "financial_cards",
            "financial_transactions",
            "card_statements",
            "statement_items",
            "transaction_references",
            "transaction_relations"
        )) {
            String value = "financial_accounts".equals(table)
                ? "(to_jsonb(record)-'included'-'nickname')::text"
                : "to_jsonb(record)::text";
            result.put(
                table,
                admin.queryForObject(
                    "SELECT md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
                        + "FROM (SELECT " + value + " AS value FROM payse." + table
                        + " record) rows",
                    String.class
                )
            );
        }

        return result;
    }

    /**
     * 합성 금융 성공 응답만 격리 검사 폴더에 남겨 변경 없는 Flutter 파서와 대조한다.
     * @created 2026-10-29
     * @usedBy snapshotAndPages, unconnectedAndConsent, accountAndSettings
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private void capture(String name, JsonNode response) throws Exception {
        assertTrue(name.matches("[a-z-]+"));
        Path directory = Path.of(setting("RESPONSE_DIR"))
            .toAbsolutePath()
            .normalize();
        assertEquals(
            Path.of(setting("SEED_FILE"))
                .toAbsolutePath()
                .normalize()
                .getParent()
                .resolve("public-responses"),
            directory
        );
        assertTrue(response.isObject());
        assertFalse(response.has(FinanceFields.ACCESS_TOKEN));
        assertFalse(response.has(FinanceFields.PHONE));
        Files.writeString(
            directory.resolve(name + ".json"),
            json.writerWithDefaultPrettyPrinter().writeValueAsString(response)
        );
    }

    /**
     * 실제 현재 사용자 버전으로 금융 쓰기 공통 필드를 준비한다.
     * @created 2026-10-29
     * @usedBy 금융 쓰기 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode command() {
        return json.createObjectNode()
            .put(FinanceFields.EXPECTED_DATA_VERSION, version())
            .put(FinanceFields.RULE_VERSION, FinanceCodes.CALCULATION_RULES)
            .put(FinanceFields.IDEMPOTENCY_KEY, UUID.randomUUID().toString());
    }

    /**
     * 기대 버전은 검사 대상의 응답을 복사하지 않고 저장된 사용자 버전에서 읽는다.
     * @created 2026-10-29
     * @usedBy command, 경합·롤백 검사
     */
    private String version() {
        return admin.queryForObject(
            "SELECT data_version::text FROM payse.users WHERE id=?",
            String.class,
            owner
        );
    }

    /**
     * 실제 loopback 서버에 요청하고 금융 응답의 보안 헤더를 확인한다.
     * @created 2026-10-29
     * @usedBy API 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private HttpResponse<String> send(
        String method,
        String path,
        String body,
        String bearer,
        Map<String, String> headers
    )
        throws Exception {
        var request = HttpRequest.newBuilder(URI.create(base + path))
            .timeout(Duration.ofSeconds(20));
        request.header(FinanceHttp.CONTENT_TYPE, FinanceHttp.JSON_UTF8);
        if (bearer != null) {
            request.header(FinanceHttp.AUTHORIZATION, FinanceHttp.BEARER_PREFIX + bearer);
        }
        headers.forEach(request::header);
        request.method(
            method,
            body == null ? HttpRequest.BodyPublishers.noBody()
                : HttpRequest.BodyPublishers.ofString(body)
        );
        var result = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertEquals(
            FinanceHttp.NO_STORE,
            result.headers()
                .firstValue(FinanceHttp.CACHE_CONTROL)
                .orElse("")
        );
        assertTrue(
            result.headers()
                .allValues(FinanceHttp.SET_COOKIE)
                .isEmpty()
        );
        return result;
    }

    /**
     * 현재 사용자 요청을 보내며 본문 null과 생략을 구분한다.
     * @created 2026-10-29
     * @usedBy API 검사
     */
    private HttpResponse<String> send(String method, String path, JsonNode body) throws Exception {
        return send(method, path, body == null ? null : body.toString(), token, Map.of());
    }

    /**
     * 정상 금융 응답의 상태를 확인한 뒤 JSON만 반환한다.
     * @created 2026-10-29
     * @usedBy 정상 API 검사
     */
    private JsonNode ok(String method, String path, JsonNode body) throws Exception {
        HttpResponse<String> result = send(method, path, body);
        assertEquals(200, result.statusCode());
        return json.readTree(result.body());
    }

    /**
     * 정해진 오류 코드·외부 메시지 형태와 민감 값 비노출을 확인한다.
     * @created 2026-10-29
     * @usedBy 오류·권한·충돌 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private void error(HttpResponse<String> result, int status, String code) {
        assertEquals(status, result.statusCode());
        JsonNode problem = json.readTree(result.body()).get(FinanceFields.ERROR);
        assertNotNull(problem);
        assertEquals(code, problem.path(FinanceFields.CODE).asString());
        assertDoesNotThrow(
            () -> UUID.fromString(problem.path(FinanceFields.REQUEST_ID).asString())
        );
        assertTrue(problem.path(FinanceFields.DETAILS).isArray());
        assertFalse(result.body().contains(token));
        assertFalse(result.body().contains("SELECT "));
        if (status == 401) {
            assertEquals(
                FinanceHttp.BEARER_SCHEME,
                result.headers()
                    .firstValue(FinanceHttp.WWW_AUTHENTICATE)
                    .orElse("")
            );
        }
    }

    /**
     * 사전 계정의 검증값을 실제 인증 HTTP로 대조해 세션을 얻는다.
     * @created 2026-10-29
     * @usedBy start, reloginAndCursor
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private String login() throws Exception {
        ObjectNode body = json.createObjectNode()
            .put(FinanceFields.NAME, credentials.path(FinanceFields.NAME).asString())
            .put(FinanceFields.PHONE, credentials.path(FinanceFields.PHONE).asString())
            .put(FinanceFields.CODE, code);
        var response = send(
            FinanceHttp.POST,
            FinancePaths.SESSIONS_PATH,
            body.toString(),
            null,
            Map.of()
        );
        assertEquals(201, response.statusCode());
        return json.readTree(response.body())
            .path(FinanceFields.ACCESS_TOKEN)
            .asString();
    }

    /**
     * 검사에서 새 단건 의무를 만들며 저장 ID는 성공 영수증에서 받는다.
     * @created 2026-10-29
     * @usedBy CRUD·배정·취소 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private String createObligation() throws Exception {
        ObjectNode body = command()
            .put(FinanceFields.LABEL, "확인한 정기점검")
            .put(
                FinanceFields.WITHDRAWAL_ACCOUNT_ID,
                account()
                    .path(FinanceFields.ACCOUNT_ID)
                    .asString()
            )
            .put(FinanceFields.AMOUNT_KRW, 30000)
            .put(FinanceFields.DUE_DATE, "2026-10-24");
        return changed(ok(FinanceHttp.POST, FinancePaths.OBLIGATIONS_PATH, body), "obligation");
    }

    /**
     * 세 배열을 갖춘 명시 배정 변경 객체를 만든다.
     * @created 2026-10-29
     * @usedBy createReserve, reserveChanges
     */
    private ObjectNode allocations() {
        ObjectNode changes = json.createObjectNode();
        changes.putArray("create");
        changes.putArray("update");
        changes.putArray("remove");
        return changes;
    }

    /**
     * 새 보호 설정에 선택한 의무 배정을 추가한다.
     * @created 2026-10-29
     * @usedBy reserveChanges, cancelObligation, cancelReserve
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private String createReserve(String obligation) throws Exception {
        ObjectNode body = command()
            .put(
                FinanceFields.ACCOUNT_ID,
                account()
                    .path(FinanceFields.ACCOUNT_ID)
                    .asString()
            )
            .put(FinanceFields.LABEL, "점검 준비금")
            .put(FinanceFields.AMOUNT_KRW, 50000);
        ObjectNode changes = allocations();
        if (obligation != null) {
            ((ArrayNode) changes.get("create")).addObject()
                .put(FinanceFields.OBLIGATION_ID, obligation)
                .put(FinanceFields.AMOUNT_KRW, 20000);
        }
        body.set(FinanceFields.ALLOCATION_CHANGES, changes);
        return changed(ok(FinanceHttp.POST, FinancePaths.RESERVES_PATH, body), "reserve");
    }

    /**
     * 전체 거래를 중복 없이 페이지로 제공하고 원천 사실·기준 시각을 유지한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void snapshotAndPages() throws Exception {
        JsonNode snapshot = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        assertEquals(FinanceCodes.API_V3, snapshot.path(FinanceFields.SCHEMA_VERSION).asString());
        assertEquals(owner.toString(), snapshot.path(FinanceFields.USER_ID).asString());
        assertEquals(
            source.path(FinanceFields.SOURCE_VERSION),
            snapshot.path(FinanceFields.SOURCE_VERSION)
        );
        assertEquals(
            Instant.parse("2026-10-19T03:00:00Z"),
            Instant.parse(snapshot.path(FinanceFields.AS_OF).asString())
        );
        assertEquals(
            source.path(FinanceFields.ACCOUNTS).size(),
            snapshot.path(FinanceFields.ACCOUNTS).size()
        );
        capture("full-snapshot", snapshot);
        assertEquals(
            source.path(FinanceFields.SETTINGS)
                .path(FinanceFields.SALARY)
                .path(FinanceFields.RECEIPT_EVIDENCE),
            snapshot.path(FinanceFields.SETTINGS)
                .path(FinanceFields.SALARY)
                .path(FinanceFields.RECEIPT_EVIDENCE)
        );
        Set<String> received = new HashSet<>();
        JsonNode page = snapshot;
        int pages = 0;
        while (true) {
            pages++;
            assertTrue(page.path(FinanceFields.TRANSACTIONS).size() <= 100);
            for (JsonNode transaction : page.path(FinanceFields.TRANSACTIONS)) {
                assertTrue(
                    received.add(transaction.path(FinanceFields.TRANSACTION_ID).asString()),
                    "Duplicated page transaction"
                );
                assertTrue(transaction.path(FinanceFields.AMOUNT_KRW).isIntegralNumber());
                assertFalse(transaction.has(FinanceFields.ITEMS));
            }

            JsonNode cursor = page.path(FinanceFields.PAGE).path(FinanceFields.NEXT_CURSOR);
            if (cursor.isNull()) {
                break;
            }

            assertTrue(pages < 10, "Unbounded cursor chain");
            page = ok(
                FinanceHttp.GET,
                FinancePaths.TRANSACTION_CURSOR_PATH + cursor.asString(),
                null
            );
            capture("transaction-page", page);
            assertEquals(
                snapshot.path(FinanceFields.DATA_VERSION),
                page.path(FinanceFields.DATA_VERSION)
            );
            assertFalse(page.has(FinanceFields.ACCOUNTS));
        }

        Set<String> expected = new HashSet<>();
        source.path(FinanceFields.TRANSACTIONS)
            .forEach(value -> expected.add(value.path(FinanceFields.TRANSACTION_ID).asString()));
        assertEquals(expected, received);
        assertTrue(pages >= 2);
        for (JsonNode statement : snapshot.path(FinanceFields.STATEMENTS)) {
            assertFalse(statement.has(FinanceFields.ITEMS));
        }
    }

    /**
     * 기간 첫 조회와 후속 페이지는 같은 조건에 묶이며 기존 Snapshot cursor와 교차 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @Test
    void periodPagesBindDatesAndPurpose() throws Exception {
        JsonNode snapshot = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        LocalDate end = LocalDate.parse(
            snapshot.path(FinanceFields.COVERAGE)
                .get(0)
                .path(FinanceFields.REQUESTED_END)
                .asString()
        );
        LocalDate start = end.minusYears(2);
        String period = "startDate=" + start + "&endDate=" + end;
        JsonNode page = ok(FinanceHttp.GET, "/transactions?" + period, null);
        assertEquals(
            snapshot.path(FinanceFields.SCHEMA_VERSION),
            page.path(FinanceFields.SCHEMA_VERSION)
        );
        assertEquals(snapshot.path(FinanceFields.COVERAGE), page.path(FinanceFields.COVERAGE));
        assertFalse(page.has(FinanceFields.ACCOUNTS));
        String cursor = page.path(FinanceFields.PAGE)
            .path(FinanceFields.NEXT_CURSOR)
            .asString();
        assertFalse(cursor.isBlank());
        error(
            send(
                FinanceHttp.GET,
                "/transactions?" + period + "&cursor="
                    + snapshot.path(FinanceFields.PAGE)
                        .path(FinanceFields.NEXT_CURSOR)
                        .asString(),
                null
            ),
            409,
            FinanceCodes.STALE_DATA
        );
        error(
            send(FinanceHttp.GET, FinancePaths.TRANSACTION_CURSOR_PATH + cursor, null),
            409,
            FinanceCodes.STALE_DATA
        );
        error(
            send(
                FinanceHttp.GET,
                "/transactions?startDate=" + start.plusDays(1) + "&endDate=" + end
                    + "&cursor=" + cursor,
                null
            ),
            409,
            FinanceCodes.STALE_DATA
        );
        error(
            send(FinanceHttp.GET, "/transactions?" + period + "&cursor=broken", null),
            400,
            FinanceCodes.INVALID_CURSOR
        );
        Set<String> received = new HashSet<>();
        int pages = 0;
        while (true) {
            pages++;
            assertTrue(page.path(FinanceFields.TRANSACTIONS).size() <= 100);
            for (JsonNode row : page.path(FinanceFields.TRANSACTIONS)) {
                assertTrue(received.add(row.path(FinanceFields.TRANSACTION_ID).asString()));
            }

            JsonNode next = page.path(FinanceFields.PAGE).path(FinanceFields.NEXT_CURSOR);
            if (next.isNull()) {
                break;
            }

            assertTrue(pages < 10);
            page = ok(
                FinanceHttp.GET,
                "/transactions?" + period + "&cursor=" + next.asString(),
                null
            );
        }

        Set<String> expected = new HashSet<>();
        for (String group : List
            .of(FinanceFields.TRANSACTIONS, FinanceFields.RELATED_TRANSACTIONS)) {
            source.path(group)
                .forEach(row -> expected.add(row.path(FinanceFields.TRANSACTION_ID).asString()));
        }

        assertEquals(expected, received);
        assertTrue(pages >= 2);
        assertEquals(
            204,
            send(FinanceHttp.DELETE, FinancePaths.CURRENT_SESSION_PATH, null).statusCode()
        );
        token = login();
        error(
            send(FinanceHttp.GET, "/transactions?" + period + "&cursor=" + cursor, null),
            403,
            FinanceCodes.RESOURCE_FORBIDDEN
        );
    }

    /**
     * 단일 날짜 경계를 포함하며 없는 기간은 빈 페이지, 잘못된 입력은 오류로 구분한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void periodDatesRemainExplicitAndReadOnly() throws Exception {
        JsonNode snapshot = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        LocalDate firstDay = LocalDate.parse(
            snapshot.path(FinanceFields.COVERAGE)
                .get(0)
                .path(FinanceFields.REQUESTED_START)
                .asString()
        );
        LocalDate emptyDay = firstDay.minusYears(2);
        JsonNode empty = ok(
            FinanceHttp.GET,
            "/transactions?startDate=" + emptyDay + "&endDate=" + emptyDay,
            null
        );
        assertTrue(empty.path(FinanceFields.TRANSACTIONS).isEmpty());
        assertTrue(
            empty.path(FinanceFields.PAGE)
                .path(FinanceFields.NEXT_CURSOR)
                .isNull()
        );
        assertEquals(snapshot.path(FinanceFields.COVERAGE), empty.path(FinanceFields.COVERAGE));
        for (String query : List.of(
            "startDate=2026-01-01",
            "endDate=2026-10-19",
            "startDate=2025-02-29&endDate=2026-10-19",
            "startDate=2026-10-20&endDate=2026-10-19",
            "startDate=2026-01-01&startDate=2026-01-02&endDate=2026-10-19"
        )) {
            error(
                send(FinanceHttp.GET, "/transactions?" + query, null),
                422,
                FinanceCodes.VALIDATION_FAILED
            );
        }

        error(
            send(FinanceHttp.GET, "/transactions?startDate=invalid", null, "invalid", Map.of()),
            401,
            FinanceCodes.SESSION_INVALID
        );
        assertEquals(
            snapshot.path(FinanceFields.DATA_VERSION),
            ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null).path(FinanceFields.DATA_VERSION)
        );
    }

    /**
     * 금융 저장 후에는 기간이 같아도 이전 페이지 문맥을 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void periodCursorRejectsChangedFinancialVersion() throws Exception {
        LocalDate end = LocalDate.parse(
            source.path(FinanceFields.COVERAGE)
                .get(0)
                .path(FinanceFields.REQUESTED_END)
                .asString()
        );
        String period = "startDate=" + end.minusYears(2) + "&endDate=" + end;
        String cursor = ok(FinanceHttp.GET, "/transactions?" + period, null)
            .path(FinanceFields.PAGE)
            .path(FinanceFields.NEXT_CURSOR)
            .asString();
        assertFalse(cursor.isBlank());
        ok(
            FinanceHttp.PATCH,
            FinancePaths.ACCOUNT_PATH + account()
                .path(FinanceFields.ACCOUNT_ID)
                .asString(),
            command().put(FinanceFields.NICKNAME, "기간 조회")
        );
        error(
            send(FinanceHttp.GET, "/transactions?" + period + "&cursor=" + cursor, null),
            409,
            FinanceCodes.STALE_DATA
        );
    }

    /**
     * 연결 전에는 열 개 메타 키만 반환하고 로그인 자체가 연결을 만들지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void unconnectedAndConsent() throws Exception {
        admin.update("DELETE FROM payse.institution_links WHERE user_id=?", owner);
        JsonNode first = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        assertEquals(10, first.size());
        assertTrue(first.path(FinanceFields.INSTITUTION_LINKS).isEmpty());
        assertFalse(first.has(FinanceFields.ACCOUNTS));
        capture("unconnected", first);
        ObjectNode body = command();
        body.putArray(FinanceFields.INSTITUTION_CODES)
            .add(
                account()
                    .path(FinanceFields.INSTITUTION_CODE)
                    .asString()
            );
        JsonNode connected = ok(FinanceHttp.POST, FinancePaths.INSTITUTION_LINKS_PATH, body)
            .path(FinanceFields.SNAPSHOT);
        assertEquals(2, connected.path(FinanceFields.ACCOUNTS).size());
        assertEquals(0, connected.path(FinanceFields.CARDS).size());
        assertTrue(connected.path(FinanceFields.ACCESS_RESTRICTIONS).size() > 0);
        capture("partial-bank", connected);
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.institution_links WHERE user_id=? AND disconnected_at IS NULL",
                Integer.class,
                owner
            )
        );
        JsonNode debit = single(
            source.path(FinanceFields.CARDS),
            value -> "debit".equals(value.path(FinanceFields.CARD_TYPE).asString())
        );
        ObjectNode addCard = command();
        addCard.putArray(FinanceFields.INSTITUTION_CODES)
            .add(
                account()
                    .path(FinanceFields.INSTITUTION_CODE)
                    .asString()
            )
            .add(debit.path(FinanceFields.INSTITUTION_CODE).asString());
        capture(
            "partial-bank-card",
            ok(FinanceHttp.POST, FinancePaths.INSTITUTION_LINKS_PATH, addCard)
                .path(FinanceFields.SNAPSHOT)
        );
    }

    /**
     * 감마만 연간 원천으로 준비하고 일반 로그인·기관 연결·전체 페이지·재로그인을 검사한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void gammaImport() throws Exception {
        admin.execute("TRUNCATE payse.users CASCADE");
        admin.execute("TRUNCATE payse.auth_rate_limits");
        prepareSeed("GAMMA_SEED_FILE");
        source = json.readTree(Files.readString(Path.of(setting("GAMMA_SOURCE_FILE"))));
        owner = UUID.fromString(source.path(FinanceFields.USER_ID).asString());
        JsonNode users = json
            .readTree(Files.readString(Path.of("fixtures/generated/server-seeds.json")))
            .path(FinanceFields.USERS);
        credentials = single(
            users,
            entry -> entry.path(FinanceFields.USER_ID).equals(source.path(FinanceFields.USER_ID))
        );
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.users SET code_verifier=? WHERE id=?",
                context.getBean(AuthCrypto.class).codeVerifier(owner, code),
                owner
            )
        );
        sourceBefore = fingerprint();
        Map<String, String> others = otherState();
        token = login();
        long before = Long.parseLong(version());
        JsonNode first = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        assertTrue(first.path(FinanceFields.INSTITUTION_LINKS).isEmpty());
        assertFalse(first.has(FinanceFields.ACCOUNTS));
        assertEquals(1L, before);
        capture("gamma-unconnected", first);

        ObjectNode body = command();
        ArrayNode codes = body.putArray(FinanceFields.INSTITUTION_CODES);
        source.path(FinanceFields.INSTITUTIONS)
            .forEach(institution -> codes.add(institution.path(FinanceFields.CODE).asString()));
        JsonNode connected = ok(FinanceHttp.POST, FinancePaths.INSTITUTION_LINKS_PATH, body)
            .path(FinanceFields.SNAPSHOT);
        assertEquals(Long.toString(before + 1), version());
        assertEquals(9, connected.path(FinanceFields.ACCOUNTS).size());
        assertEquals(4, connected.path(FinanceFields.CARDS).size());
        assertEquals(codes.size(), connected.path(FinanceFields.INSTITUTION_LINKS).size());
        assertEquals(
            source.path(FinanceFields.SOURCE_VERSION),
            connected.path(FinanceFields.SOURCE_VERSION)
        );
        Instant asOf = java.time.OffsetDateTime.parse(source.path(FinanceFields.AS_OF).asString())
            .toInstant();
        assertEquals(asOf, Instant.parse(connected.path(FinanceFields.AS_OF).asString()));
        for (JsonNode account : connected.path(FinanceFields.ACCOUNTS)) {
            assertFalse(account.path(FinanceFields.INCLUDED).asBoolean());
            assertEquals(asOf, Instant.parse(account.path(FinanceFields.AS_OF).asString()));
        }
        assertTrue(
            connected.path(FinanceFields.SETTINGS)
                .path(FinanceFields.SALARY)
                .path(FinanceFields.SALARY_ACCOUNT_ID)
                .isNull()
        );
        capture("gamma-connected", connected);

        Set<String> received = new HashSet<>();
        JsonNode page = connected;
        int pages = 0;
        while (true) {
            pages++;
            assertEquals(owner.toString(), page.path(FinanceFields.USER_ID).asString());
            assertEquals(
                connected.path(FinanceFields.DATA_VERSION),
                page.path(FinanceFields.DATA_VERSION)
            );
            for (JsonNode transaction : page.path(FinanceFields.TRANSACTIONS)) {
                assertTrue(received.add(transaction.path(FinanceFields.TRANSACTION_ID).asString()));
            }
            JsonNode cursor = page.path(FinanceFields.PAGE).path(FinanceFields.NEXT_CURSOR);
            if (cursor.isNull()) {
                break;
            }
            assertTrue(pages < 100, "Unbounded annual cursor chain");
            page = ok(
                FinanceHttp.GET,
                FinancePaths.TRANSACTION_CURSOR_PATH + cursor.asString(),
                null
            );
        }
        Set<String> expected = new HashSet<>();
        source.path(FinanceFields.TRANSACTIONS)
            .forEach(row -> expected.add(row.path(FinanceFields.TRANSACTION_ID).asString()));
        assertEquals(1825, received.size());
        assertEquals(expected, received);
        assertTrue(pages > 1);
        HttpResponse<String> logout = send(
            FinanceHttp.DELETE,
            FinancePaths.CURRENT_SESSION_PATH,
            null
        );
        assertEquals(204, logout.statusCode());
        token = login();
        JsonNode restored = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        for (String field : List.of(
            FinanceFields.ACCOUNTS,
            FinanceFields.INSTITUTION_LINKS,
            FinanceFields.SETTINGS,
            FinanceFields.SOURCE_VERSION
        )) {
            assertEquals(connected.path(field), restored.path(field));
        }
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.financial_transactions "
                    + "WHERE user_id=? AND payse_transaction_type IS NOT NULL",
                Integer.class,
                owner
            )
        );
        assertEquals(Long.toString(before + 1), version());
        assertEquals(others, otherState());
    }

    /**
     * 감마 이외 계정의 인증·버전·설정·연결·계좌 상태가 변하지 않았는지 대조한다.
     * @created 2026-11-03
     * @usedBy gammaImport
     */
    private Map<String, String> otherState() {
        Map<String, String> result = new HashMap<>();
        for (String table : List.of(
            "users",
            "user_attributes",
            "institution_links",
            "financial_accounts"
        )) {
            String key = "users".equals(table) ? "id" : "user_id";
            result.put(
                table,
                admin.queryForObject(
                    "SELECT md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
                        + "FROM (SELECT to_jsonb(record)::text AS value FROM payse." + table
                        + " record WHERE " + key + "<>?) rows",
                    String.class,
                    owner
                )
            );
        }
        return result;
    }

    /**
     * 사용자 선택·별칭·급여·카드 계획은 저장하고 원천 일정·잔액은 보존한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void accountAndSettings() throws Exception {
        ObjectNode selection = command();
        selection.putArray(FinanceFields.ACCOUNT_IDS)
            .add(
                account()
                    .path(FinanceFields.ACCOUNT_ID)
                    .asString()
            );
        ok(FinanceHttp.PATCH, FinancePaths.ACCOUNT_SELECTION_PATH, selection);
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.financial_accounts WHERE user_id=? AND included",
                Integer.class,
                owner
            )
        );
        ok(
            FinanceHttp.PATCH,
            FinancePaths.ACCOUNT_PATH + account()
                .path(FinanceFields.ACCOUNT_ID)
                .asString(),
            command().put(FinanceFields.NICKNAME, "급여 통장")
        );
        assertEquals(
            "급여 통장",
            admin.queryForObject(
                "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
                String.class,
                owner,
                UUID.fromString(
                    account()
                        .path(FinanceFields.ACCOUNT_ID)
                        .asString()
                )
            )
        );
        ObjectNode salary = command();
        salary.putObject(FinanceFields.SALARY)
            .put(FinanceFields.SALARY_DAY, 31)
            .put(FinanceFields.SALARY_AMOUNT_KRW, 3200000)
            .put(
                FinanceFields.SALARY_ACCOUNT_ID,
                account()
                    .path(FinanceFields.ACCOUNT_ID)
                    .asString()
            );
        JsonNode saved = ok(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, salary)
            .path(FinanceFields.SNAPSHOT);
        assertEquals(
            31,
            saved.path(FinanceFields.SETTINGS)
                .path(FinanceFields.SALARY)
                .path(FinanceFields.SALARY_DAY)
                .intValue()
        );
        capture("postwrite", saved);
        JsonNode card = single(
            source.path(FinanceFields.CARDS),
            value -> "debit".equals(value.path(FinanceFields.CARD_TYPE).asString())
        );
        ObjectNode plan = command();
        plan.putArray(FinanceFields.CARD_PLANS)
            .addObject()
            .put(FinanceFields.CARD_ID, card.path(FinanceFields.CARD_ID).asString())
            .put(FinanceFields.PLANNED_PAYMENT_DAY, 29);
        ok(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, plan);
        ObjectNode clear = command();
        clear.putArray(FinanceFields.CARD_PLANS)
            .addObject()
            .put(FinanceFields.CARD_ID, card.path(FinanceFields.CARD_ID).asString())
            .putNull(FinanceFields.PLANNED_PAYMENT_DAY);
        ok(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, clear);
        ok(
            FinanceHttp.PATCH,
            FinancePaths.ACCOUNT_PATH + account()
                .path(FinanceFields.ACCOUNT_ID)
                .asString(),
            command().putNull(FinanceFields.NICKNAME)
        );
        assertNull(
            admin.queryForObject(
                "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
                String.class,
                owner,
                UUID.fromString(
                    account()
                        .path(FinanceFields.ACCOUNT_ID)
                        .asString()
                )
            )
        );
    }

    /**
     * 수동 의무의 생성·정정·DELETE 논리 취소와 버전 증가를 실제 저장한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void obligationChanges() throws Exception {
        String obligation = createObligation();
        ok(
            FinanceHttp.PATCH,
            FinancePaths.OBLIGATION_PATH + obligation,
            command()
                .put(FinanceFields.LABEL, "점검비 확정")
                .put(FinanceFields.AMOUNT_KRW, 35000)
                .put(FinanceFields.DUE_DATE, "2026-10-26")
        );
        ObjectNode cancel = command();
        HttpResponse<String> result = send(
            FinanceHttp.DELETE,
            FinancePaths.OBLIGATION_PATH + obligation,
            null,
            token,
            Map.of(
                FinanceHttp.DATA_VERSION_HEADER,
                cancel.path(FinanceFields.EXPECTED_DATA_VERSION).asString(),
                FinanceHttp.RULE_VERSION_HEADER,
                cancel.path(FinanceFields.RULE_VERSION).asString(),
                FinanceHttp.IDEMPOTENCY_HEADER,
                cancel.path(FinanceFields.IDEMPOTENCY_KEY).asString()
            )
        );
        assertEquals(200, result.statusCode());
        assertEquals(
            "cancelled",
            admin.queryForObject(
                "SELECT status FROM payse.obligations WHERE user_id=? AND id=?",
                String.class,
                owner,
                UUID.fromString(obligation)
            )
        );
    }

    /**
     * 보호 설정과 배정의 추가·수정·제거가 원자 저장되고 상한을 넘으면 거절된다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void reserveChanges() throws Exception {
        String obligation = createObligation();
        String reserve = createReserve(obligation);
        JsonNode snapshot = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        JsonNode allocation = single(
            snapshot.path(FinanceFields.ALLOCATIONS),
            value -> reserve.equals(value.path(FinanceFields.RESERVE_ID).asString())
        );
        ObjectNode changes = allocations();
        ((ArrayNode) changes.get("update")).addObject()
            .put(
                FinanceFields.ALLOCATION_ID,
                allocation.path(FinanceFields.ALLOCATION_ID).asString()
            )
            .put(FinanceFields.AMOUNT_KRW, 15000);
        ObjectNode update = command()
            .put(FinanceFields.LABEL, "점검 준비금 수정")
            .put(FinanceFields.AMOUNT_KRW, 40000);
        update.set(FinanceFields.ALLOCATION_CHANGES, changes);
        ok(FinanceHttp.PATCH, FinancePaths.RESERVE_PATH + reserve, update);
        error(
            send(
                FinanceHttp.PATCH,
                FinancePaths.RESERVE_PATH + reserve,
                command().put(FinanceFields.AMOUNT_KRW, 1)
            ),
            422,
            FinanceCodes.LIMIT_EXCEEDED
        );
        ObjectNode remove = command();
        ObjectNode removal = allocations();
        ((ArrayNode) removal.get("remove"))
            .add(allocation.path(FinanceFields.ALLOCATION_ID).asString());
        remove.set(FinanceFields.ALLOCATION_CHANGES, removal);
        ok(FinanceHttp.PATCH, FinancePaths.RESERVE_PATH + reserve, remove);
        ObjectNode cancel = command();
        cancel.putArray(FinanceFields.DETACH_ALLOCATIONS);
        ok(
            FinanceHttp.POST,
            FinancePaths.RESERVE_PATH + reserve + FinancePaths.CANCEL_SUFFIX,
            cancel
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.reserve_allocations WHERE user_id=? AND reserve_id=?",
                Integer.class,
                owner,
                UUID.fromString(reserve)
            )
        );
    }

    /**
     * 미지급 배정 목록을 빠뜨리면 전부 거절하고 정확한 확인 목록에서만 의무를 취소한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void cancelObligation() throws Exception {
        String obligation = createObligation();
        String reserve = createReserve(obligation);
        JsonNode allocation = single(
            ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null).path(FinanceFields.ALLOCATIONS),
            value -> reserve.equals(value.path(FinanceFields.RESERVE_ID).asString())
        );
        ObjectNode missing = command();
        missing.putArray(FinanceFields.DETACH_ALLOCATIONS);
        error(
            send(
                FinanceHttp.POST,
                FinancePaths.OBLIGATION_PATH + obligation + FinancePaths.CANCEL_SUFFIX,
                missing
            ),
            409,
            FinanceCodes.RELATION_CONFLICT
        );
        ObjectNode cancel = command();
        cancel.putArray(FinanceFields.DETACH_ALLOCATIONS)
            .addObject()
            .put(
                FinanceFields.ALLOCATION_ID,
                allocation.path(FinanceFields.ALLOCATION_ID).asString()
            )
            .put(FinanceFields.UNRELEASED_KRW, 20000);
        ok(
            FinanceHttp.POST,
            FinancePaths.OBLIGATION_PATH + obligation + FinancePaths.CANCEL_SUFFIX,
            cancel
        );
        assertEquals(
            50000L,
            admin.queryForObject(
                "SELECT amount_krw FROM payse.reserves WHERE user_id=? AND id=?",
                Long.class,
                owner,
                UUID.fromString(reserve)
            )
        );
        assertEquals(
            "cancelled",
            admin.queryForObject(
                "SELECT status FROM payse.obligations WHERE user_id=? AND id=?",
                String.class,
                owner,
                UUID.fromString(obligation)
            )
        );
    }

    /**
     * 보호 설정 취소 시 연결만 해제하고 의무 원본과 실제 자금은 유지한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void cancelReserve() throws Exception {
        String obligation = createObligation();
        String reserve = createReserve(obligation);
        JsonNode allocation = single(
            ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null).path(FinanceFields.ALLOCATIONS),
            value -> reserve.equals(value.path(FinanceFields.RESERVE_ID).asString())
        );
        ObjectNode cancel = command();
        cancel.putArray(FinanceFields.DETACH_ALLOCATIONS)
            .addObject()
            .put(
                FinanceFields.ALLOCATION_ID,
                allocation.path(FinanceFields.ALLOCATION_ID).asString()
            )
            .put(FinanceFields.UNRELEASED_KRW, 20000);
        ok(
            FinanceHttp.POST,
            FinancePaths.RESERVE_PATH + reserve + FinancePaths.CANCEL_SUFFIX,
            cancel
        );
        assertEquals(
            "active",
            admin.queryForObject(
                "SELECT status FROM payse.obligations WHERE user_id=? AND id=?",
                String.class,
                owner,
                UUID.fromString(obligation)
            )
        );
        assertEquals(
            Boolean.TRUE,
            admin.queryForObject(
                "SELECT cancelled_at IS NOT NULL FROM payse.reserves WHERE user_id=? AND id=?",
                Boolean.class,
                owner,
                UUID.fromString(reserve)
            )
        );
    }

    /**
     * 원천 청구 의무와 지급 이력을 사용자 취소·계좌 변경으로 덮지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void historyProtection() throws Exception {
        JsonNode billed = single(
            source.path(FinanceFields.OBLIGATIONS),
            value -> !value.path(FinanceFields.STATEMENT_ID).isNull()
        );
        error(
            send(
                FinanceHttp.PATCH,
                FinancePaths.OBLIGATION_PATH + billed.path(FinanceFields.OBLIGATION_ID).asString(),
                command().put(FinanceFields.AMOUNT_KRW, 1)
            ),
            409,
            FinanceCodes.HISTORY_LOCKED
        );
        JsonNode partial = single(
            source.path(FinanceFields.ALLOCATIONS),
            value -> value.path(FinanceFields.RELEASED_KRW).longValue() > 0
        );
        ObjectNode cancel = command();
        cancel.putArray(FinanceFields.DETACH_ALLOCATIONS)
            .addObject()
            .put(FinanceFields.ALLOCATION_ID, partial.path(FinanceFields.ALLOCATION_ID).asString())
            .put(
                FinanceFields.UNRELEASED_KRW,
                partial.path(FinanceFields.AMOUNT_KRW).longValue()
                    - partial.path(FinanceFields.RELEASED_KRW).longValue()
            );
        error(
            send(
                FinanceHttp.POST,
                FinancePaths.OBLIGATION_PATH + partial.path(FinanceFields.OBLIGATION_ID).asString()
                    + FinancePaths.CANCEL_SUFFIX,
                cancel
            ),
            409,
            FinanceCodes.HISTORY_LOCKED
        );
        ObjectNode remove = command();
        ObjectNode changes = allocations();
        ((ArrayNode) changes.get("remove"))
            .add(partial.path(FinanceFields.ALLOCATION_ID).asString());
        remove.set(FinanceFields.ALLOCATION_CHANGES, changes);
        error(
            send(
                FinanceHttp.PATCH,
                FinancePaths.RESERVE_PATH + partial.path(FinanceFields.RESERVE_ID).asString(),
                remove
            ),
            409,
            FinanceCodes.HISTORY_LOCKED
        );
    }

    /**
     * 타 사용자·존재하지 않는 계좌를 같은 오류로 숨기고 원천 수정 키를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void ownershipAndValidation() throws Exception {
        String foreign = foreignSource.path(FinanceFields.SETTINGS)
            .path(FinanceFields.SALARY)
            .path(FinanceFields.SALARY_ACCOUNT_ID)
            .asString();
        error(
            send(
                FinanceHttp.PATCH,
                FinancePaths.ACCOUNT_PATH + foreign,
                command().put(FinanceFields.NICKNAME, "다른 통장")
            ),
            403,
            FinanceCodes.RESOURCE_FORBIDDEN
        );
        error(
            send(
                FinanceHttp.PATCH,
                FinancePaths.ACCOUNT_PATH + UUID.randomUUID(),
                command().put(FinanceFields.NICKNAME, "없는 통장")
            ),
            403,
            FinanceCodes.RESOURCE_FORBIDDEN
        );
        error(
            send(
                FinanceHttp.PATCH,
                FinancePaths.ACCOUNT_PATH + account()
                    .path(FinanceFields.ACCOUNT_ID)
                    .asString(),
                command().put(FinanceFields.BALANCE_KRW, 1)
            ),
            422,
            FinanceCodes.VALIDATION_FAILED
        );
        ObjectNode badDate = command()
            .put(FinanceFields.LABEL, "일정 검증")
            .put(
                FinanceFields.WITHDRAWAL_ACCOUNT_ID,
                account()
                    .path(FinanceFields.ACCOUNT_ID)
                    .asString()
            )
            .put(FinanceFields.AMOUNT_KRW, 1)
            .put(FinanceFields.DUE_DATE, "2026-02-30");
        error(
            send(FinanceHttp.POST, FinancePaths.OBLIGATIONS_PATH, badDate),
            422,
            FinanceCodes.VALIDATION_FAILED
        );
        error(
            send(
                FinanceHttp.PATCH,
                FinancePaths.SETTINGS_PATH,
                command()
                    .putObject(FinanceFields.SALARY)
                    .put(FinanceFields.RECEIPT_EVIDENCE, "changed")
            ),
            422,
            FinanceCodes.VALIDATION_FAILED
        );
        ObjectNode emptySelection = command();
        emptySelection.putArray(FinanceFields.ACCOUNT_IDS);
        error(
            send(FinanceHttp.PATCH, FinancePaths.ACCOUNT_SELECTION_PATH, emptySelection),
            422,
            FinanceCodes.VALIDATION_FAILED
        );
    }

    /**
     * 같은 요청은 이전 버전이어도 재생하고 다른 요청·새 키의 구 버전은 충돌한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void replayAndVersion() throws Exception {
        String path = FinancePaths.ACCOUNT_PATH + account()
            .path(FinanceFields.ACCOUNT_ID)
            .asString();
        ObjectNode first = command().put(FinanceFields.NICKNAME, "생활 통장");
        JsonNode saved = ok(FinanceHttp.PATCH, path, first);
        ok(FinanceHttp.PATCH, path, command().put(FinanceFields.NICKNAME, "생활 통장 수정"));
        JsonNode replay = ok(FinanceHttp.PATCH, path, first);
        assertTrue(replay.path(FinanceFields.REPLAYED).booleanValue());
        assertEquals(
            saved.path(FinanceFields.RECEIPT).path(FinanceFields.RECEIPT_ID),
            replay.path(FinanceFields.RECEIPT).path(FinanceFields.RECEIPT_ID)
        );
        assertEquals(
            version(),
            replay.path(FinanceFields.SNAPSHOT)
                .path(FinanceFields.DATA_VERSION)
                .asString()
        );
        error(
            send(FinanceHttp.PATCH, path, first.deepCopy().put(FinanceFields.NICKNAME, "다른 요청")),
            409,
            FinanceCodes.IDEMPOTENCY_CONFLICT
        );
        error(
            send(
                FinanceHttp.PATCH,
                path,
                first.deepCopy().put(FinanceFields.IDEMPOTENCY_KEY, UUID.randomUUID().toString())
            ),
            409,
            FinanceCodes.STALE_DATA
        );
        error(
            send(
                FinanceHttp.PATCH,
                path,
                command()
                    .put(FinanceFields.NICKNAME, "규칙 확인")
                    .put(FinanceFields.RULE_VERSION, "PAYSE-CALC-unknown")
            ),
            409,
            FinanceCodes.RULE_VERSION_MISMATCH
        );
    }

    /**
     * 실제 동시 요청에서도 같은 키 효과는 한 번이며 다른 키의 구 버전은 하나만 성공한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void concurrentWrites() throws Exception {
        String path = FinancePaths.ACCOUNT_PATH + account()
            .path(FinanceFields.ACCOUNT_ID)
            .asString();
        ObjectNode first = command().put(FinanceFields.NICKNAME, "동시 저장");
        long before = Long.parseLong(version());
        List<HttpResponse<String>> same = parallel(path, first, first.deepCopy());
        boolean allReplayed = same.stream().allMatch(value -> value.statusCode() == 200);
        assertTrue(allReplayed);
        assertEquals(before + 1, Long.parseLong(version()));
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.write_receipts WHERE user_id=? AND operation_key=?",
                Integer.class,
                owner,
                first.path(FinanceFields.IDEMPOTENCY_KEY).asString()
            )
        );
        ObjectNode next = command().put(FinanceFields.NICKNAME, "첫 요청");
        ObjectNode different = next.deepCopy()
            .put(FinanceFields.IDEMPOTENCY_KEY, UUID.randomUUID().toString())
            .put(FinanceFields.NICKNAME, "둘째 요청");
        List<HttpResponse<String>> conflict = parallel(path, next, different);
        assertEquals(
            Set.of(200, 409),
            Set.of(conflict.get(0).statusCode(), conflict.get(1).statusCode())
        );
        assertEquals(before + 2, Long.parseLong(version()));
    }

    /**
     * 두 실제 HTTP 호출을 같은 시작 신호로 실행한다.
     * @created 2026-10-29
     * @usedBy concurrentWrites
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private List<HttpResponse<String>> parallel(String path, ObjectNode first, ObjectNode second)
        throws Exception {
        try (var executor = Executors.newFixedThreadPool(2)) {
            CountDownLatch start = new CountDownLatch(1);
            var left = executor.submit(
                () -> {
                    start.await();
                    return send(FinanceHttp.PATCH, path, first);
                }
            );
            var right = executor.submit(
                () -> {
                    start.await();
                    return send(FinanceHttp.PATCH, path, second);
                }
            );
            start.countDown();
            return List.of(left.get(20, TimeUnit.SECONDS), right.get(20, TimeUnit.SECONDS));
        }
    }

    /**
     * 영수증 단계 SQL 취소에서 앞선 설정·버전이 롤백되고 같은 키 재시도가 성공한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rollbackOnReceiptFailure() throws Exception {
        String before = version();
        String path = FinancePaths.ACCOUNT_PATH + account()
            .path(FinanceFields.ACCOUNT_ID)
            .asString();
        ObjectNode body = command().put(FinanceFields.NICKNAME, "취소된 변경");
        String oldNickname = admin.queryForObject(
            "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class,
            owner,
            UUID.fromString(
                account()
                    .path(FinanceFields.ACCOUNT_ID)
                    .asString()
            )
        );
        admin.execute(
            """
            CREATE FUNCTION payse.test_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'isolated cancellation' USING ERRCODE = '57014';
            END $$;
            CREATE TRIGGER test_receipt_failure BEFORE INSERT ON payse.write_receipts
              FOR EACH ROW EXECUTE FUNCTION payse.test_receipt_failure();
            """
        );
        try {
            error(send(FinanceHttp.PATCH, path, body), 503, FinanceCodes.TEMPORARILY_UNAVAILABLE);
            assertEquals(before, version());
            assertEquals(
                oldNickname,
                admin.queryForObject(
                    "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
                    String.class,
                    owner,
                    UUID.fromString(
                        account()
                            .path(FinanceFields.ACCOUNT_ID)
                            .asString()
                    )
                )
            );
            assertEquals(
                0,
                admin.queryForObject(
                    "SELECT count(*) FROM payse.write_receipts WHERE user_id=? AND operation_key=?",
                    Integer.class,
                    owner,
                    body.path(FinanceFields.IDEMPOTENCY_KEY).asString()
                )
            );
        } finally {
            admin.execute("DROP TRIGGER test_receipt_failure ON payse.write_receipts");
            admin.execute("DROP FUNCTION payse.test_receipt_failure()");
        }

        ok(FinanceHttp.PATCH, path, body);
    }

    /**
     * 지연 DB 제약의 최종 실패에서도 앞선 설정·영수증·버전을 함께 되돌린다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void deferredConstraintRollback() throws Exception {
        String before = version();
        ObjectNode body = command().put(FinanceFields.NICKNAME, "제약 검증");
        UUID accountId = UUID.fromString(
            account()
                .path(FinanceFields.ACCOUNT_ID)
                .asString()
        );
        String oldNickname = admin.queryForObject(
            "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class,
            owner,
            accountId
        );
        admin.execute(
            """
            CREATE FUNCTION payse.test_deferred_failure() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'isolated deferred constraint' USING ERRCODE = '23514';
            END $$;
            CREATE CONSTRAINT TRIGGER test_deferred_failure AFTER UPDATE ON payse.financial_accounts
              DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payse.test_deferred_failure();
            """
        );
        try {
            error(
                send(FinanceHttp.PATCH, FinancePaths.ACCOUNT_PATH + accountId, body),
                409,
                FinanceCodes.RELATION_CONFLICT
            );
            assertEquals(before, version());
            assertEquals(
                oldNickname,
                admin.queryForObject(
                    "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
                    String.class,
                    owner,
                    accountId
                )
            );
            assertEquals(
                0,
                admin.queryForObject(
                    "SELECT count(*) FROM payse.write_receipts WHERE user_id=? AND operation_key=?",
                    Integer.class,
                    owner,
                    body.path(FinanceFields.IDEMPOTENCY_KEY).asString()
                )
            );
        } finally {
            admin.execute("DROP TRIGGER test_deferred_failure ON payse.financial_accounts");
            admin.execute("DROP FUNCTION payse.test_deferred_failure()");
        }
    }

    /**
     * RLS·원천 쓰기 금지와 인증 없는 저장소 호출 차단을 실제 역할로 검사한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void runtimePermissions() {
        JdbcTemplate runtime = context.getBean(JdbcTemplate.class);
        AuthTransactions transactions = context.getBean(AuthTransactions.class);
        AuthRepository auth = context.getBean(AuthRepository.class);
        String digest = context.getBean(AuthCrypto.class).tokenDigest(token);
        FinancialRepository repository = context.getBean(FinancialRepository.class);
        assertThrows(IllegalStateException.class, () -> repository.load(owner));
        assertEquals(
            0,
            transactions.run(
                () -> runtime
                    .queryForObject("SELECT count(*) FROM payse.financial_accounts", Integer.class)
            )
        );
        transactions.run(
            () -> {
                assertTrue(auth.authorize(digest).isPresent());
                UUID foreign = UUID
                    .fromString(foreignSource.path(FinanceFields.USER_ID).asString());
                assertEquals(
                    0,
                    runtime.queryForObject(
                        "SELECT count(*) FROM payse.financial_accounts WHERE user_id=?",
                        Integer.class,
                        foreign
                    )
                );
                assertEquals(
                    source.path(FinanceFields.ACCOUNTS).size(),
                    repository.load(owner)
                        .path(FinanceFields.ACCOUNTS)
                        .size()
                );
                assertThrows(IllegalStateException.class, () -> repository.load(foreign));
                return null;
            }
        );
        assertThrows(
            AuthStoreException.class,
            () -> transactions.run(
                () -> {
                    auth.authorize(digest).orElseThrow();
                    runtime
                        .update(
                            "UPDATE payse.financial_accounts SET balance_krw=0 WHERE user_id=?",
                            owner
                        );
                    return null;
                }
            )
        );
        assertEquals(
            0,
            transactions.run(
                () -> runtime
                    .queryForObject("SELECT count(*) FROM payse.financial_accounts", Integer.class)
            )
        );
    }

    /**
     * JPA 1차 캐시가 다음 사용자의 RLS를 우회하지 않고 명시 flush 후 실패도 원복되는지 검사한다.
     * @created 2026-10-29
     * @usedBy JUnit 실제 PostgreSQL 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void entityIsolationAndRollback() {
        EntityManager entityManager = context.getBean(EntityManager.class);
        AuthTransactions transactions = context.getBean(AuthTransactions.class);
        AuthRepository auth = context.getBean(AuthRepository.class);
        AuthCrypto crypto = context.getBean(AuthCrypto.class);
        UUID accountId = UUID.fromString(
            account()
                .path(FinanceFields.ACCOUNT_ID)
                .asString()
        );
        UUID foreign = UUID.fromString(foreignSource.path(FinanceFields.USER_ID).asString());
        var foreignToken = crypto.issueToken();
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.users SET code_verifier=? WHERE id=?",
                crypto.codeVerifier(foreign, code),
                foreign
            )
        );
        transactions.run(() -> auth.openSession(foreign, foreignToken.digest()).orElseThrow());
        Object firstContext = transactions.run(
            () -> {
                auth.authorize(crypto.tokenDigest(token)).orElseThrow();
                AccountEntity account = entityManager.find(AccountEntity.class, accountId);
                assertNotNull(account);
                assertEquals(owner, account.userId());
                return entityManager.getDelegate();
            }
        );
        transactions.run(
            () -> {
                auth.authorize(foreignToken.digest()).orElseThrow();
                assertNotSame(firstContext, entityManager.getDelegate());
                assertNull(entityManager.find(AccountEntity.class, accountId));
                return null;
            }
        );
        String oldNickname = admin.queryForObject(
            "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class,
            owner,
            accountId
        );
        String before = version();
        assertThrows(
            IllegalStateException.class,
            () -> transactions.run(
                () -> {
                    auth.authorize(crypto.tokenDigest(token)).orElseThrow();
                    entityManager.find(AccountEntity.class, accountId).rename("롤백 확인");

                    entityManager.flush();
                    throw new IllegalStateException("intentional isolated rollback");
                }
            )
        );
        assertEquals(
            oldNickname,
            admin.queryForObject(
                "SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
                String.class,
                owner,
                accountId
            )
        );
        assertEquals(before, version());
    }

    /**
     * 재로그인에서도 설정을 유지하며 이전 세션·변조·구 버전 cursor를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void reloginAndCursor() throws Exception {
        String cursor = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null)
            .path(FinanceFields.PAGE)
            .path(FinanceFields.NEXT_CURSOR)
            .asString();
        assertNotNull(cursor);
        error(
            send(FinanceHttp.GET, "/transactions?cursor=broken", null),
            400,
            FinanceCodes.INVALID_CURSOR
        );
        ok(
            FinanceHttp.PATCH,
            FinancePaths.ACCOUNT_PATH + account()
                .path(FinanceFields.ACCOUNT_ID)
                .asString(),
            command().put(FinanceFields.NICKNAME, "다시 접속")
        );
        error(
            send(FinanceHttp.GET, FinancePaths.TRANSACTION_CURSOR_PATH + cursor, null),
            409,
            FinanceCodes.STALE_DATA
        );
        cursor = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null)
            .path(FinanceFields.PAGE)
            .path(FinanceFields.NEXT_CURSOR)
            .asString();
        HttpResponse<String> logout = send(
            FinanceHttp.DELETE,
            FinancePaths.CURRENT_SESSION_PATH,
            null
        );
        assertEquals(204, logout.statusCode());
        error(
            send(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null),
            401,
            FinanceCodes.SESSION_INVALID
        );
        token = login();
        error(
            send(FinanceHttp.GET, FinancePaths.TRANSACTION_CURSOR_PATH + cursor, null),
            403,
            FinanceCodes.RESOURCE_FORBIDDEN
        );
        JsonNode restored = ok(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null);
        JsonNode saved = single(
            restored.path(FinanceFields.ACCOUNTS),
            value -> value.path(FinanceFields.ACCOUNT_ID)
                .equals(account().path(FinanceFields.ACCOUNT_ID))
        );
        assertEquals("다시 접속", saved.path(FinanceFields.NICKNAME).asString());
    }

    /**
     * 미지원 원천 형식을 v3로 위장하지 않고 서버 계산 필드 없이 실패한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-10-30 - v4 지원 전환 후 미지원 버전 검사에 별도 비지원 형식을 사용
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void unsupportedSourceVersion() throws Exception {
        admin.update(
            "UPDATE payse.source_contexts SET schema_version='PAYSE-DRAFT-UNSUPPORTED' WHERE user_id=?",
            owner
        );
        try {
            error(
                send(FinanceHttp.GET, FinancePaths.SNAPSHOT_PATH, null),
                503,
                FinanceCodes.TEMPORARILY_UNAVAILABLE
            );
        } finally {
            admin.update(
                "UPDATE payse.source_contexts SET schema_version='PAYSE-DRAFT-3' WHERE user_id=?",
                owner
            );
        }
    }

    /**
     * 유효 인증이 먼저 필요하며 잘못된 입력·본문 상한을 원자 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void invalidHttpInput() throws Exception {
        error(
            send(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, "{", "bad-token", Map.of()),
            401,
            FinanceCodes.SESSION_INVALID
        );
        error(
            send(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, "{", token, Map.of()),
            400,
            FinanceCodes.INVALID_JSON
        );
        error(
            send(FinanceHttp.PATCH, FinancePaths.SETTINGS_PATH, " ".repeat(65537), token, Map.of()),
            413,
            FinanceCodes.REQUEST_TOO_LARGE
        );
        error(
            send(FinanceHttp.GET, FinancePaths.TRANSACTIONS_PATH, null),
            400,
            FinanceCodes.INVALID_CURSOR
        );
        error(
            send(FinanceHttp.GET, "/snapshot?limit=2", null),
            422,
            FinanceCodes.VALIDATION_FAILED
        );
    }
}
