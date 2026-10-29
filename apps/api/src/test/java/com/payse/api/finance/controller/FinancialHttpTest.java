package com.payse.api.finance.controller;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

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
     */
    @BeforeAll
    static void requireDatabase() {
        assumeFalse(System.getenv().keySet().stream().noneMatch(key -> key.startsWith("PAYSE_FINANCIAL_TEST_")),
            "Run test_financial_service.py with a new isolated PostgreSQL directory");
        assertTrue(setting("JDBC_URL").matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_financial"));
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
        assertTrue(value != null && !value.isBlank(), "Missing isolated financial setting: " + name);
        return value;
    }

    /**
     * 폐기용 DB만 초기화하고 실제 원천·설정 시나리오와 임시 서버를 준비한다.
     * @created 2026-10-29
     * @usedBy JUnit BeforeEach
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
        assertEquals("payse_auth_test_financial", admin.queryForObject("SELECT current_database()", String.class));
        // 전용 실행기가 만든 DB에서만 각 검사를 독립 준비한다. 기관 기준정보는 유지한다.
        admin.execute("TRUNCATE payse.users CASCADE");
        admin.execute("TRUNCATE payse.auth_rate_limits");
        admin.execute(Files.readString(Path.of(setting("SEED_FILE"))));
        source = json.readTree(Files.readString(Path.of("fixtures/generated/snapshots/alpha-ready.json")));
        foreignSource = json.readTree(Files.readString(Path.of("fixtures/generated/snapshots/beta-ready.json")));
        owner = UUID.fromString(source.get("userId").asString());
        JsonNode users = json.readTree(Files.readString(Path.of("fixtures/generated/server-seeds.json"))).get("users");
        credentials = single(users, entry -> entry.get("userId").equals(source.get("userId")));
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.users WHERE id=?", Integer.class, owner));
        assertEquals(source.get("accounts").size(), admin.queryForObject(
            "SELECT count(*) FROM payse.financial_accounts WHERE user_id=?", Integer.class, owner));

        SecureRandom random = new SecureRandom();
        Map<String, Object> properties = new HashMap<>();
        properties.put("server.port", "0");
        properties.put("server.address", "127.0.0.1");
        properties.put("spring.main.banner-mode", "off");
        properties.put("PAYSE_AUTH_PEER_MODE", "direct");
        properties.put("PAYSE_JDBC_URL", setting("JDBC_URL"));
        properties.put("PAYSE_DB_USER", setting("DB_USER"));
        properties.put("PAYSE_DB_PASSWORD", setting("DB_PASSWORD"));
        properties.put("PAYSE_DB_MAX_POOL_SIZE", "6");
        properties.put("PAYSE_DB_CONNECTION_TIMEOUT_MS", "5000");
        properties.put("PAYSE_DB_VALIDATION_TIMEOUT_MS", "1000");
        properties.put("PAYSE_AUTH_CODE_KEY_ID", "financial-test");
        for (String key : List.of("PAYSE_AUTH_CODE_KEY_BASE64", "PAYSE_AUTH_LIMIT_KEY_BASE64", "PAYSE_FINANCE_CURSOR_KEY_BASE64")) {
            byte[] bytes = new byte[32];
            random.nextBytes(bytes);
            properties.put(key, Base64.getEncoder().encodeToString(bytes));
        }
        SpringApplication app = new SpringApplication(PayseApiApplication.class);
        app.setAdditionalProfiles("database", "auth", "finance");
        app.setDefaultProperties(properties);
        context = app.run();
        base = "http://127.0.0.1:" + ((WebServerApplicationContext) context).getWebServer().getPort();
        code = String.format(java.util.Locale.ROOT, "%06d", random.nextInt(1_000_000));
        assertEquals(1, admin.update("UPDATE payse.users SET code_verifier=? WHERE id=?",
            context.getBean(AuthCrypto.class).codeVerifier(owner, code), owner));
        client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        token = login();
        sourceBefore = fingerprint();
    }

    /**
     * 모든 검사에서 원천 불변을 확인하고 자신이 만든 연결·서버만 닫는다.
     * @created 2026-10-29
     * @usedBy JUnit AfterEach
     */
    @AfterEach
    void stop() {
        try {
            if (sourceBefore != null) assertEquals(sourceBefore, fingerprint(), "Financial source facts changed");
        } finally {
            if (client != null) client.close();
            if (context != null) context.close();
            if (adminPool != null) adminPool.close();
        }
    }

    /**
     * 표기명·첫 행 대신 검증된 단일 관계로 검사 대상을 찾는다.
     * @created 2026-10-29
     * @usedBy start, account, changed, historyProtection
     */
    private JsonNode single(JsonNode array, Predicate<JsonNode> matches) {
        List<JsonNode> found = new ArrayList<>();
        array.forEach(value -> { if (matches.test(value)) found.add(value); });
        assertEquals(1, found.size(), "Fixture relationship must identify exactly one object");
        return found.getFirst();
    }

    /**
     * 급여 설정이 가리키는 실제 소유 계좌 관계를 확인한다.
     * @created 2026-10-29
     * @usedBy 설정·의무·보호금 검사
     */
    private JsonNode account() {
        JsonNode id = source.get("settings").get("salary").get("salaryAccountId");
        return single(source.get("accounts"), value -> value.get("accountId").equals(id));
    }

    /**
     * 명시한 성공 영수증의 대상 하나를 확인하고 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy createObligation, createReserve
     */
    private String changed(JsonNode result, String resource) {
        return single(result.get("receipt").get("changedRefs"), ref -> resource.equals(ref.path("resource").asString()))
            .get("id").asString();
    }

    /**
     * 원천 테이블과 계좌 원천 열의 지문을 만들며 허용 설정 열은 제외한다.
     * @created 2026-10-29
     * @usedBy start, stop
     */
    private Map<String, String> fingerprint() {
        Map<String, String> result = new HashMap<>();
        for (String table : List.of("source_contexts", "financial_accounts", "financial_cards", "financial_transactions",
                "card_statements", "statement_items", "transaction_references", "transaction_relations")) {
            String value = "financial_accounts".equals(table)
                ? "(to_jsonb(record)-'included'-'nickname')::text" : "to_jsonb(record)::text";
            result.put(table, admin.queryForObject("SELECT md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
                + "FROM (SELECT " + value + " AS value FROM payse." + table + " record) rows", String.class));
        }
        return result;
    }

    /**
     * 합성 금융 성공 응답만 격리 검사 폴더에 남겨 변경 없는 Flutter 파서와 대조한다.
     * @created 2026-10-29
     * @usedBy snapshotAndPages, unconnectedAndConsent, accountAndSettings
     */
    private void capture(String name, JsonNode response) throws Exception {
        assertTrue(name.matches("[a-z-]+"));
        Path directory = Path.of(setting("RESPONSE_DIR")).toAbsolutePath().normalize();
        assertEquals(Path.of(setting("SEED_FILE")).toAbsolutePath().normalize().getParent().resolve("public-responses"), directory);
        assertTrue(response.isObject());
        assertFalse(response.has("accessToken"));
        assertFalse(response.has("phone"));
        Files.writeString(directory.resolve(name + ".json"), json.writerWithDefaultPrettyPrinter().writeValueAsString(response));
    }

    /**
     * 실제 현재 사용자 버전으로 금융 쓰기 공통 필드를 준비한다.
     * @created 2026-10-29
     * @usedBy 금융 쓰기 검사
     */
    private ObjectNode command() {
        return json.createObjectNode().put("expectedDataVersion", version()).put("ruleVersion", "PAYSE-CALC-1")
            .put("idempotencyKey", UUID.randomUUID().toString());
    }

    /**
     * 기대 버전은 검사 대상의 응답을 복사하지 않고 저장된 사용자 버전에서 읽는다.
     * @created 2026-10-29
     * @usedBy command, 경합·롤백 검사
     */
    private String version() {
        return admin.queryForObject("SELECT data_version::text FROM payse.users WHERE id=?", String.class, owner);
    }

    /**
     * 실제 loopback 서버에 요청하고 금융 응답의 보안 헤더를 확인한다.
     * @created 2026-10-29
     * @usedBy API 검사
     */
    private HttpResponse<String> send(String method, String path, String body, String bearer, Map<String, String> headers)
            throws Exception {
        var request = HttpRequest.newBuilder(URI.create(base + path)).timeout(Duration.ofSeconds(20));
        request.header("Content-Type", "application/json; charset=utf-8");
        if (bearer != null) request.header("Authorization", "Bearer " + bearer);
        headers.forEach(request::header);
        request.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body));
        var result = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertEquals("no-store", result.headers().firstValue("Cache-Control").orElse(""));
        assertTrue(result.headers().allValues("Set-Cookie").isEmpty());
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
     */
    private void error(HttpResponse<String> result, int status, String code) {
        assertEquals(status, result.statusCode());
        JsonNode problem = json.readTree(result.body()).get("error");
        assertNotNull(problem);
        assertEquals(code, problem.path("code").asString());
        assertDoesNotThrow(() -> UUID.fromString(problem.path("requestId").asString()));
        assertTrue(problem.path("details").isArray());
        assertFalse(result.body().contains(token));
        assertFalse(result.body().contains("SELECT "));
        if (status == 401) assertEquals("Bearer", result.headers().firstValue("WWW-Authenticate").orElse(""));
    }

    /**
     * 사전 계정의 검증값을 실제 인증 HTTP로 대조해 세션을 얻는다.
     * @created 2026-10-29
     * @usedBy start, reloginAndCursor
     */
    private String login() throws Exception {
        ObjectNode body = json.createObjectNode().put("name", credentials.path("name").asString())
            .put("phone", credentials.path("phone").asString()).put("code", code);
        var response = send("POST", "/demo-sessions", body.toString(), null, Map.of());
        assertEquals(201, response.statusCode());
        return json.readTree(response.body()).path("accessToken").asString();
    }

    /**
     * 검사에서 새 단건 의무를 만들며 저장 ID는 성공 영수증에서 받는다.
     * @created 2026-10-29
     * @usedBy CRUD·배정·취소 검사
     */
    private String createObligation() throws Exception {
        ObjectNode body = command().put("label", "확인한 정기점검").put("withdrawalAccountId", account().path("accountId").asString())
            .put("amountKRW", 30000).put("dueDate", "2026-10-24");
        return changed(ok("POST", "/obligations", body), "obligation");
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
     */
    private String createReserve(String obligation) throws Exception {
        ObjectNode body = command().put("accountId", account().path("accountId").asString())
            .put("label", "점검 준비금").put("amountKRW", 50000);
        ObjectNode changes = allocations();
        if (obligation != null) ((ArrayNode) changes.get("create")).addObject().put("obligationId", obligation).put("amountKRW", 20000);
        body.set("allocationChanges", changes);
        return changed(ok("POST", "/reserves", body), "reserve");
    }

    /**
     * 전체 거래를 중복 없이 페이지로 제공하고 원천 사실·기준 시각을 유지한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void snapshotAndPages() throws Exception {
        JsonNode snapshot = ok("GET", "/snapshot", null);
        assertEquals("PAYSE-API-0.6-3", snapshot.path("schemaVersion").asString());
        assertEquals(owner.toString(), snapshot.path("userId").asString());
        assertEquals(source.path("sourceVersion"), snapshot.path("sourceVersion"));
        assertEquals(Instant.parse("2026-10-19T03:00:00Z"), Instant.parse(snapshot.path("asOf").asString()));
        assertEquals(source.path("accounts").size(), snapshot.path("accounts").size());
        capture("full-snapshot", snapshot);
        assertEquals(source.path("settings").path("salary").path("receiptEvidence"),
            snapshot.path("settings").path("salary").path("receiptEvidence"));
        Set<String> received = new HashSet<>();
        JsonNode page = snapshot;
        int pages = 0;
        while (true) {
            pages++;
            assertTrue(page.path("transactions").size() <= 100);
            for (JsonNode transaction : page.path("transactions")) {
                assertTrue(received.add(transaction.path("transactionId").asString()), "Duplicated page transaction");
                assertTrue(transaction.path("amountKRW").isIntegralNumber());
                assertFalse(transaction.has("items"));
            }
            JsonNode cursor = page.path("page").path("nextCursor");
            if (cursor.isNull()) break;
            assertTrue(pages < 10, "Unbounded cursor chain");
            page = ok("GET", "/transactions?cursor=" + cursor.asString(), null);
            capture("transaction-page", page);
            assertEquals(snapshot.path("dataVersion"), page.path("dataVersion"));
            assertFalse(page.has("accounts"));
        }
        Set<String> expected = new HashSet<>();
        source.path("transactions").forEach(value -> expected.add(value.path("transactionId").asString()));
        assertEquals(expected, received);
        assertTrue(pages >= 2);
        for (JsonNode statement : snapshot.path("statements")) assertFalse(statement.has("items"));
    }

    /**
     * 연결 전에는 열 개 메타 키만 반환하고 로그인 자체가 연결을 만들지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void unconnectedAndConsent() throws Exception {
        admin.update("DELETE FROM payse.institution_links WHERE user_id=?", owner);
        JsonNode first = ok("GET", "/snapshot", null);
        assertEquals(10, first.size());
        assertTrue(first.path("institutionLinks").isEmpty());
        assertFalse(first.has("accounts"));
        capture("unconnected", first);
        ObjectNode body = command();
        body.putArray("institutionCodes").add(account().path("institutionCode").asString());
        JsonNode connected = ok("POST", "/institution-links", body).path("snapshot");
        assertEquals(2, connected.path("accounts").size());
        assertEquals(0, connected.path("cards").size());
        assertTrue(connected.path("accessRestrictions").size() > 0);
        capture("partial-bank", connected);
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.institution_links WHERE user_id=? AND disconnected_at IS NULL", Integer.class, owner));
        JsonNode debit = single(source.path("cards"), value -> "debit".equals(value.path("cardType").asString()));
        ObjectNode addCard = command();
        addCard.putArray("institutionCodes").add(account().path("institutionCode").asString()).add(debit.path("institutionCode").asString());
        capture("partial-bank-card", ok("POST", "/institution-links", addCard).path("snapshot"));
    }

    /**
     * 사용자 선택·별칭·급여·카드 계획은 저장하고 원천 일정·잔액은 보존한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void accountAndSettings() throws Exception {
        ObjectNode selection = command();
        selection.putArray("accountIds").add(account().path("accountId").asString());
        ok("PATCH", "/account-selection", selection);
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.financial_accounts WHERE user_id=? AND included", Integer.class, owner));
        ok("PATCH", "/accounts/" + account().path("accountId").asString(), command().put("nickname", "급여 통장"));
        assertEquals("급여 통장", admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class, owner, UUID.fromString(account().path("accountId").asString())));
        ObjectNode salary = command();
        salary.putObject("salary").put("salaryDay", 31).put("salaryAmountKRW", 3200000)
            .put("salaryAccountId", account().path("accountId").asString());
        JsonNode saved = ok("PATCH", "/settings", salary).path("snapshot");
        assertEquals(31, saved.path("settings").path("salary").path("salaryDay").intValue());
        capture("postwrite", saved);
        JsonNode card = single(source.path("cards"), value -> "debit".equals(value.path("cardType").asString()));
        ObjectNode plan = command();
        plan.putArray("cardPlans").addObject().put("cardId", card.path("cardId").asString()).put("plannedPaymentDay", 29);
        ok("PATCH", "/settings", plan);
        ObjectNode clear = command();
        clear.putArray("cardPlans").addObject().put("cardId", card.path("cardId").asString()).putNull("plannedPaymentDay");
        ok("PATCH", "/settings", clear);
        ok("PATCH", "/accounts/" + account().path("accountId").asString(), command().putNull("nickname"));
        assertNull(admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class, owner, UUID.fromString(account().path("accountId").asString())));
    }

    /**
     * 수동 의무의 생성·정정·DELETE 논리 취소와 버전 증가를 실제 저장한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void obligationChanges() throws Exception {
        String obligation = createObligation();
        ok("PATCH", "/obligations/" + obligation, command().put("label", "점검비 확정").put("amountKRW", 35000)
            .put("dueDate", "2026-10-26"));
        ObjectNode cancel = command();
        HttpResponse<String> result = send("DELETE", "/obligations/" + obligation, null, token, Map.of(
            "Payse-Expected-Data-Version", cancel.path("expectedDataVersion").asString(),
            "Payse-Rule-Version", cancel.path("ruleVersion").asString(), "Idempotency-Key", cancel.path("idempotencyKey").asString()));
        assertEquals(200, result.statusCode());
        assertEquals("cancelled", admin.queryForObject("SELECT status FROM payse.obligations WHERE user_id=? AND id=?",
            String.class, owner, UUID.fromString(obligation)));
    }

    /**
     * 보호 설정과 배정의 추가·수정·제거가 원자 저장되고 상한을 넘으면 거절된다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void reserveChanges() throws Exception {
        String obligation = createObligation();
        String reserve = createReserve(obligation);
        JsonNode snapshot = ok("GET", "/snapshot", null);
        JsonNode allocation = single(snapshot.path("allocations"), value -> reserve.equals(value.path("reserveId").asString()));
        ObjectNode changes = allocations();
        ((ArrayNode) changes.get("update")).addObject().put("allocationId", allocation.path("allocationId").asString()).put("amountKRW", 15000);
        ObjectNode update = command().put("label", "점검 준비금 수정").put("amountKRW", 40000);
        update.set("allocationChanges", changes);
        ok("PATCH", "/reserves/" + reserve, update);
        error(send("PATCH", "/reserves/" + reserve, command().put("amountKRW", 1)), 422, "LIMIT_EXCEEDED");
        ObjectNode remove = command();
        ObjectNode removal = allocations();
        ((ArrayNode) removal.get("remove")).add(allocation.path("allocationId").asString());
        remove.set("allocationChanges", removal);
        ok("PATCH", "/reserves/" + reserve, remove);
        ObjectNode cancel = command();
        cancel.putArray("detachAllocations");
        ok("POST", "/reserves/" + reserve + "/cancel", cancel);
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.reserve_allocations WHERE user_id=? AND reserve_id=?",
            Integer.class, owner, UUID.fromString(reserve)));
    }

    /**
     * 미지급 배정 목록을 빠뜨리면 전부 거절하고 정확한 확인 목록에서만 의무를 취소한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void cancelObligation() throws Exception {
        String obligation = createObligation();
        String reserve = createReserve(obligation);
        JsonNode allocation = single(ok("GET", "/snapshot", null).path("allocations"),
            value -> reserve.equals(value.path("reserveId").asString()));
        ObjectNode missing = command();
        missing.putArray("detachAllocations");
        error(send("POST", "/obligations/" + obligation + "/cancel", missing), 409, "RELATION_CONFLICT");
        ObjectNode cancel = command();
        cancel.putArray("detachAllocations").addObject().put("allocationId", allocation.path("allocationId").asString()).put("unreleasedKRW", 20000);
        ok("POST", "/obligations/" + obligation + "/cancel", cancel);
        assertEquals(50000L, admin.queryForObject("SELECT amount_krw FROM payse.reserves WHERE user_id=? AND id=?",
            Long.class, owner, UUID.fromString(reserve)));
        assertEquals("cancelled", admin.queryForObject("SELECT status FROM payse.obligations WHERE user_id=? AND id=?",
            String.class, owner, UUID.fromString(obligation)));
    }

    /**
     * 보호 설정 취소 시 연결만 해제하고 의무 원본과 실제 자금은 유지한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void cancelReserve() throws Exception {
        String obligation = createObligation();
        String reserve = createReserve(obligation);
        JsonNode allocation = single(ok("GET", "/snapshot", null).path("allocations"),
            value -> reserve.equals(value.path("reserveId").asString()));
        ObjectNode cancel = command();
        cancel.putArray("detachAllocations").addObject().put("allocationId", allocation.path("allocationId").asString()).put("unreleasedKRW", 20000);
        ok("POST", "/reserves/" + reserve + "/cancel", cancel);
        assertEquals("active", admin.queryForObject("SELECT status FROM payse.obligations WHERE user_id=? AND id=?",
            String.class, owner, UUID.fromString(obligation)));
        assertEquals(Boolean.TRUE, admin.queryForObject("SELECT cancelled_at IS NOT NULL FROM payse.reserves WHERE user_id=? AND id=?",
            Boolean.class, owner, UUID.fromString(reserve)));
    }

    /**
     * 원천 청구 의무와 지급 이력을 사용자 취소·계좌 변경으로 덮지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void historyProtection() throws Exception {
        JsonNode billed = single(source.path("obligations"), value -> !value.path("statementId").isNull());
        error(send("PATCH", "/obligations/" + billed.path("obligationId").asString(), command().put("amountKRW", 1)),
            409, "HISTORY_LOCKED");
        JsonNode partial = single(source.path("allocations"), value -> value.path("releasedKRW").longValue() > 0);
        ObjectNode cancel = command();
        cancel.putArray("detachAllocations").addObject().put("allocationId", partial.path("allocationId").asString())
            .put("unreleasedKRW", partial.path("amountKRW").longValue() - partial.path("releasedKRW").longValue());
        error(send("POST", "/obligations/" + partial.path("obligationId").asString() + "/cancel", cancel), 409, "HISTORY_LOCKED");
        ObjectNode remove = command();
        ObjectNode changes = allocations();
        ((ArrayNode) changes.get("remove")).add(partial.path("allocationId").asString());
        remove.set("allocationChanges", changes);
        error(send("PATCH", "/reserves/" + partial.path("reserveId").asString(), remove), 409, "HISTORY_LOCKED");
    }

    /**
     * 타 사용자·존재하지 않는 계좌를 같은 오류로 숨기고 원천 수정 키를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void ownershipAndValidation() throws Exception {
        String foreign = foreignSource.path("settings").path("salary").path("salaryAccountId").asString();
        error(send("PATCH", "/accounts/" + foreign, command().put("nickname", "다른 통장")), 403, "RESOURCE_FORBIDDEN");
        error(send("PATCH", "/accounts/" + UUID.randomUUID(), command().put("nickname", "없는 통장")), 403, "RESOURCE_FORBIDDEN");
        error(send("PATCH", "/accounts/" + account().path("accountId").asString(), command().put("balanceKRW", 1)), 422, "VALIDATION_FAILED");
        ObjectNode badDate = command().put("label", "일정 검증").put("withdrawalAccountId", account().path("accountId").asString())
            .put("amountKRW", 1).put("dueDate", "2026-02-30");
        error(send("POST", "/obligations", badDate), 422, "VALIDATION_FAILED");
        error(send("PATCH", "/settings", command().putObject("salary").put("receiptEvidence", "changed")), 422, "VALIDATION_FAILED");
        ObjectNode emptySelection = command();
        emptySelection.putArray("accountIds");
        error(send("PATCH", "/account-selection", emptySelection), 422, "VALIDATION_FAILED");
    }

    /**
     * 같은 요청은 이전 버전이어도 재생하고 다른 요청·새 키의 구 버전은 충돌한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void replayAndVersion() throws Exception {
        String path = "/accounts/" + account().path("accountId").asString();
        ObjectNode first = command().put("nickname", "생활 통장");
        JsonNode saved = ok("PATCH", path, first);
        ok("PATCH", path, command().put("nickname", "생활 통장 수정"));
        JsonNode replay = ok("PATCH", path, first);
        assertTrue(replay.path("replayed").booleanValue());
        assertEquals(saved.path("receipt").path("receiptId"), replay.path("receipt").path("receiptId"));
        assertEquals(version(), replay.path("snapshot").path("dataVersion").asString());
        error(send("PATCH", path, first.deepCopy().put("nickname", "다른 요청")), 409, "IDEMPOTENCY_CONFLICT");
        error(send("PATCH", path, first.deepCopy().put("idempotencyKey", UUID.randomUUID().toString())), 409, "STALE_DATA");
        error(send("PATCH", path, command().put("nickname", "규칙 확인").put("ruleVersion", "PAYSE-CALC-unknown")),
            409, "RULE_VERSION_MISMATCH");
    }

    /**
     * 실제 동시 요청에서도 같은 키 효과는 한 번이며 다른 키의 구 버전은 하나만 성공한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void concurrentWrites() throws Exception {
        String path = "/accounts/" + account().path("accountId").asString();
        ObjectNode first = command().put("nickname", "동시 저장");
        long before = Long.parseLong(version());
        List<HttpResponse<String>> same = parallel(path, first, first.deepCopy());
        assertTrue(same.stream().allMatch(value -> value.statusCode() == 200));
        assertEquals(before + 1, Long.parseLong(version()));
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.write_receipts WHERE user_id=? AND operation_key=?",
            Integer.class, owner, first.path("idempotencyKey").asString()));
        ObjectNode next = command().put("nickname", "첫 요청");
        ObjectNode different = next.deepCopy().put("idempotencyKey", UUID.randomUUID().toString()).put("nickname", "둘째 요청");
        List<HttpResponse<String>> conflict = parallel(path, next, different);
        assertEquals(Set.of(200, 409), Set.of(conflict.get(0).statusCode(), conflict.get(1).statusCode()));
        assertEquals(before + 2, Long.parseLong(version()));
    }

    /**
     * 두 실제 HTTP 호출을 같은 시작 신호로 실행한다.
     * @created 2026-10-29
     * @usedBy concurrentWrites
     */
    private List<HttpResponse<String>> parallel(String path, ObjectNode first, ObjectNode second) throws Exception {
        try (var executor = Executors.newFixedThreadPool(2)) {
            CountDownLatch start = new CountDownLatch(1);
            var left = executor.submit(() -> { start.await(); return send("PATCH", path, first); });
            var right = executor.submit(() -> { start.await(); return send("PATCH", path, second); });
            start.countDown();
            return List.of(left.get(20, TimeUnit.SECONDS), right.get(20, TimeUnit.SECONDS));
        }
    }

    /**
     * 영수증 단계 SQL 취소에서 앞선 설정·버전이 롤백되고 같은 키 재시도가 성공한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void rollbackOnReceiptFailure() throws Exception {
        String before = version();
        String path = "/accounts/" + account().path("accountId").asString();
        ObjectNode body = command().put("nickname", "취소된 변경");
        String oldNickname = admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class, owner, UUID.fromString(account().path("accountId").asString()));
        admin.execute("""
            CREATE FUNCTION payse.test_receipt_failure() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'isolated cancellation' USING ERRCODE = '57014';
            END $$;
            CREATE TRIGGER test_receipt_failure BEFORE INSERT ON payse.write_receipts
              FOR EACH ROW EXECUTE FUNCTION payse.test_receipt_failure();
            """);
        try {
            error(send("PATCH", path, body), 503, "TEMPORARILY_UNAVAILABLE");
            assertEquals(before, version());
            assertEquals(oldNickname, admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
                String.class, owner, UUID.fromString(account().path("accountId").asString())));
            assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.write_receipts WHERE user_id=? AND operation_key=?",
                Integer.class, owner, body.path("idempotencyKey").asString()));
        } finally {
            admin.execute("DROP TRIGGER test_receipt_failure ON payse.write_receipts");
            admin.execute("DROP FUNCTION payse.test_receipt_failure()");
        }
        ok("PATCH", path, body);
    }

    /**
     * 지연 DB 제약의 최종 실패에서도 앞선 설정·영수증·버전을 함께 되돌린다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void deferredConstraintRollback() throws Exception {
        String before = version();
        ObjectNode body = command().put("nickname", "제약 검증");
        UUID accountId = UUID.fromString(account().path("accountId").asString());
        String oldNickname = admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class, owner, accountId);
        admin.execute("""
            CREATE FUNCTION payse.test_deferred_failure() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              RAISE EXCEPTION 'isolated deferred constraint' USING ERRCODE = '23514';
            END $$;
            CREATE CONSTRAINT TRIGGER test_deferred_failure AFTER UPDATE ON payse.financial_accounts
              DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payse.test_deferred_failure();
            """);
        try {
            error(send("PATCH", "/accounts/" + accountId, body), 409, "RELATION_CONFLICT");
            assertEquals(before, version());
            assertEquals(oldNickname, admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
                String.class, owner, accountId));
            assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.write_receipts WHERE user_id=? AND operation_key=?",
                Integer.class, owner, body.path("idempotencyKey").asString()));
        } finally {
            admin.execute("DROP TRIGGER test_deferred_failure ON payse.financial_accounts");
            admin.execute("DROP FUNCTION payse.test_deferred_failure()");
        }
    }

    /**
     * RLS·원천 쓰기 금지와 인증 없는 저장소 호출 차단을 실제 역할로 검사한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void runtimePermissions() {
        JdbcTemplate runtime = context.getBean(JdbcTemplate.class);
        AuthTransactions transactions = context.getBean(AuthTransactions.class);
        AuthRepository auth = context.getBean(AuthRepository.class);
        String digest = context.getBean(AuthCrypto.class).tokenDigest(token);
        FinancialRepository repository = context.getBean(FinancialRepository.class);
        assertThrows(IllegalStateException.class, () -> repository.load(owner));
        assertEquals(0, transactions.run(() -> runtime.queryForObject("SELECT count(*) FROM payse.financial_accounts", Integer.class)));
        transactions.run(() -> {
            assertTrue(auth.authorize(digest).isPresent());
            UUID foreign = UUID.fromString(foreignSource.path("userId").asString());
            assertEquals(0, runtime.queryForObject("SELECT count(*) FROM payse.financial_accounts WHERE user_id=?", Integer.class, foreign));
            assertEquals(source.path("accounts").size(), repository.load(owner).path("accounts").size());
            assertThrows(IllegalStateException.class, () -> repository.load(foreign));
            return null;
        });
        assertThrows(AuthStoreException.class, () -> transactions.run(() -> {
            auth.authorize(digest).orElseThrow();
            runtime.update("UPDATE payse.financial_accounts SET balance_krw=0 WHERE user_id=?", owner);
            return null;
        }));
        assertEquals(0, transactions.run(() -> runtime.queryForObject("SELECT count(*) FROM payse.financial_accounts", Integer.class)));
    }

    /**
     * JPA 1차 캐시가 다음 사용자의 RLS를 우회하지 않고 명시 flush 후 실패도 원복되는지 검사한다.
     * @created 2026-10-29
     * @usedBy JUnit 실제 PostgreSQL 검사
     */
    @Test
    void entityIsolationAndRollback() {
        EntityManager entityManager = context.getBean(EntityManager.class);
        AuthTransactions transactions = context.getBean(AuthTransactions.class);
        AuthRepository auth = context.getBean(AuthRepository.class);
        AuthCrypto crypto = context.getBean(AuthCrypto.class);
        UUID accountId = UUID.fromString(account().path("accountId").asString());
        UUID foreign = UUID.fromString(foreignSource.path("userId").asString());
        var foreignToken = crypto.issueToken();
        assertEquals(1, admin.update("UPDATE payse.users SET code_verifier=? WHERE id=?",
            crypto.codeVerifier(foreign, code), foreign));
        transactions.run(() -> auth.openSession(foreign, foreignToken.digest()).orElseThrow());
        Object firstContext = transactions.run(() -> {
            auth.authorize(crypto.tokenDigest(token)).orElseThrow();
            AccountEntity account = entityManager.find(AccountEntity.class, accountId);
            assertNotNull(account);
            assertEquals(owner, account.userId());
            return entityManager.getDelegate();
        });
        transactions.run(() -> {
            auth.authorize(foreignToken.digest()).orElseThrow();
            assertNotSame(firstContext, entityManager.getDelegate());
            assertNull(entityManager.find(AccountEntity.class, accountId));
            return null;
        });
        String oldNickname = admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class, owner, accountId);
        String before = version();
        assertThrows(IllegalStateException.class, () -> transactions.run(() -> {
            auth.authorize(crypto.tokenDigest(token)).orElseThrow();
            entityManager.find(AccountEntity.class, accountId).rename("롤백 확인");
            entityManager.flush();
            throw new IllegalStateException("intentional isolated rollback");
        }));
        assertEquals(oldNickname, admin.queryForObject("SELECT nickname FROM payse.financial_accounts WHERE user_id=? AND id=?",
            String.class, owner, accountId));
        assertEquals(before, version());
    }

    /**
     * 재로그인에서도 설정을 유지하며 이전 세션·변조·구 버전 cursor를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void reloginAndCursor() throws Exception {
        String cursor = ok("GET", "/snapshot", null).path("page").path("nextCursor").asString();
        assertNotNull(cursor);
        error(send("GET", "/transactions?cursor=broken", null), 400, "INVALID_CURSOR");
        ok("PATCH", "/accounts/" + account().path("accountId").asString(), command().put("nickname", "다시 접속"));
        error(send("GET", "/transactions?cursor=" + cursor, null), 409, "STALE_DATA");
        cursor = ok("GET", "/snapshot", null).path("page").path("nextCursor").asString();
        HttpResponse<String> logout = send("DELETE", "/demo-sessions/current", null);
        assertEquals(204, logout.statusCode());
        error(send("GET", "/snapshot", null), 401, "SESSION_INVALID");
        token = login();
        error(send("GET", "/transactions?cursor=" + cursor, null), 403, "RESOURCE_FORBIDDEN");
        JsonNode restored = ok("GET", "/snapshot", null);
        JsonNode saved = single(restored.path("accounts"), value -> value.path("accountId").equals(account().path("accountId")));
        assertEquals("다시 접속", saved.path("nickname").asString());
    }

    /**
     * 미지원 원천 형식을 v3로 위장하지 않고 서버 계산 필드 없이 실패한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void unsupportedSourceVersion() throws Exception {
        admin.update("UPDATE payse.source_contexts SET schema_version='PAYSE-DRAFT-4' WHERE user_id=?", owner);
        try { error(send("GET", "/snapshot", null), 503, "TEMPORARILY_UNAVAILABLE"); }
        finally { admin.update("UPDATE payse.source_contexts SET schema_version='PAYSE-DRAFT-3' WHERE user_id=?", owner); }
    }

    /**
     * 유효 인증이 먼저 필요하며 잘못된 입력·본문 상한을 원자 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void invalidHttpInput() throws Exception {
        error(send("PATCH", "/settings", "{", "bad-token", Map.of()), 401, "SESSION_INVALID");
        error(send("PATCH", "/settings", "{", token, Map.of()), 400, "INVALID_JSON");
        error(send("PATCH", "/settings", " ".repeat(65537), token, Map.of()), 413, "REQUEST_TOO_LARGE");
        error(send("GET", "/transactions", null), 400, "INVALID_CURSOR");
        error(send("GET", "/snapshot?limit=2", null), 422, "VALIDATION_FAILED");
    }
}
