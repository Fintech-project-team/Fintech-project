package com.payse.api.auth;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.payse.api.PayseApiApplication;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.net.InetAddress;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
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

/**
 * 실제 HTTP와 최소 권한 PostgreSQL로 인증 계약·순서·경합·롤백을 확인한다.
 * @created 2026-10-28
 * @usedBy test_session_service.py가 실행하는 Gradle JUnit
 */
class AuthHttpTest {
    private ConfigurableApplicationContext context;
    private HikariDataSource adminPool;
    private JdbcTemplate admin;
    private AuthCrypto crypto;
    private HttpClient client;
    private String base;
    private User user;
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 새로 준비한 사용자·합성 자격 묶음이다. 값은 외부로 출력하지 않는다.
     * @created 2026-10-28
     * @usedBy AuthHttpTest.newUser, body
     */
    private record User(UUID id, String name, String phone, String code) {
        /**
         * 테스트 실패 문자열에서도 자격을 숨긴다.
         * @created 2026-10-28
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "User[REDACTED]"; }
    }

    /**
     * 명시된 폐기용 DB와 검사 역할 외의 연결을 거절한다.
     * @created 2026-10-28
     * @usedBy JUnit BeforeAll
     */
    @BeforeAll
    static void requireDatabase() {
        assumeFalse(System.getenv().keySet().stream().noneMatch(key -> key.startsWith("PAYSE_SESSION_TEST_")),
            "Run test_session_service.py with an isolated PostgreSQL directory");
        assertTrue(setting("JDBC_URL").matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_sessions"));
        assertTrue(setting("DB_USER").matches("payse_session_[0-9a-f]{32}"));
        assertTrue(setting("ADMIN_USER").matches("payse_session_setup_[0-9a-f]{32}"));
    }

    /**
     * 일부만 지정한 검사 환경은 건너뛰지 않고 실패시킨다.
     * @created 2026-10-28
     * @usedBy requireDatabase, start
     */
    private static String setting(String suffix) {
        String value = System.getenv("PAYSE_SESSION_TEST_" + suffix);
        assertTrue(value != null && !value.isBlank(), "Missing isolated test setting: " + suffix);
        return value;
    }

    /**
     * 새 키·사용자로 실제 서버를 loopback 임의 포트에서 시작한다.
     * @created 2026-10-28
     * @usedBy JUnit BeforeEach
     */
    @BeforeEach
    void start() {
        SecureRandom random = new SecureRandom();
        byte[] codeKey = new byte[32];
        byte[] limitKey = new byte[32];
        random.nextBytes(codeKey);
        random.nextBytes(limitKey);
        Map<String, Object> properties = new HashMap<>();
        properties.put("server.port", "0");
        properties.put("server.address", "127.0.0.1");
        properties.put("spring.main.banner-mode", "off");
        properties.put("PAYSE_AUTH_PEER_MODE", "direct");
        properties.put("PAYSE_JDBC_URL", setting("JDBC_URL"));
        properties.put("PAYSE_DB_USER", setting("DB_USER"));
        properties.put("PAYSE_DB_PASSWORD", setting("DB_PASSWORD"));
        properties.put("PAYSE_DB_MAX_POOL_SIZE", "6");
        properties.put("PAYSE_DB_CONNECTION_TIMEOUT_MS", "3000");
        properties.put("PAYSE_DB_VALIDATION_TIMEOUT_MS", "1000");
        properties.put("PAYSE_AUTH_CODE_KEY_ID", "http-test");
        properties.put("PAYSE_AUTH_CODE_KEY_BASE64", Base64.getEncoder().encodeToString(codeKey));
        properties.put("PAYSE_AUTH_LIMIT_KEY_BASE64", Base64.getEncoder().encodeToString(limitKey));
        SpringApplication app = new SpringApplication(PayseApiApplication.class);
        app.setAdditionalProfiles("database", "auth");
        app.setDefaultProperties(properties);
        context = app.run();
        base = "http://127.0.0.1:" + ((WebServerApplicationContext) context).getWebServer().getPort();
        crypto = context.getBean(AuthCrypto.class);
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(setting("JDBC_URL"));
        config.setUsername(setting("ADMIN_USER"));
        config.setPassword(setting("ADMIN_PASSWORD"));
        config.setMaximumPoolSize(2);
        adminPool = new HikariDataSource(config);
        admin = new JdbcTemplate(adminPool);
        user = newUser();
        client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
    }

    /**
     * 테스트가 생성한 서버·클라이언트·관리 연결만 닫는다.
     * @created 2026-10-28
     * @usedBy JUnit AfterEach
     */
    @AfterEach
    void stop() {
        if (client != null) client.close();
        if (context != null) context.close();
        if (adminPool != null) adminPool.close();
    }

    /**
     * 고정 UUID·표시명 조회 대신 생성한 ID와 검증한 관계를 사용한다.
     * @created 2026-10-28
     * @usedBy start, crossUserReverification
     */
    private User newUser() {
        UUID id = UUID.randomUUID();
        String suffix = id.toString().replace("-", "").substring(0, 12);
        for (int digit = 0; digit < 10; digit++) suffix = suffix.replace((char) ('0' + digit), (char) ('k' + digit));
        SecureRandom random = new SecureRandom();
        User prepared = new User(id, "사용자" + suffix,
            "010" + String.format(Locale.ROOT, "%08d", random.nextInt(100_000_000)),
            String.format(Locale.ROOT, "%06d", random.nextInt(1_000_000)));
        assertEquals(1, admin.update("""
            INSERT INTO payse.users(id, name, phone, code_verifier, data_version, created_at)
            VALUES (?, ?, ?, ?, 1, clock_timestamp())
            """, prepared.id(), prepared.name(), prepared.phone(), crypto.codeVerifier(prepared.id(), prepared.code())));
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.users WHERE id=? AND name=? AND phone=?",
            Integer.class, prepared.id(), prepared.name(), prepared.phone()));
        return prepared;
    }

    /**
     * 검증용 자격을 JSON 문자열로 작성한다. 원문을 로그에 쓰지 않는다.
     * @created 2026-10-28
     * @usedBy HTTP 인증 검사
     */
    private String body(User account) {
        return json.writeValueAsString(Map.of("name", account.name(), "phone", account.phone(), "code", account.code()));
    }

    /**
     * 제한된 테스트 서버에 실제 요청을 보내고 공통 응답 보안 헤더를 검사한다.
     * @created 2026-10-28
     * @usedBy 각 HTTP 검사
     */
    private HttpResponse<String> send(String method, String path, String body, String token, Map<String, String> headers)
            throws Exception {
        var request = HttpRequest.newBuilder(URI.create(base + path)).timeout(Duration.ofSeconds(10));
        request.header("Content-Type", headers.getOrDefault("Content-Type", "application/json; charset=utf-8"));
        if (token != null) request.header("Authorization", "Bearer " + token);
        headers.forEach((name, value) -> {
            if (!name.equals("Content-Type")) request.header(name, value);
        });
        request.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body));
        var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertEquals("no-store", response.headers().firstValue("Cache-Control").orElse(""));
        assertTrue(response.headers().allValues("Set-Cookie").isEmpty());
        return response;
    }

    /**
     * 오류 모양과 민감 원문 비노출을 확인한다. 오류 텍스트를 재출력하지 않는다.
     * @created 2026-10-28
     * @usedBy 오류·권한·제한 검사
     */
    private void error(HttpResponse<String> response, int status, String code) {
        assertEquals(status, response.statusCode());
        JsonNode problem = json.readTree(response.body()).get("error");
        assertNotNull(problem);
        assertEquals(code, problem.get("code").asString());
        assertDoesNotThrow(() -> UUID.fromString(problem.get("requestId").asString()));
        assertTrue(problem.get("details").isArray());
        assertEquals(0, problem.get("details").size());
        for (String secret : List.of(user.name(), user.phone(), user.code(), "SELECT ", "Exception", "accessToken")) {
            assertFalse(response.body().contains(secret));
        }
        if (status == 401) assertEquals("Bearer", response.headers().firstValue("WWW-Authenticate").orElse(""));
    }

    /**
     * 준비한 계정으로 최초 로그인하고 저장된 사용자·이름·토큰 형식을 확인한다.
     * @created 2026-10-28
     * @usedBy 정상·재확인·종료 검사
     */
    private String login() throws Exception {
        var response = send("POST", "/demo-sessions", body(user), null, Map.of());
        assertEquals(201, response.statusCode());
        JsonNode result = json.readTree(response.body());
        assertEquals(6, result.size());
        assertEquals(user.id().toString(), result.get("userId").asString());
        assertEquals(user.name(), result.get("name").asString());
        assertEquals("Bearer", result.get("tokenType").asString());
        return result.get("accessToken").asString();
    }

    /**
     * 원격 IP의 HMAC으로 기록 건수를 읽어 중복 집계를 감지한다.
     * @created 2026-10-28
     * @usedBy 요청 제한·롤백 검사
     */
    private int ipEvents() throws Exception {
        String key = crypto.ipLimitKey(InetAddress.getByAddress(new byte[] {127, 0, 0, 1}));
        return admin.queryForObject("""
            SELECT coalesce((SELECT cardinality(event_times) FROM payse.auth_rate_limits
              WHERE kind='ip' AND key_digest=?), 0)
            """, Integer.class, key);
    }

    /**
     * 생성·재확인·종료와 재로그인을 실제 DB에서 수행한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void lifecycle() throws Exception {
        String token = login();
        error(send("POST", "/demo-sessions", body(user), null, Map.of()), 401, "AUTH_REJECTED");
        var verified = send("POST", "/demo-sessions/current/reverify", body(user), token, Map.of());
        assertEquals(200, verified.statusCode());
        JsonNode result = json.readTree(verified.body());
        assertEquals(3, result.size());
        assertTrue(result.get("verified").asBoolean());
        assertFalse(verified.body().contains("accessToken"));
        var ended = send("DELETE", "/demo-sessions/current", null, token, Map.of());
        assertEquals(204, ended.statusCode());
        assertEquals("", ended.body());
        error(send("DELETE", "/demo-sessions/current", null, token, Map.of()), 401, "SESSION_INVALID");
        assertNotEquals(token, login());
        assertEquals(4, ipEvents());
    }

    /**
     * 종료된/누락 토큰은 본문 오류보다 먼저 거절하고 IP는 각각 한 번 기록한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void invalidTokenPrecedesInput() throws Exception {
        String token = login();
        assertEquals(204, send("DELETE", "/demo-sessions/current", null, token, Map.of()).statusCode());
        for (String bad : List.of("{", "{}", "x".repeat(4097))) {
            error(send("POST", "/demo-sessions/current/reverify", bad, token, Map.of()), 401, "SESSION_INVALID");
        }
        error(send("POST", "/demo-sessions/current/reverify", body(user), null, Map.of()), 401, "SESSION_INVALID");
        assertEquals(5, ipEvents());
    }

    /**
     * 구문·중복 JSON 키·알 수 없는 필드·타입·null을 원문 노출 없이 거절한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void strictInput() throws Exception {
        String valid = body(user);
        for (String bad : List.of("", "\n ", "{", valid + " {}", valid.replace("{", "{\"name\":\"중복이름\","))) {
            error(send("POST", "/demo-sessions", bad, null, Map.of()), 400, "INVALID_JSON");
        }
        for (String bad : List.of("null", "[]", "{}", valid.replace("{", "{\"installationId\":\"unused\","),
                valid.replace("\"" + user.code() + "\"", "123456"),
                valid.replace("\"" + user.code() + "\"", "null"))) {
            error(send("POST", "/demo-sessions", bad, null, Map.of()), 422, "VALIDATION_FAILED");
        }
        assertEquals(11, ipEvents());
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.demo_sessions WHERE user_id=?", Integer.class, user.id()));
    }

    /**
     * 바이트 경계 4096은 허용하고 4097은 거절한다. 잘린 본문으로 저장하지 않는다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void bodyByteLimit() throws Exception {
        String valid = body(user);
        int padding = 4096 - valid.getBytes(StandardCharsets.UTF_8).length;
        error(send("POST", "/demo-sessions", valid + " ".repeat(padding + 1), null, Map.of()), 413, "REQUEST_TOO_LARGE");
        assertEquals(201, send("POST", "/demo-sessions", valid + " ".repeat(padding), null, Map.of()).statusCode());
        assertEquals(2, ipEvents());
    }

    /**
     * 61번째 IP 요청은 위조 전달 헤더로 우회하지 못하고 저장된 제한을 따른다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void forwardedHeadersCannotBypassLimits() throws Exception {
        for (int index = 0; index < 60; index++) {
            error(send("POST", "/demo-sessions", "{", null,
                Map.of("X-Forwarded-For", "192.0.2." + index, "Forwarded", "for=198.51.100.7")), 400, "INVALID_JSON");
        }
        var response = send("POST", "/demo-sessions", body(user), null, Map.of("X-Real-IP", "203.0.113.8"));
        error(response, 429, "RATE_LIMITED");
        long retry = Long.parseLong(response.headers().firstValue("Retry-After").orElseThrow());
        assertTrue(retry >= 1 && retry <= 60);
        assertEquals(60, ipEvents());
    }

    /**
     * 코드 실패 5회 차단은 숫자형 코드로 우회하지 못하고 재시도 초를 올림한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void combinationLimitPrecedesCodeFormat() throws Exception {
        String wrong = user.code().equals("000000") ? "000001" : "000000";
        String body = json.writeValueAsString(Map.of("name", user.name(), "phone", user.phone(), "code", wrong));
        for (int index = 1; index < 5; index++) error(send("POST", "/demo-sessions", body, null, Map.of()), 401, "AUTH_REJECTED");
        Instant sentAt = Instant.now();
        var blocked = send("POST", "/demo-sessions", body, null, Map.of());
        Instant receivedAt = Instant.now();
        error(blocked, 429, "RATE_LIMITED");
        long retry = Long.parseLong(blocked.headers().firstValue("Retry-After").orElseThrow());
        Instant retryAt = admin.queryForObject("""
            SELECT blocked_until FROM payse.auth_rate_limits WHERE kind='combo' AND key_digest=?
            """, OffsetDateTime.class, crypto.combinationLimitKey(user.name(), user.phone())).toInstant();
        // DB와 JVM의 시계 정밀도가 다를 수 있다. 전송 구간의 올림값을 검사하고 DB 정책 검사는 별도로 유지한다.
        long earliest = Math.max(1, (long) Math.ceil(Duration.between(receivedAt, retryAt).toNanos() / 1_000_000_000.0));
        long latest = Math.max(1, (long) Math.ceil(Duration.between(sentAt, retryAt).toNanos() / 1_000_000_000.0));
        assertTrue(retry >= earliest && retry <= latest, "Retry-After outside response interval");
        error(send("POST", "/demo-sessions", body(user).replace("\"" + user.code() + "\"", "123456"), null, Map.of()),
            429, "RATE_LIMITED");
        assertEquals(6, ipEvents());
    }

    /**
     * 다른 사용자 자격으로 기존 토큰을 재확인해도 세션 소유자가 바뀌지 않는다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void crossUserReverification() throws Exception {
        String token = login();
        User other = newUser();
        error(send("POST", "/demo-sessions/current/reverify", body(other), token, Map.of()), 401, "AUTH_REJECTED");
        assertEquals(200, send("POST", "/demo-sessions/current/reverify", body(user), token, Map.of()).statusCode());
    }

    /**
     * 와일드카드·비JSON·압축 본문을 허용하지 않고 요청을 한 번씩 기록한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void rejectsOtherContentTypes() throws Exception {
        for (String type : List.of("*/*", "application/*", "text/plain", "application/json; charset=iso-8859-1")) {
            error(send("POST", "/demo-sessions", body(user), null, Map.of("Content-Type", type)), 422, "VALIDATION_FAILED");
        }
        error(send("POST", "/demo-sessions", body(user), null, Map.of("Content-Encoding", "gzip")), 422, "VALIDATION_FAILED");
        assertEquals(5, ipEvents());
    }

    /**
     * 유효한 세션도 중복 Authorization·본문이 있는 종료 요청을 우회하지 못한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void rejectsAmbiguousAuthorizationAndLogoutBody() throws Exception {
        String token = login();
        error(send("POST", "/demo-sessions/current/reverify", body(user), token,
            Map.of("Authorization", "Basic invalid")), 401, "SESSION_INVALID");
        error(send("DELETE", "/demo-sessions/current", "{}", token, Map.of()), 422, "VALIDATION_FAILED");
        assertEquals(200, send("POST", "/demo-sessions/current/reverify", body(user), token, Map.of()).statusCode());
    }

    /**
     * 동시에 들어온 로그인 중 하나만 성공하고 실제 활성 세션도 하나다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void concurrentLogin() throws Exception {
        try (var pool = Executors.newFixedThreadPool(2)) {
            CountDownLatch start = new CountDownLatch(1);
            var first = pool.submit(() -> { start.await(); return send("POST", "/demo-sessions", body(user), null, Map.of()); });
            var second = pool.submit(() -> { start.await(); return send("POST", "/demo-sessions", body(user), null, Map.of()); });
            start.countDown();
            var statuses = List.of(first.get(10, TimeUnit.SECONDS).statusCode(), second.get(10, TimeUnit.SECONDS).statusCode());
            assertEquals(1, statuses.stream().filter(status -> status == 201).count());
            assertEquals(1, statuses.stream().filter(status -> status == 401).count());
        }
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.demo_sessions WHERE user_id=? AND ended_at IS NULL",
            Integer.class, user.id()));
        assertEquals(2, ipEvents());
    }

    /**
     * 실제 DB 커밋 실패 시 토큰을 반환하지 않고 세션은 롤백하되 IP 기록은 유지한다.
     * @created 2026-10-28
     * @usedBy JUnit test
     */
    @Test
    void commitFailureReturnsNoToken() throws Exception {
        String name = "http_fail_" + UUID.randomUUID().toString().replace("-", "");
        // 검증 도구가 생성한 식별자·UUID만 사용하며 이 소유 DB 밖에서는 실행하지 않는다.
        admin.execute("""
            CREATE FUNCTION payse.%s() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NEW.user_id='%s'::uuid THEN
                RAISE EXCEPTION 'Isolated commit failure' USING ERRCODE='23514';
              END IF;
              RETURN NEW;
            END $$
            """.formatted(name, user.id()));
        admin.execute("""
            CREATE CONSTRAINT TRIGGER %s AFTER INSERT ON payse.demo_sessions
              DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION payse.%s()
            """.formatted(name, name));
        try {
            error(send("POST", "/demo-sessions", body(user), null, Map.of()), 503, "TEMPORARILY_UNAVAILABLE");
            assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.demo_sessions WHERE user_id=?", Integer.class, user.id()));
            assertEquals(1, ipEvents());
        } finally {
            admin.execute("DROP TRIGGER " + name + " ON payse.demo_sessions");
            admin.execute("DROP FUNCTION payse." + name + "()");
        }
        login();
    }
}
