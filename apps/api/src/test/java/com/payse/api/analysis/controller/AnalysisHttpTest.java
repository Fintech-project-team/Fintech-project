package com.payse.api.analysis.controller;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.payse.api.PayseApiApplication;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.service.AnalysisIdentity;
import com.payse.api.analysis.service.AnalysisJobs;
import com.payse.api.analysis.service.AnalysisRuntime;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.mapper.FinancialRepository;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.time.Clock;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.ZoneOffset;
import java.time.temporal.ChronoUnit;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.HashSet;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Predicate;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 폐기 PostgreSQL·실제 loopback HTTP로 분석 저장·복구·격리·삭제를 검증한다. 공급자/KMS만 대역이다.
 * @created 2026-11-01
 * @usedBy test_analysis_service.py의 Gradle JUnit
 */
class AnalysisHttpTest {
    private static final String RESULT_TEXT = "검증용 분석 본문은 암호화 저장됩니다";
    private final JsonMapper json = JsonMapper.builder().build();
    private ConfigurableApplicationContext context;
    private HikariDataSource adminPool;
    private JdbcTemplate admin;
    private HttpClient client;
    private Map<String, Object> properties;
    private Map<String, String> financialBefore;
    private String base;
    private String token;
    private String code;
    private UUID owner;
    private JsonNode credentials;
    private ObjectNode source;
    private ObjectNode input;
    private ControlledModel model;
    private TestClock clock;
    private TestKeys testKeys;

    /**
     * 기존 서비스 DB에 접속하지 않고 전용 실행기가 만든 폐기 DB 이름·로그인만 허용한다.
     * @created 2026-11-01
     * @usedBy JUnit BeforeAll
     */
    @BeforeAll
    static void requireDatabase() {
        assumeFalse(System.getenv().keySet().stream().noneMatch(key -> key.startsWith("PAYSE_ANALYSIS_TEST_")),
            "Run the analysis integration runner with an isolated PostgreSQL directory");
        assertTrue(setting("JDBC_URL").matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_analysis"));
        assertTrue(setting("DB_USER").matches("payse_analysis_[0-9a-f]{32}"));
        assertTrue(setting("ADMIN_USER").matches("payse_analysis_setup_[0-9a-f]{32}"));
    }

    /**
     * 일부 환경만 지정된 검사를 성공·건너뛰기로 숨기지 않는다.
     * @created 2026-11-01
     * @usedBy requireDatabase, start
     */
    private static String setting(String name) {
        String value = System.getenv("PAYSE_ANALYSIS_TEST_" + name);
        assertTrue(value != null && !value.isBlank(), "Missing isolated analysis setting: " + name);
        return value;
    }

    /**
     * 폐기 DB만 재적재하고 합성 인증으로 로그인한 뒤 실제 저장 원천을 읽는다.
     * @created 2026-11-01
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
        assertEquals("payse_auth_test_analysis", admin.queryForObject("SELECT current_database()", String.class));
        admin.execute("TRUNCATE payse.users CASCADE");
        admin.execute("TRUNCATE payse.auth_rate_limits");
        prepareSeed();
        JsonNode fixture = json.readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots/demo-life.json")));
        owner = UUID.fromString(fixture.path("userId").asString());
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.users WHERE id=?", Integer.class, owner));
        credentials = credentials(owner);
        properties = new HashMap<>();
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
        properties.put("PAYSE_AUTH_CODE_KEY_ID", "analysis-test");
        SecureRandom random = new SecureRandom();
        for (String key : List.of("PAYSE_AUTH_CODE_KEY_BASE64", "PAYSE_AUTH_LIMIT_KEY_BASE64", "PAYSE_FINANCE_CURSOR_KEY_BASE64")) {
            byte[] bytes = new byte[32];
            random.nextBytes(bytes);
            properties.put(key, Base64.getEncoder().encodeToString(bytes));
        }
        launch(true);
        code = String.format(java.util.Locale.ROOT, "%06d", random.nextInt(1_000_000));
        setCode(owner, code);
        client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        token = login(credentials, code);
        source = source(token);
        assertEquals("PAYSE-DRAFT-4", source.path("schemaVersion").asString());
        input = meaningInput(source, 10);
        financialBefore = fingerprint();
    }

    /**
     * 분석 프로필 여부를 구분하고 실제 운영 공급자 대신 테스트 구성만 명시 주입한다.
     * @created 2026-11-01
     * @usedBy start, disabledProfile
     */
    private void launch(boolean analysis) {
        SpringApplication app = analysis
            ? new SpringApplication(PayseApiApplication.class, RuntimeConfig.class)
            : new SpringApplication(PayseApiApplication.class);
        app.setAdditionalProfiles(analysis ? new String[]{"database", "auth", "finance", "analysis"}
            : new String[]{"database", "auth", "finance"});
        app.setDefaultProperties(properties);
        context = app.run();
        base = "http://127.0.0.1:" + ((WebServerApplicationContext) context).getWebServer().getPort();
        if (analysis) {
            model = context.getBean(ControlledModel.class);
            clock = context.getBean(TestClock.class);
            testKeys = context.getBean(TestKeys.class);
        }
    }

    /**
     * 연간 자료 적재만 같은 JDBC 연결에서 별도 제한을 설정한다. 제품 요청의 12초 제한은 유지한다.
     * @created 2026-11-01
     * @usedBy start
     * @modified 2026-11-01 - 준비용 통계를 최종 제약 검사 전에 갱신해 반복 재적재 지연 완화
     */
    private void prepareSeed() throws Exception {
        String seed = Files.readString(Path.of(setting("SEED_FILE")));
        var boundary = java.util.regex.Pattern.compile("(?m)^SET CONSTRAINTS ALL IMMEDIATE;\\r?$");
        assertEquals(1L, boundary.matcher(seed).results().count(), "Expected one final seed validation boundary");
        // 폐기 DB의 통계만 갱신한다. 원천 값·제약·RLS·커밋 경계는 동일하게 유지한다.
        String prepared = boundary.matcher(seed).replaceFirst("ANALYZE;\n$0");
        admin.execute((org.springframework.jdbc.core.ConnectionCallback<Void>) connection -> {
            try (var statement = connection.createStatement()) {
                statement.execute("SET statement_timeout = '120s'");
                try { statement.execute(prepared); }
                finally {
                    statement.execute("ROLLBACK");
                    statement.execute("SET statement_timeout = '12s'");
                }
            }
            return null;
        });
    }

    /**
     * 비동기 작업을 해제·종료한 뒤 금융 불변을 확인하고 이 검사 소유 연결만 닫는다.
     * @created 2026-11-01
     * @usedBy JUnit AfterEach
     * @modified 2026-11-01 - 기억 목록의 복호화 경합 대기도 종료 전에 해제
     */
    @AfterEach
    void stop() throws Exception {
        try {
            if (model != null) model.release.countDown();
            if (testKeys != null) testKeys.unwrapRelease.countDown();
            if (context != null) context.close();
            if (financialBefore != null) assertEquals(financialBefore, fingerprint(), "Financial data changed");
        } finally {
            if (client != null) client.close();
            if (adminPool != null) adminPool.close();
        }
    }

    /**
     * 실제 접수·상태·본문·암호화 저장·결과 조회와 새 itemKey의 무호출 재사용을 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void storesAndReusesEncryptedResults() throws Exception {
        ObjectNode accepted = accept(input, key());
        assertFalse(accepted.has("result"));
        String job = accepted.path("jobId").asString();
        submit(job, input, key(), false, false);
        ObjectNode completed = await(job, "succeeded");
        assertFalse(completed.has("result"));
        ObjectNode result = query(input, null, token);
        assertEquals("available", result.path("resultAvailability").asString());
        assertEquals(10, result.path("result").path("items").size());
        assertTrue(result.toString().contains(RESULT_TEXT));
        assertEquals(1, model.calls.get());
        assertEquals(10, admin.queryForObject("SELECT count(*) FROM payse.analysis_items WHERE user_id=? AND ciphertext IS NOT NULL", Integer.class, owner));
        for (String table : List.of("analysis_jobs", "analysis_attempts", "analysis_results", "analysis_items")) {
            String persisted = admin.queryForObject("SELECT coalesce(jsonb_agg(to_jsonb(t))::text,'[]') FROM payse." + table + " t WHERE user_id=?", String.class, owner);
            assertFalse(persisted.contains(RESULT_TEXT), table + " persisted plaintext");
            assertFalse(persisted.contains("merchantName"), table + " persisted financial input");
        }
        ObjectNode renamed = input.deepCopy();
        for (JsonNode item : renamed.path("items")) ((ObjectNode) item).put("itemKey", "new-screen:" + item.path("itemKey").asString());
        ((ObjectNode) renamed.path("context")).put("inputRevision", 8).put("localSessionEpoch", 9);
        ObjectNode reused = query(renamed, result.path("resultId").asString(), token);
        assertEquals("available", reused.path("resultAvailability").asString());
        for (JsonNode item : reused.path("result").path("items")) assertTrue(item.path("interpretation").path("itemKey").asString().startsWith("new-screen:"));
        assertEquals(1, model.calls.get());
    }

    /**
     * 로그아웃·새 세션 이후에도 같은 사용자의 유효 기억을 모델 호출 없이 복구한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void reusesAfterRelogin() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode original = query(input, null, token);
        assertEquals(204, send("DELETE", "/demo-sessions/current", null, token, null).statusCode());
        String previous = token;
        token = login(credentials, code);
        assertNotEquals(previous, token);
        ((ObjectNode) input.path("context")).put("localSessionEpoch", 2);
        ObjectNode recovered = query(input, original.path("resultId").asString(), token);
        assertEquals("available", recovered.path("resultAvailability").asString());
        assertEquals(original.path("resultId"), recovered.path("resultId"));
        assertEquals(1, model.calls.get());
    }

    /**
     * 다른 사용자는 작업·결과·기억을 조회하거나 삭제하지 못하며 자기 캐시도 섞이지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void isolatesUsers() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode result = query(input, null, token);
        JsonNode fixture = json.readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots/beta-ready.json")));
        UUID other = UUID.fromString(fixture.path("userId").asString());
        assertNotEquals(owner, other);
        setCode(other, code);
        String otherToken = login(credentials(other), code);
        ObjectNode otherInput = meaningInput(source(otherToken), 10);
        assertEquals(403, send("GET", "/analysis-jobs/" + job, null, otherToken, null).statusCode());
        assertEquals(403, send("POST", "/analysis-results/query", queryBody(otherInput, result.path("resultId").asString()).toString(), otherToken, null).statusCode());
        JsonNode first = result.path("result").path("items").get(0);
        assertEquals(403, send("DELETE", "/analysis-memories/" + first.path("itemId").asString(), null, otherToken, key()).statusCode());
        assertEquals("missing", query(otherInput, null, otherToken).path("resultAvailability").asString());
        assertEquals(1, model.calls.get());
    }

    /**
     * 동시 제출·동일 키 재전송은 시도 한 건만 만들고 같은 키의 다른 접수 내용은 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void serializesIdempotentSubmissions() throws Exception {
        String intakeKey = key();
        ObjectNode descriptor = descriptor(input, intakeKey);
        ObjectNode accepted = body(send("POST", "/analysis-jobs", descriptor.toString(), token, null), 202);
        String job = accepted.path("jobId").asString();
        assertEquals(job, body(send("POST", "/analysis-jobs", descriptor.toString(), token, null), 200).path("jobId").asString());
        ObjectNode changed = descriptor.deepCopy().put("triggerKind", "B");
        assertEquals(409, send("POST", "/analysis-jobs", changed.toString(), token, null).statusCode());
        ObjectNode permit = permit(job);
        ObjectNode request = submission(input, key(), permit.path("permit").asString());
        model.block();
        try (var pool = Executors.newFixedThreadPool(2)) {
            var first = pool.submit(() -> send("POST", "/analysis-jobs/" + job + "/input", request.toString(), token, null));
            var second = pool.submit(() -> send("POST", "/analysis-jobs/" + job + "/input", request.toString(), token, null));
            List<Integer> codes = new ArrayList<>(List.of(first.get(15, TimeUnit.SECONDS).statusCode(), second.get(15, TimeUnit.SECONDS).statusCode()));
            codes.sort(Integer::compareTo);
            assertEquals(List.of(200, 202), codes);
        } finally { model.release.countDown(); }
        await(job, "succeeded");
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?", Integer.class, owner, UUID.fromString(job)));
        assertEquals(1, model.calls.get());
    }

    /**
     * 검증 실패 응답은 저장 성공으로 바꾸지 않고 사용자 재시도에서만 다시 생성한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void retriesFailedOutputOnlyOnRequest() throws Exception {
        model.failure = "invalid";
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "failed");
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_results WHERE user_id=?", Integer.class, owner));
        assertEquals(1, model.calls.get());
        model.failure = "none";
        submit(job, input, key(), true, false);
        await(job, "succeeded");
        assertEquals(2, model.calls.get());
    }

    /**
     * 전송 결과 불명은 중복 위험 확인 없이 재전송하지 않고 명시 확인 후 한 번 재시도한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void requiresUnknownAcknowledgement() throws Exception {
        model.failure = "unknown";
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "outcomeUnknown");
        ObjectNode noConsent = submission(input, key(), null).put("acknowledgeDuplicateRisk", false);
        assertEquals(409, send("POST", "/analysis-jobs/" + job + "/retry", noConsent.toString(), token, null).statusCode());
        assertEquals(1, model.calls.get());
        model.failure = "none";
        submit(job, input, key(), true, true);
        await(job, "succeeded");
        assertEquals(2, model.calls.get());
    }

    /**
     * 늦은 새 묶음 결과가 도착해도 사용자가 지운 동일 기억을 재보존하거나 노출하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void deletionWinsOverLateResult() throws Exception {
        String firstJob = accept(input, key()).path("jobId").asString();
        submit(firstJob, input, key(), false, false);
        await(firstJob, "succeeded");
        ObjectNode original = query(input, null, token);
        String firstKey = input.path("items").get(0).path("itemKey").asString();
        JsonNode memory = unique(original.path("result").path("items"), row -> firstKey.equals(row.path("interpretation").path("itemKey").asString()));
        clock.advance(Duration.ofMillis(1));
        ObjectNode expanded = meaningInput(source, 11);
        String lateJob = accept(expanded, key()).path("jobId").asString();
        model.block();
        submit(lateJob, expanded, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        String deleteKey = key(), itemId = memory.path("itemId").asString();
        assertEquals(204, send("DELETE", "/analysis-memories/" + itemId, null, token, deleteKey).statusCode());
        assertEquals(204, send("DELETE", "/analysis-memories/" + itemId, null, token, deleteKey).statusCode());
        model.release.countDown();
        await(lateJob, "succeeded");
        ObjectNode result = query(expanded, null, token);
        assertEquals("partial", result.path("resultAvailability").asString());
        assertEquals(10, result.path("result").path("items").size());
        JsonNode status = unique(result.path("result").path("itemAvailability"), row -> firstKey.equals(row.path("itemKey").asString()));
        assertEquals("deleted", status.path("state").asString());
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.analysis_suppressions WHERE user_id=?", Integer.class, owner));
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.analysis_items WHERE user_id=? AND id=? AND ciphertext IS NULL AND crypto_meta IS NULL AND deleted_at IS NOT NULL", Integer.class, owner, UUID.fromString(itemId)));
    }

    /**
     * 무효 세션은 잘못된 본문보다 우선하며 인증된 요청은 64KiB를 넘기면 접수하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void authenticatesBeforeReadingBody() throws Exception {
        assertEquals(401, send("POST", "/analysis-jobs", "{broken", "invalid", null).statusCode());
        String oversized = " ".repeat(65537);
        assertEquals(413, send("POST", "/analysis-jobs", oversized, token, null).statusCode());
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_jobs", Integer.class));
        assertEquals(0, model.calls.get());
    }

    /**
     * 분석 프로필이 없으면 경로를 열지 않고 기존 금융 조회는 계속 제공한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void disabledProfile() throws Exception {
        context.close();
        context = null;
        launch(false);
        assertEquals(401, send("POST", "/analysis-jobs", descriptor(input, key()).toString(), token, null).statusCode());
        assertEquals("PAYSE-API-0.6-4", body(send("GET", "/snapshot", null, token, null), 200).path("schemaVersion").asString());
    }

    /**
     * 한 건은 60초 전에 전송하지 않고 경계 도달 시에만 같은 작업의 제출 허가를 발급한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void waitsForSingleItemThreshold() throws Exception {
        ObjectNode single = subset(input, 0, 1);
        String job = accept(single, key()).path("jobId").asString();
        ObjectNode waiting = body(send("GET", "/analysis-jobs/" + job, null, token, null), 200);
        assertEquals("queued", waiting.path("state").asString());
        assertEquals("wait", waiting.path("action").asString());
        assertFalse(waiting.has("permit"));
        clock.advance(Duration.ofSeconds(59));
        assertEquals("wait", body(send("GET", "/analysis-jobs/" + job, null, token, null), 200).path("action").asString());
        assertEquals(0, model.calls.get());
        clock.advance(Duration.ofSeconds(1));
        ObjectNode ready = permit(job);
        assertEquals(clock.instant().plusSeconds(60), Instant.parse(ready.path("permitExpiresAt").asString()));
        submit(job, single, key(), false, false);
        await(job, "succeeded");
        assertEquals(1, model.calls.get());
        assertEquals(1, query(single, null, token).path("result").path("items").size());
    }

    /**
     * 만료 허가·180초 실행창을 구분하고 사용자 재시도만 새 실행창을 시작한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void expiresPermitAndExecutionWindow() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        ObjectNode first = permit(job);
        Instant initialExpiry = jobTime(job, "execution_expires_at");
        clock.advance(Duration.ofSeconds(60));
        ObjectNode stalePermit = submission(input, key(), first.path("permit").asString());
        assertEquals(409, send("POST", "/analysis-jobs/" + job + "/input", stalePermit.toString(), token, null).statusCode());
        ObjectNode renewed = permit(job);
        assertNotEquals(first.path("permit"), renewed.path("permit"));
        assertEquals(initialExpiry, jobTime(job, "execution_expires_at"));
        clock.advance(Duration.ofSeconds(120));
        ObjectNode missed = body(send("GET", "/analysis-jobs/" + job, null, token, null), 200);
        assertEquals("failed", missed.path("state").asString());
        assertEquals("retry", missed.path("action").asString());
        assertFalse(missed.has("permit"));
        assertEquals(0, model.calls.get());
        ObjectNode late = submission(input, key(), renewed.path("permit").asString());
        assertEquals(409, send("POST", "/analysis-jobs/" + job + "/input", late.toString(), token, null).statusCode());
        submit(job, input, key(), true, false);
        await(job, "succeeded");
        assertEquals(clock.instant().plusSeconds(180), jobTime(job, "execution_expires_at"));
        assertEquals(1, model.calls.get());
    }

    /**
     * 큰 묶음에서 필요한 일부 기억만 재조회할 때 새 itemKey와 무관하게 모델 호출 없이 반환한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void reusesSubsetWithoutWholeBundleIdentity() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode all = query(input, null, token);
        ObjectNode smaller = subset(input, 3, 2);
        for (JsonNode item : smaller.path("items")) ((ObjectNode) item).put("itemKey", "subset:" + item.path("itemKey").asString());
        ((ObjectNode) smaller.path("context")).put("inputRevision", 7).put("localSessionEpoch", 4);
        ObjectNode reused = query(smaller, null, token);
        assertEquals("available", reused.path("resultAvailability").asString());
        assertEquals(all.path("resultId"), reused.path("resultId"));
        assertEquals(2, reused.path("result").path("items").size());
        Set<String> wanted = new HashSet<>();
        smaller.path("items").forEach(item -> wanted.add(item.path("itemKey").asString()));
        for (JsonNode row : reused.path("result").path("items")) assertTrue(wanted.remove(row.path("interpretation").path("itemKey").asString()));
        assertTrue(wanted.isEmpty());
        assertEquals(1, model.calls.get());
    }

    /**
     * 일반 재시도·조회는 최초 저장 기한을 유지하고 만료 후 명시 새 분석만 새 기한을 시작한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void onlyNewRecoveryAnalysisRestartsRetention() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode original = query(input, null, token);
        Map<String, String> originalDates = memoryDates(original);
        clock.advance(Duration.ofSeconds(60));
        ObjectNode repeated = body(send("POST", "/analysis-jobs/" + job + "/retry", submission(input, key(), null).toString(), token, null), 200);
        assertEquals("readResult", repeated.path("action").asString());
        assertEquals(originalDates, memoryDates(query(input, null, token)));
        assertEquals(1, model.calls.get());
        clock.advance(Duration.ofDays(100));
        assertEquals("expired", body(send("GET", "/analysis-jobs/" + job, null, token, null), 200).path("state").asString());
        assertEquals("missing", query(input, null, token).path("resultAvailability").asString());
        assertEquals(409, send("POST", "/analysis-jobs/" + job + "/retry", submission(input, key(), null).toString(), token, null).statusCode());
        ObjectNode recovery = recovery(input, job);
        String fresh = body(send("POST", "/analysis-jobs", recovery.toString(), token, null), 202).path("jobId").asString();
        assertNotEquals(job, fresh);
        submit(fresh, input, key(), false, false);
        await(fresh, "succeeded");
        ObjectNode result = query(input, null, token);
        assertEquals("available", result.path("resultAvailability").asString());
        assertNotEquals(original.path("resultId"), result.path("resultId"));
        for (JsonNode item : result.path("result").path("items")) {
            assertEquals(clock.instant(), Instant.parse(item.path("storedAt").asString()));
            assertEquals(clock.instant().atZone(ZoneId.of("Asia/Seoul")).plusMonths(3).toInstant(), Instant.parse(item.path("normalExpiresAt").asString()));
        }
        assertEquals(2, model.calls.get());
        assertEquals(originalDates, persistedDates(original));
    }

    /**
     * 만료 작업을 복구해도 중요보존으로 유효한 기억이 있으면 새 분석·저장 기산 없이 재사용한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void recoveryUsesValidImportantMemoryFirst() throws Exception {
        model.important = true;
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode original = query(input, null, token);
        Map<String, String> dates = memoryDates(original);
        clock.advance(Duration.ofDays(100));
        ObjectNode recovered = body(send("POST", "/analysis-jobs", recovery(input, job).toString(), token, null), 200);
        assertEquals("succeeded", recovered.path("state").asString());
        assertEquals(original.path("resultId"), recovered.path("resultId"));
        assertEquals(dates, memoryDates(query(input, null, token)));
        assertEquals(1, model.calls.get());
        assertEquals(10, admin.queryForObject("SELECT count(*) FROM payse.analysis_items WHERE user_id=?", Integer.class, owner));
    }

    /**
     * 같은 사용자의 서로 다른 대기 작업 두 개를 허용하고 세 번째 신규 접수만 제한한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void enforcesUserQueueCapacityWithoutBlockingFinance() throws Exception {
        accept(subset(input, 0, 1), key());
        accept(subset(input, 1, 1), key());
        assertEquals(429, send("POST", "/analysis-jobs", descriptor(subset(input, 2, 1), key()).toString(), token, null).statusCode());
        assertEquals(2, admin.queryForObject("SELECT count(*) FROM payse.analysis_jobs WHERE user_id=?", Integer.class, owner));
        assertEquals("PAYSE-API-0.6-4", body(send("GET", "/snapshot", null, token, null), 200).path("schemaVersion").asString());
        assertEquals(0, model.calls.get());
    }

    /**
     * 폐기 DB의 다른 사용자 대기 20개가 전체 한도에 포함되고 한 자리 해제 후 정상 접수된다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void enforcesGlobalQueueCapacityAcrossOwners() throws Exception {
        List<UUID> waiting = seedWaitingUsers(10);
        financialBefore = fingerprint();
        ObjectNode single = subset(input, 0, 1);
        assertEquals(20, waiting.size());
        assertEquals(429, send("POST", "/analysis-jobs", descriptor(single, key()).toString(), token, null).statusCode());
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_jobs WHERE user_id=?", Integer.class, owner));
        assertEquals(1, admin.update("UPDATE payse.analysis_jobs SET state='cancelled',finished_at=? WHERE id=?",
            OffsetDateTime.ofInstant(clock.instant(), ZoneOffset.UTC), waiting.getFirst()));
        accept(single, key());
        assertEquals(20, admin.queryForObject("SELECT count(*) FROM payse.analysis_jobs WHERE state IN ('queued','awaitingInput')", Integer.class));
        assertEquals(0, model.calls.get());
    }

    /**
     * 관련 거래가 같으면 원천 묶음 버전 상승만으로 실행 결과를 버리지 않으며 최초 출처는 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void allowsUnrelatedSourceRefreshDuringExecution() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        model.block();
        submit(job, input, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        String nextVersion = "analysis-refresh:" + UUID.randomUUID();
        refreshSourceVersion(nextVersion);
        financialBefore = fingerprint();
        model.release.countDown();
        await(job, "succeeded");
        ObjectNode current = meaningInput(source(token), 10);
        assertEquals(nextVersion, current.path("context").path("sourceVersion").asString());
        ObjectNode result = query(current, null, token);
        assertEquals("available", result.path("resultAvailability").asString());
        assertEquals(input.path("context").path("sourceVersion"), result.path("provenance").path("sourceVersion"));
        assertEquals(1, model.calls.get());
    }

    /**
     * 실행 중 관련 거래의 사용자 분류가 바뀌면 늦은 응답을 저장·적용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsRelatedClassificationChangeDuringExecution() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        model.block();
        submit(job, input, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        UUID transaction = UUID.fromString(input.path("items").get(0).path("targetTransactionId").asString());
        assertEquals(1, admin.update("UPDATE payse.financial_transactions SET payse_transaction_type='expense' WHERE user_id=? AND id=?", owner, transaction));
        assertEquals(1, admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner));
        financialBefore = fingerprint();
        model.release.countDown();
        await(job, "failed");
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_results WHERE user_id=?", Integer.class, owner));
        assertEquals("missing", query(meaningInput(source(token), 10), null, token).path("resultAvailability").asString());
        assertEquals(1, model.calls.get());
    }

    /**
     * 모델 응답을 기다리던 세션을 로그아웃하면 새 세션이 생겨도 옛 실행이 결과를 저장하지 못한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void logoutBlocksPendingResultAdoption() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        model.block();
        submit(job, input, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        String ended = token;
        assertEquals(204, send("DELETE", "/demo-sessions/current", null, token, null).statusCode());
        token = login(credentials, code);
        assertNotEquals(ended, token);
        assertEquals(401, send("GET", "/analysis-jobs/" + job, null, ended, null).statusCode());
        model.release.countDown();
        assertTrue(model.returned.await(10, TimeUnit.SECONDS));
        clock.advance(Duration.ofSeconds(181));
        ObjectNode waiting = body(send("GET", "/analysis-jobs/" + job, null, token, null), 200);
        assertEquals("outcomeUnknown", waiting.path("state").asString());
        assertEquals("missing", query(input, null, token).path("resultAvailability").asString());
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_results WHERE user_id=?", Integer.class, owner));
        assertEquals(1, model.calls.get());
    }

    /**
     * 공급자 성공 뒤 키 감싸기가 실패해도 관측 사용량을 지우거나 암호화되지 않은 결과를 저장하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesUsageWhenEncryptionFails() throws Exception {
        testKeys.failWrap = true;
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "failed");
        JsonNode attempt = json.readTree(admin.queryForObject("""
            SELECT to_jsonb(a)::text
            FROM payse.analysis_attempts a
            WHERE user_id=? AND job_id=?
            """, String.class, owner, UUID.fromString(job)));
        assertEquals("settled", attempt.path("dispatch_state").asString());
        assertTrue(attempt.path("detail").path("usageKnown").asBoolean());
        assertEquals(100, attempt.path("detail").path("inputTokens").asInt());
        assertEquals(80, attempt.path("detail").path("outputTokens").asInt());
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_results WHERE user_id=?", Integer.class, owner));
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_items WHERE user_id=?", Integer.class, owner));
        assertEquals(1, model.calls.get());
    }

    /**
     * 정상 완료 뒤 중복 실패 콜백이 와도 정산된 사용량·채택 결과를 수정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void settledUsageSurvivesLateFailureCallback() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        String sql = "SELECT to_jsonb(a)::text FROM payse.analysis_attempts a WHERE user_id=? AND job_id=?";
        JsonNode before = json.readTree(admin.queryForObject(sql, String.class, owner, UUID.fromString(job)));
        assertEquals("settled", before.path("dispatch_state").asString());
        assertEquals(100, before.path("detail").path("inputTokens").asInt());
        String hash = admin.queryForObject("SELECT input_hash FROM payse.analysis_jobs WHERE user_id=? AND id=?", String.class, owner, UUID.fromString(job));
        Class<?> workType = Class.forName("com.payse.api.analysis.service.AnalysisJobs$Work");
        var constructor = workType.getDeclaredConstructor(String.class, UUID.class, UUID.class, UUID.class,
            String.class, String.class, ObjectNode.class);
        constructor.setAccessible(true);
        Object work = constructor.newInstance(token, owner, UUID.fromString(job), UUID.fromString(before.path("id").asString()),
            hash, new AnalysisIdentity().sourceHash(source, input), input.deepCopy());
        var callback = AnalysisJobs.class.getDeclaredMethod("fail", workType, boolean.class, String.class, TokenUsage.class);
        callback.setAccessible(true);
        callback.invoke(context.getBean(AnalysisJobs.class), work, true, "LATE_FAILURE_TEST", new TokenUsage(900, null, 900));
        callback.invoke(context.getBean(AnalysisJobs.class), work, true, "LATE_FAILURE_TEST", null);
        JsonNode after = json.readTree(admin.queryForObject(sql, String.class, owner, UUID.fromString(job)));
        assertEquals(before, after);
        assertEquals("succeeded", body(send("GET", "/analysis-jobs/" + job, null, token, null), 200).path("state").asString());
        assertEquals("available", query(input, null, token).path("resultAvailability").asString());
        assertEquals(1, model.calls.get());
    }

    /**
     * 최초 분석의 화면 선택·epoch·revision은 출처로 공개하지 않고 현재 요청 문맥만 반환한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void limitsPublicProvenanceToAnalysisSource() throws Exception {
        String target = input.path("items").get(0).path("targetTransactionId").asString();
        JsonNode transaction = unique(source.path("transactions"), value -> target.equals(value.path("transactionId").asString()));
        ObjectNode originalContext = (ObjectNode) input.path("context");
        originalContext.putArray("selectedAccountIds").add(transaction.path("accountId").asString());
        originalContext.put("localSessionEpoch", 5).put("inputRevision", 6);
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode current = input.deepCopy();
        ObjectNode currentContext = (ObjectNode) current.path("context");
        currentContext.putArray("selectedAccountIds");
        currentContext.put("localSessionEpoch", 9).put("inputRevision", 10);
        ObjectNode response = query(current, null, token);
        JsonNode provenance = response.path("provenance");
        assertEquals(Set.of("schemaVersion", "dataVersion", "sourceVersion", "ruleVersion", "asOf", "versions", "analysisInputHash"),
            provenance.propertyNames());
        for (String field : List.of("selectedAccountIds", "localSessionEpoch", "inputRevision")) assertFalse(provenance.has(field));
        assertEquals(currentContext, response.path("context"));
        assertEquals("available", response.path("resultAvailability").asString());
        assertEquals(1, model.calls.get());
    }

    /**
     * 로그아웃은 대기 작업·옛 허가를 취소하고 새 세션의 명시 재시도만 한 번 실행한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void logoutCancelsWaitingPermitButAllowsExplicitRetry() throws Exception {
        String job = accept(input, key()).path("jobId").asString();
        ObjectNode oldPermit = permit(job);
        assertEquals("awaitingInput", oldPermit.path("state").asString());
        String ended = token;
        assertEquals(204, send("DELETE", "/demo-sessions/current", null, token, null).statusCode());
        token = login(credentials, code);
        assertNotEquals(ended, token);
        ((ObjectNode) input.path("context")).put("localSessionEpoch", 2);
        ObjectNode cancelled = body(send("GET", "/analysis-jobs/" + job, null, token, null), 200);
        assertEquals("cancelled", cancelled.path("state").asString());
        assertEquals("retry", cancelled.path("action").asString());
        assertFalse(cancelled.has("permit"));
        ObjectNode oldSubmission = submission(input, key(), oldPermit.path("permit").asString());
        assertEquals(409, send("POST", "/analysis-jobs/" + job + "/input", oldSubmission.toString(), token, null).statusCode());
        assertEquals(0, admin.queryForObject("SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?", Integer.class, owner, UUID.fromString(job)));
        assertEquals(0, model.calls.get());
        submit(job, input, key(), true, false);
        await(job, "succeeded");
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?", Integer.class, owner, UUID.fromString(job)));
        assertEquals(1, model.calls.get());
    }

    /**
     * 실패 이후 관련 DB 금액이 바뀌면 같은 작업 재시도를 거절하고 새 원천 접수로 구분한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void changedAmountRejectsOldRetryBeforeNewAttempt() throws Exception {
        model.failure = "invalid";
        String job = accept(input, key()).path("jobId").asString();
        submit(job, input, key(), false, false);
        await(job, "failed");
        UUID target = UUID.fromString(input.path("items").get(0).path("targetTransactionId").asString());
        long before = admin.queryForObject("SELECT amount_krw FROM payse.financial_transactions WHERE user_id=? AND id=?", Long.class, owner, target);
        assertTrue(before < 9_000_000_000_000L);
        assertEquals(1, admin.update("UPDATE payse.financial_transactions SET amount_krw=? WHERE user_id=? AND id=?", before + 1, owner, target));
        assertEquals(1, admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner));
        financialBefore = fingerprint();
        ObjectNode refreshed = meaningInput(source(token), 10);
        assertEquals(new AnalysisIdentity().hint(input), new AnalysisIdentity().hint(refreshed));
        HttpResponse<String> rejected = send("POST", "/analysis-jobs/" + job + "/retry", submission(refreshed, key(), null).toString(), token, null);
        assertEquals(409, rejected.statusCode());
        assertEquals("STALE_DATA", json.readTree(rejected.body()).path("error").path("code").asString());
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?", Integer.class, owner, UUID.fromString(job)));
        assertEquals(1, model.calls.get());
        model.failure = "none";
        String currentJob = accept(refreshed, key()).path("jobId").asString();
        assertNotEquals(job, currentJob);
        submit(currentJob, refreshed, key(), false, false);
        await(currentJob, "succeeded");
        assertEquals("available", query(refreshed, null, token).path("resultAvailability").asString());
        assertEquals(2, model.calls.get());
    }


    /**
     * 비활성·원천 변경 기억도 검토용 본문은 읽되 현재 적용 가능하다고 표시하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void listsInactiveAndChangedMemoriesForReview() throws Exception {
        storeMemories(input);
        String inactive = memoryId(input.path("items").get(0).path("itemKey").asString());
        String changed = memoryId(input.path("items").get(1).path("itemKey").asString());
        String transaction = input.path("items").get(1).path("targetTransactionId").asString();
        assertEquals(1, admin.update("UPDATE payse.analysis_items SET active=false,metadata_version=metadata_version+1 WHERE user_id=? AND id=?", owner, UUID.fromString(inactive)));
        assertEquals(1, admin.update("UPDATE payse.financial_transactions SET amount_krw=amount_krw+1 WHERE user_id=? AND id=?", owner, UUID.fromString(transaction)));
        assertEquals(1, admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner));
        financialBefore = fingerprint();
        Map<String, String> dates = allMemoryDates();
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories("", token);
        assertEquals("PAYSE-ANALYSIS-1", listed.path("contractVersion").asString());
        assertEquals(10, listed.path("items").size());
        for (JsonNode item : listed.path("items")) {
            assertEquals("unchecked", item.path("resultAvailability").asString());
            assertEquals("available", item.path("contentAvailability").asString());
            assertTrue(item.has("interpretation"));
            assertEquals(RESULT_TEXT, item.path("retentionReason").asString());
            assertFalse(item.has("sourceRefs"));
            assertFalse(item.has("sourceHash"));
            assertFalse(item.has("id"));
        }
        assertFalse(memory(listed, inactive).path("active").asBoolean());
        assertEquals(2, memory(listed, inactive).path("metadataVersion").asInt());
        assertTrue(memory(listed, changed).path("sourceChanged").asBoolean());
        assertFalse(memory(listed, inactive).path("sourceChanged").asBoolean());
        assertEquals(10, testKeys.unwrapCalls.get());
        assertEquals(1, model.calls.get());
        assertEquals(dates, allMemoryDates());
    }

    /**
     * 과거 기간 조회도 삭제·일반 만료 본문을 되살리지 않고 중요보존 예외만 복호화한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryPeriodsDoNotRestoreExpiredOrDeletedBodies() throws Exception {
        storeMemories(input);
        LocalDate day = clock.instant().atZone(ZoneId.of("Asia/Seoul")).toLocalDate();
        String removed = memoryId(input.path("items").get(0).path("itemKey").asString());
        String retained = memoryId(input.path("items").get(1).path("itemKey").asString());
        assertEquals(204, send("DELETE", "/analysis-memories/" + removed, null, token, key()).statusCode());
        assertEquals(1, admin.update("UPDATE payse.analysis_items SET important=true,is_reference=true,metadata_version=metadata_version+1 WHERE user_id=? AND id=?", owner, UUID.fromString(retained)));
        Map<String, String> dates = allMemoryDates();
        clock.advance(Duration.ofDays(100));
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories(period(day, day), token);
        assertEquals(10, listed.path("items").size());
        for (JsonNode item : listed.path("items")) {
            String id = item.path("itemId").asString();
            if (id.equals(retained)) {
                assertEquals("available", item.path("contentAvailability").asString());
                assertEquals("unchecked", item.path("resultAvailability").asString());
                assertTrue(item.has("interpretation"));
            } else assertHiddenMemory(item, id.equals(removed) ? "deleted" : "expired");
        }
        assertEquals(1, testKeys.unwrapCalls.get());
        testKeys.unwrapCalls.set(0);
        assertTrue(listMemories(period(day.plusDays(1), day.plusDays(1)), token).path("items").isEmpty());
        assertEquals(0, testKeys.unwrapCalls.get());
        assertEquals(dates, allMemoryDates());
        assertEquals(1, model.calls.get());
        for (String invalid : List.of("?startDate=" + day, "?endDate=" + day,
                "?startDate=2026-02-30&endDate=2026-03-01", period(day.plusDays(1), day))) {
            body(send("GET", "/analysis-memories" + invalid, null, token, null), 422);
        }
    }

    /**
     * 저장일의 서울 자정 양쪽을 구분하며 종료일 하루 전체를 포함한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryPeriodUsesSeoulDayBoundaries() throws Exception {
        model.unknownClassification = true;
        ObjectNode twenty = independentInput(20);
        ZoneId seoul = ZoneId.of("Asia/Seoul");
        LocalDate first = clock.instant().atZone(seoul).toLocalDate();
        Instant midnight = first.plusDays(1).atStartOfDay(seoul).toInstant();
        clock.advance(Duration.between(clock.instant(), midnight.minusMillis(1)));
        storeMemories(subset(twenty, 0, 10));
        clock.advance(Duration.ofMillis(2));
        storeMemories(subset(twenty, 10, 10));
        ObjectNode before = listMemories(period(first, first), token);
        ObjectNode after = listMemories(period(first.plusDays(1), first.plusDays(1)), token);
        assertEquals(10, before.path("items").size());
        assertEquals(10, after.path("items").size());
        Set<String> ids = new HashSet<>();
        for (JsonNode item : before.path("items")) {
            assertEquals(first, Instant.parse(item.path("storedAt").asString()).atZone(seoul).toLocalDate());
            assertTrue(ids.add(item.path("itemId").asString()));
        }
        for (JsonNode item : after.path("items")) {
            assertEquals(first.plusDays(1), Instant.parse(item.path("storedAt").asString()).atZone(seoul).toLocalDate());
            assertTrue(ids.add(item.path("itemId").asString()));
        }
        assertEquals(20, listMemories(period(first, first.plusDays(1)), token).path("items").size());
        assertEquals(2, model.calls.get());
    }

    /**
     * 20건 페이지는 다른 사용자·세션·기간에 재사용되지 않으며 해당 페이지 본문만 복호화한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryPagesBindOwnerSessionAndPeriod() throws Exception {
        model.unknownClassification = true;
        storeMemories(independentInput(25));
        LocalDate day = clock.instant().atZone(ZoneId.of("Asia/Seoul")).toLocalDate();
        String range = period(day, day);
        testKeys.unwrapCalls.set(0);
        ObjectNode first = listMemories(range, token);
        assertEquals(20, first.path("items").size());
        assertTrue(first.path("pageInfo").path("hasMore").asBoolean());
        String cursor = first.path("pageInfo").path("nextCursor").asString();
        assertFalse(cursor.isBlank());
        assertEquals(20, testKeys.unwrapCalls.get());
        testKeys.unwrapCalls.set(0);
        ObjectNode second = listMemories(range + "&cursor=" + cursor, token);
        assertEquals(5, second.path("items").size());
        assertFalse(second.path("pageInfo").path("hasMore").asBoolean());
        assertTrue(second.path("pageInfo").path("nextCursor").isNull());
        assertEquals(5, testKeys.unwrapCalls.get());
        List<String> actual = new ArrayList<>();
        for (JsonNode page : List.of(first, second)) for (JsonNode item : page.path("items")) {
            assertEquals("unchecked", item.path("resultAvailability").asString());
            actual.add(item.path("itemId").asString());
        }
        assertEquals(25, new HashSet<>(actual).size());
        assertEquals(actual.stream().sorted().toList(), actual);
        assertEquals(admin.queryForList("SELECT id::text FROM payse.analysis_items WHERE user_id=? ORDER BY id", String.class, owner), actual);
        body(send("GET", "/analysis-memories" + period(day, day.plusDays(1)) + "&cursor=" + cursor, null, token, null), 409);
        JsonNode beta = json.readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots/beta-ready.json")));
        UUID other = UUID.fromString(beta.path("userId").asString());
        setCode(other, code);
        String otherToken = login(credentials(other), code);
        assertTrue(listMemories("", otherToken).path("items").isEmpty());
        body(send("GET", "/analysis-memories" + range + "&cursor=" + cursor, null, otherToken, null), 403);
        assertEquals(204, send("DELETE", "/demo-sessions/current", null, token, null).statusCode());
        token = login(credentials, code);
        body(send("GET", "/analysis-memories" + range + "&cursor=" + cursor, null, token, null), 403);
        body(send("GET", "/analysis-memories?cursor=invalid", null, token, null), 400);
        assertEquals(1, model.calls.get());
    }

    /**
     * 모델이 답변 근거를 줄여도 원래 입력의 연결 거래 권한까지 기억 조회에서 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryListUsesFullStoredSourcePermissions() throws Exception {
        JsonNode relation = unique(source.path("transactionRelations"), row -> "fixture-owned-transfer-1".equals(row.path("evidenceRef").asString()));
        JsonNode from = unique(source.path("transactions"), row -> relation.path("fromId").equals(row.path("transactionId")));
        JsonNode to = unique(source.path("transactions"), row -> relation.path("toId").equals(row.path("transactionId")));
        ObjectNode extended = meaningInput(source, 9);
        appendMeaning(extended, from);
        appendMeaning(extended, to);
        ObjectNode link = ((ArrayNode) extended.path("relations")).addObject();
        for (String field : List.of("kind", "fromId", "toId")) link.set(field, relation.get(field));
        ObjectNode fromItem = (ObjectNode) unique(extended.path("items"), row -> from.path("transactionId").equals(row.path("targetTransactionId")));
        ((ArrayNode) fromItem.path("evidenceTransactionIds")).add(to.path("transactionId").asString());
        model.unknownClassification = true;
        model.minimalEvidence = true;
        storeMemories(extended);
        String fromMemory = memoryId(fromItem.path("itemKey").asString());
        String toMemory = memoryId("meaning:" + to.path("transactionId").asString());
        ObjectNode original = listMemories("", token);
        assertEquals(1, memory(original, fromMemory).path("interpretation").path("evidenceTransactionIds").size());
        String targetInstitution = institutionFor(to);
        assertNotEquals(institutionFor(from), targetInstitution);
        disconnectInstitution(targetInstitution);
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories("", token);
        assertEquals(11, listed.path("items").size());
        assertHiddenMemory(memory(listed, fromMemory), "restricted");
        assertHiddenMemory(memory(listed, toMemory), "restricted");
        assertEquals(9, testKeys.unwrapCalls.get());
        assertFalse(listed.toString().contains(to.path("transactionId").asString()));
        assertEquals(1, model.calls.get());
    }

    /**
     * 원천 권한 메타가 없는 기존 행은 검토 목록에 남기되 본문·암호화 키를 읽지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void legacyMemoryIsListedWithoutDecrypting() throws Exception {
        storeMemories(input);
        String original = memoryId(input.path("items").get(0).path("itemKey").asString());
        String legacy = cloneMemory(original, true);
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories("", token);
        assertEquals(11, listed.path("items").size());
        assertHiddenMemory(memory(listed, legacy), "unverified");
        assertEquals(10, testKeys.unwrapCalls.get());
    }

    /**
     * 다른 기억 ID에 복사한 암호문은 같은 사용자라도 AAD가 달라 목록 본문으로 노출되지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryCiphertextCannotMoveToOtherItem() throws Exception {
        storeMemories(input);
        cloneMemory(memoryId(input.path("items").get(0).path("itemKey").asString()), false);
        HttpResponse<String> response = send("GET", "/analysis-memories", null, token, null);
        body(response, 503);
        assertFalse(response.body().contains(RESULT_TEXT));
        assertFalse(response.body().contains("interpretation"));
    }

    /**
     * 외부 키 복호화 중 삭제된 기억은 뒤늦게 응답되지 않고 변경 충돌로 재조회를 요구한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryListRechecksDeletionAfterDecrypt() throws Exception {
        storeMemories(input);
        String removed = memoryId(input.path("items").get(0).path("itemKey").asString());
        testKeys.blockUnwrap();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var pending = executor.submit(() -> send("GET", "/analysis-memories", null, token, null));
            assertTrue(testKeys.unwrapEntered.await(10, TimeUnit.SECONDS));
            try {
                assertEquals(204, send("DELETE", "/analysis-memories/" + removed, null, token, key()).statusCode());
            } finally { testKeys.unwrapRelease.countDown(); }
            HttpResponse<String> response = pending.get(15, TimeUnit.SECONDS);
            body(response, 409);
            assertFalse(response.body().contains(RESULT_TEXT));
        }
        assertHiddenMemory(memory(listMemories("", token), removed), "deleted");
        assertEquals(1, admin.queryForObject("SELECT count(*) FROM payse.analysis_suppressions WHERE user_id=?", Integer.class, owner));
    }

    /**
     * 복호화 동안 금융사 연결이 해제되면 읽었던 평문을 버리고 새 권한으로 재조회하게 한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryListRechecksDisconnectAfterDecrypt() throws Exception {
        storeMemories(input);
        JsonNode transaction = unique(source.path("transactions"), row -> input.path("items").get(0).path("targetTransactionId").equals(row.path("transactionId")));
        testKeys.blockUnwrap();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var pending = executor.submit(() -> send("GET", "/analysis-memories", null, token, null));
            assertTrue(testKeys.unwrapEntered.await(10, TimeUnit.SECONDS));
            try { disconnectInstitution(institutionFor(transaction)); }
            finally { testKeys.unwrapRelease.countDown(); }
            HttpResponse<String> response = pending.get(15, TimeUnit.SECONDS);
            body(response, 409);
            assertFalse(response.body().contains(RESULT_TEXT));
        }
        testKeys.unwrapCalls.set(0);
        for (JsonNode item : listMemories("", token).path("items")) assertHiddenMemory(item, "restricted");
        assertEquals(0, testKeys.unwrapCalls.get());
    }

    /**
     * 복호화 동안 종료한 세션은 결과 목록을 받지 못하며 새 로그인으로만 다시 조회한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryListRechecksLogoutAfterDecrypt() throws Exception {
        storeMemories(input);
        testKeys.blockUnwrap();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var pending = executor.submit(() -> send("GET", "/analysis-memories", null, token, null));
            assertTrue(testKeys.unwrapEntered.await(10, TimeUnit.SECONDS));
            try { assertEquals(204, send("DELETE", "/demo-sessions/current", null, token, null).statusCode()); }
            finally { testKeys.unwrapRelease.countDown(); }
            HttpResponse<String> response = pending.get(15, TimeUnit.SECONDS);
            body(response, 401);
            assertFalse(response.body().contains(RESULT_TEXT));
            assertFalse(response.body().contains("interpretation"));
        }
    }

    /**
     * 목록도 인증을 필터보다 먼저 검사하며 GET 본문·허용하지 않은 필터를 무시하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryListAuthenticatesBeforeFilters() throws Exception {
        body(send("GET", "/analysis-memories?startDate=bad", null, "invalid", null), 401);
        body(send("GET", "/analysis-memories?startDate=bad", null, token, null), 422);
        body(send("GET", "/analysis-memories?limit=1", null, token, null), 400);
        body(send("GET", "/analysis-memories", "{}", token, null), 422);
        assertTrue(listMemories("?startDate=0001-01-01&endDate=9999-12-31", token).path("items").isEmpty());
        assertEquals(0, model.calls.get());
    }


    /**
     * 실제 접수·입력·비동기 채택 경로로 기억을 준비하며 목록 검사 전 불필요한 복호화는 하지 않는다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private void storeMemories(ObjectNode meaning) throws Exception {
        String job = accept(meaning, key()).path("jobId").asString();
        submit(job, meaning, key(), false, false);
        await(job, "succeeded");
    }

    /**
     * 검토 목록은 적용용 현재 입력을 제출하지 않는 독립 조회 경로로 읽는다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private ObjectNode listMemories(String query, String bearer) throws Exception {
        return body(send("GET", "/analysis-memories" + query, null, bearer, null), 200);
    }

    /**
     * 준비 입력의 키와 현재 소유자로 기억 한 건을 식별하고 중복·누락은 테스트 실패로 처리한다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private String memoryId(String itemKey) {
        List<UUID> ids = admin.queryForList("SELECT id FROM payse.analysis_items WHERE user_id=? AND item_key=?", UUID.class, owner, itemKey);
        assertEquals(1, ids.size());
        return ids.getFirst().toString();
    }

    /**
     * 목록의 공개 기억 ID를 기준으로 한 항목만 선택한다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private JsonNode memory(JsonNode response, String id) {
        return unique(response.path("items"), item -> id.equals(item.path("itemId").asString()));
    }

    /**
     * 숨긴 본문·보존 설명·원천 변경 추정이 응답에서 제외되며 적용 상태는 미검증인지 검사한다.
     * @created 2026-11-01
     * @usedBy 만료·삭제·권한·기존 행 검사
     */
    private void assertHiddenMemory(JsonNode item, String state) {
        assertEquals(state, item.path("contentAvailability").asString());
        assertEquals("unchecked", item.path("resultAvailability").asString());
        for (String field : List.of("interpretation", "retentionReason", "sourceChanged", "sourceRefs", "sourceHash")) assertFalse(item.has(field), field);
        for (String field : List.of("itemId", "resultId", "semanticTaskKind", "active", "isReference", "important", "referencePolicy", "storedAt", "normalExpiresAt", "metadataVersion")) assertTrue(item.has(field), field);
    }

    /**
     * 양끝 저장일을 포함하는 명시 조회 문자열을 만들며 날짜 정책은 서버가 검증한다.
     * @created 2026-11-01
     * @usedBy 날짜 필터·페이지 검사
     */
    private String period(LocalDate start, LocalDate end) { return "?startDate=" + start + "&endDate=" + end; }

    /**
     * 최초 저장·정상 만료 시각은 전체 기억 ID별로 보존되는지 확인할 비교 자료다.
     * @created 2026-11-01
     * @usedBy 읽기·보존 기산 검사
     */
    private Map<String, String> allMemoryDates() {
        Map<String, String> dates = new HashMap<>();
        for (Map<String, Object> row : admin.queryForList("SELECT id,stored_at,normal_expires_at FROM payse.analysis_items WHERE user_id=?", owner)) {
            dates.put(row.get("id").toString(), row.get("stored_at") + "/" + row.get("normal_expires_at"));
        }
        assertFalse(dates.isEmpty());
        return dates;
    }

    /**
     * 페이지 크기 검사는 기존 금융 거래를 사용하며 관계를 생략한 가짜 근거를 만들지 않는다.
     * @created 2026-11-01
     * @usedBy 페이지·서울 날짜 경계 검사
     */
    private ObjectNode independentInput(int count) {
        Set<String> linked = new HashSet<>();
        for (JsonNode relation : source.path("transactionRelations")) {
            linked.add(relation.path("fromId").asString());
            linked.add(relation.path("toId").asString());
        }
        List<JsonNode> rows = new ArrayList<>();
        for (JsonNode row : source.path("transactions")) {
            if ("account_entry".equals(row.path("recordKind").asString()) && row.path("originalTransactionId").isNull()
                    && !linked.contains(row.path("transactionId").asString())) rows.add(row);
        }
        rows.sort(Comparator.comparing(row -> row.path("transactionId").asString()));
        assertTrue(rows.size() >= count, "Prepared source must contain enough independent account records");
        ObjectNode result = meaningInput(source, 0);
        for (JsonNode row : rows.subList(0, count)) appendMeaning(result, row);
        return result;
    }

    /**
     * 실제 원천 한 건과 현재 분류를 입력 스키마의 허용 필드로만 투영한다.
     * @created 2026-11-01
     * @usedBy independentInput, 관계 권한 검사
     */
    private void appendMeaning(ObjectNode meaning, JsonNode transaction) {
        assertEquals(owner.toString(), transaction.path("userId").asString());
        assertTrue(transaction.path("originalTransactionId").isNull());
        String id = transaction.path("transactionId").asString();
        ObjectNode item = ((ArrayNode) meaning.path("items")).addObject().put("itemKey", "meaning:" + id).put("targetTransactionId", id).putNull("candidateKey");
        item.putArray("evidenceTransactionIds").add(id);
        ObjectNode projected = ((ArrayNode) meaning.path("transactions")).addObject();
        for (String field : List.of("transactionId", "recordKind", "direction", "status", "reflectionReason", "merchantName", "description", "originalTransactionId")) projected.set(field, transaction.get(field).deepCopy());
        ((ArrayNode) meaning.path("currentClassifications")).addObject().put("transactionId", id).set("value", transaction.path("payseTransactionType").deepCopy());
    }

    /**
     * 거래의 실제 계좌 관계를 따라 연결 해제할 기관을 찾고 표시명은 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 연결 권한 검사
     */
    private String institutionFor(JsonNode transaction) {
        JsonNode account = unique(source.path("accounts"), row -> transaction.path("accountId").equals(row.path("accountId")));
        return account.path("institutionCode").asString();
    }

    /**
     * 폐기 DB의 지정 기관 연결만 해제하고 이후 API가 다른 금융 상태를 바꾸지 않는지 비교한다.
     * @created 2026-11-01
     * @usedBy 연결 해제 경합·관계 권한 검사
     */
    private void disconnectInstitution(String institution) {
        assertFalse(institution.isBlank());
        assertEquals(1, admin.update("UPDATE payse.institution_links SET disconnected_at=clock_timestamp() WHERE user_id=? AND institution_code=? AND disconnected_at IS NULL", owner, institution));
        assertEquals(1, admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner));
        financialBefore = fingerprint();
    }

    /**
     * 과거 권한 메타 누락 또는 AAD 이동 공격을 폐기 DB의 새 행으로 재현한다. 기존 행은 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy legacyMemoryIsListedWithoutDecrypting, memoryCiphertextCannotMoveToOtherItem
     */
    private String cloneMemory(String original, boolean legacy) {
        UUID result = UUID.randomUUID(), item = UUID.randomUUID();
        UUID previous = UUID.fromString(original);
        assertEquals(1, admin.update("""
            INSERT INTO payse.analysis_results
              (id,user_id,semantic_kind,input_hash,provenance,accepted_manifest,committed_at)
            SELECT ?,r.user_id,r.semantic_kind,r.input_hash,r.provenance,r.accepted_manifest,r.committed_at
            FROM payse.analysis_results r JOIN payse.analysis_items i
              ON i.user_id=r.user_id AND i.result_id=r.id
            WHERE i.user_id=? AND i.id=?
            """, result, owner, previous));
        String sourceColumns = legacy ? "NULL,NULL" : "source_refs,source_hash";
        assertEquals(1, admin.update("""
            INSERT INTO payse.analysis_items
              (id,user_id,result_id,item_key,semantic_kind,memory_key,evidence_hash,stored_at,normal_expires_at,
               ciphertext,crypto_meta,active,is_reference,important,reference_policy,metadata_version,
               policy_version,policy_actor,deleted_at,purge_requested_at,source_refs,source_hash)
            SELECT ?,user_id,?,item_key,semantic_kind,memory_key,evidence_hash,stored_at,normal_expires_at,
               ciphertext,crypto_meta,active,is_reference,important,reference_policy,metadata_version,
               policy_version,policy_actor,deleted_at,purge_requested_at,
            """ + sourceColumns + " FROM payse.analysis_items WHERE user_id=? AND id=?", item, result, owner, previous));
        return item.toString();
    }

    /**
     * 요청 경로와 본문을 실제 HTTP로 보내고 세션 쿠키를 만들지 않는지 확인한다.
     * @created 2026-11-01
     * @usedBy HTTP 검사 및 로그인
     */
    private HttpResponse<String> send(String method, String path, String body, String bearer, String idempotency) throws Exception {
        var request = HttpRequest.newBuilder(URI.create(base + path)).timeout(Duration.ofSeconds(20));
        if (bearer != null) request.header("Authorization", "Bearer " + bearer);
        if (idempotency != null) request.header("Idempotency-Key", idempotency);
        request.header("Content-Type", "application/json; charset=utf-8");
        request.method(method, body == null ? HttpRequest.BodyPublishers.noBody() : HttpRequest.BodyPublishers.ofString(body));
        var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertTrue(response.headers().allValues("Set-Cookie").isEmpty());
        return response;
    }

    /**
     * 정상 분석 응답의 상태와 no-store를 확인하고 본문 객체를 읽는다.
     * @created 2026-11-01
     * @usedBy API 검사 도우미
     */
    private ObjectNode body(HttpResponse<String> response, int status) {
        assertEquals(status, response.statusCode(), response.body());
        assertTrue(response.headers().firstValue("Cache-Control").orElse("").contains("no-store"));
        return (ObjectNode) json.readTree(response.body());
    }

    /**
     * 현재 입력과 같은 대상의 descriptor를 만든다. 본문은 접수에서 보내지 않는다.
     * @created 2026-11-01
     * @usedBy accept, serializesIdempotentSubmissions, disabledProfile
     */
    private ObjectNode descriptor(ObjectNode meaning, String requestKey) {
        ObjectNode value = json.createObjectNode().put("triggerKind", "A").put("semanticTaskKind", "transactionMeaning")
            .put("inputHashHint", new AnalysisIdentity().hint(meaning)).put("idempotencyKey", requestKey);
        value.set("context", meaning.path("context").deepCopy());
        value.putArray("reasonCodes");
        ArrayNode items = value.putArray("items");
        for (JsonNode item : meaning.path("items")) {
            ObjectNode descriptor = items.addObject().put("itemKey", item.path("itemKey").asString());
            descriptor.set("evidenceTransactionIds", item.path("evidenceTransactionIds").deepCopy());
            descriptor.putArray("candidateIds");
        }
        return value;
    }

    /**
     * 새 접수의 202 응답만 확인한다.
     * @created 2026-11-01
     * @usedBy 분석 실행 검사
     */
    private ObjectNode accept(ObjectNode meaning, String requestKey) throws Exception {
        return body(send("POST", "/analysis-jobs", descriptor(meaning, requestKey).toString(), token, null), 202);
    }

    /**
     * 10개 대상의 즉시 제출 허가를 기다리며 상태 조회에서 모델을 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy submit, serializesIdempotentSubmissions
     */
    private ObjectNode permit(String job) throws Exception {
        for (int attempt = 0; attempt < 80; attempt++) {
            ObjectNode response = body(send("GET", "/analysis-jobs/" + job, null, token, null), 200);
            if (response.path("action").asString().equals("submitInput")) {
                assertFalse(response.path("permit").asString().isBlank());
                return response;
            }
            Thread.sleep(50);
        }
        throw new AssertionError("Input permit was not issued for the confirmed ten-item threshold");
    }

    /**
     * 같은 문맥과 명시 사용자 작업 키로 본문 제출/재시도 요청을 만든다.
     * @created 2026-11-01
     * @usedBy submit, serializesIdempotentSubmissions, requiresUnknownAcknowledgement
     */
    private ObjectNode submission(ObjectNode meaning, String requestKey, String permit) {
        ObjectNode value = json.createObjectNode().put("idempotencyKey", requestKey);
        value.set("context", meaning.path("context").deepCopy());
        value.set("input", meaning.deepCopy());
        if (permit != null) value.put("permit", permit);
        return value;
    }

    /**
     * 입력 허가 또는 명시 재시도 경로로 한 번 제출한다. 자동 공급자 재시도는 없다.
     * @created 2026-11-01
     * @usedBy 분석 실행 검사
     */
    private void submit(String job, ObjectNode meaning, String requestKey, boolean retry, boolean acknowledge) throws Exception {
        ObjectNode request = submission(meaning, requestKey, retry ? null : permit(job).path("permit").asString());
        if (acknowledge) request.put("acknowledgeDuplicateRisk", true);
        body(send("POST", "/analysis-jobs/" + job + (retry ? "/retry" : "/input"), request.toString(), token, null), 202);
    }

    /**
     * 비동기 DB 채택의 기대 상태를 짧게 관찰하고 다른 종료를 정상으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy 분석 실행 검사
     */
    private ObjectNode await(String job, String expected) throws Exception {
        ObjectNode latest = null;
        for (int attempt = 0; attempt < 200; attempt++) {
            latest = body(send("GET", "/analysis-jobs/" + job, null, token, null), 200);
            if (latest.path("state").asString().equals(expected)) return latest;
            if (List.of("failed", "outcomeUnknown", "succeeded", "expired").contains(latest.path("state").asString())) break;
            Thread.sleep(50);
        }
        throw new AssertionError("Expected " + expected + " but received " + latest);
    }

    /**
     * 결과 조회에서 현재 입력과 선택 결과 ID만 제공한다.
     * @created 2026-11-01
     * @usedBy query, isolatesUsers
     */
    private ObjectNode queryBody(ObjectNode meaning, String resultId) {
        ObjectNode value = json.createObjectNode().put("semanticTaskKind", "transactionMeaning");
        value.set("context", meaning.path("context").deepCopy());
        value.set("input", meaning.deepCopy());
        if (resultId != null) value.put("resultId", resultId);
        return value;
    }

    /**
     * 상태 조회와 별도로 인증된 현재 입력으로 결과를 복구한다.
     * @created 2026-11-01
     * @usedBy 결과 검사
     */
    private ObjectNode query(ObjectNode meaning, String resultId, String bearer) throws Exception {
        return body(send("POST", "/analysis-results/query", queryBody(meaning, resultId).toString(), bearer, null), 200);
    }

    /**
     * 테스트 자료의 실제 소유 사용자에 대응하는 로그인 한 건만 선택한다.
     * @created 2026-11-01
     * @usedBy start, isolatesUsers
     */
    private JsonNode credentials(UUID user) throws Exception {
        JsonNode users = json.readTree(Files.readString(Path.of("fixtures/generated-v4/server-seeds.json"))).path("users");
        return unique(users, row -> user.toString().equals(row.path("userId").asString()));
    }

    /**
     * 폐기 DB의 준비 계정에만 임의 시험 코드의 검증값을 설정한다.
     * @created 2026-11-01
     * @usedBy start, isolatesUsers
     */
    private void setCode(UUID user, String value) {
        assertEquals(1, admin.update("UPDATE payse.users SET code_verifier=? WHERE id=?",
            context.getBean(AuthCrypto.class).codeVerifier(user, value), user));
    }

    /**
     * 실제 합성 계정 로그인 API를 호출하고 토큰은 테스트 메모리에만 보관한다.
     * @created 2026-11-01
     * @usedBy start, reusesAfterRelogin, isolatesUsers
     */
    private String login(JsonNode account, String value) throws Exception {
        ObjectNode body = json.createObjectNode().put("name", account.path("name").asString())
            .put("phone", account.path("phone").asString()).put("code", value);
        return body(send("POST", "/demo-sessions", body.toString(), null, null), 201).path("accessToken").asString();
    }

    /**
     * 같은 인증 트랜잭션에서 페이지 제한 없는 실제 DB 원천을 준비한다.
     * @created 2026-11-01
     * @usedBy start, isolatesUsers
     */
    private ObjectNode source(String bearer) {
        return context.getBean(AuthTransactions.class).run(() -> {
            var session = context.getBean(AuthRepository.class).authorize(context.getBean(AuthCrypto.class).tokenDigest(bearer)).orElseThrow();
            return context.getBean(FinancialRepository.class).load(session.userId());
        });
    }

    /**
     * 안정된 원천 참조로 다른 월의 실제 거래를 선택하고 표본·관계·기존 분류를 명시한다.
     * @created 2026-11-01
     * @usedBy start, isolatesUsers, deletionWinsOverLateResult
     */
    private ObjectNode meaningInput(ObjectNode stored, int count) {
        ObjectNode value = json.createObjectNode().put("contractVersion", "PAYSE-ANALYSIS-1")
            .put("semanticTaskKind", "transactionMeaning");
        ObjectNode context = value.putObject("context").put("schemaVersion", "PAYSE-API-0.6-4")
            .put("inputRevision", 1).put("localSessionEpoch", 1);
        for (String field : List.of("dataVersion", "sourceVersion", "ruleVersion", "asOf")) context.set(field, stored.get(field));
        context.putArray("selectedAccountIds");
        ArrayNode items = value.putArray("items"), transactions = value.putArray("transactions"), current = value.putArray("currentClassifications");
        value.putArray("relations");
        value.putArray("unavailableReferences");
        value.putArray("candidates");
        List<String> months = List.of("2025-10", "2025-11", "2025-12", "2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08");
        for (String month : months.subList(0, count)) {
            JsonNode transaction = unique(stored.path("transactions"), row -> row.path("sourceRef").asString().endsWith("/salary/" + month));
            assertEquals(stored.path("userId"), transaction.path("userId"));
            assertEquals("account_entry", transaction.path("recordKind").asString());
            assertTrue(transaction.path("originalTransactionId").isNull());
            String id = transaction.path("transactionId").asString();
            ObjectNode item = items.addObject().put("itemKey", "meaning:" + id).put("targetTransactionId", id).putNull("candidateKey");
            item.putArray("evidenceTransactionIds").add(id);
            ObjectNode projected = transactions.addObject();
            for (String field : List.of("transactionId", "recordKind", "direction", "status", "reflectionReason", "merchantName", "description", "originalTransactionId")) projected.set(field, transaction.get(field).deepCopy());
            current.addObject().put("transactionId", id).set("value", transaction.path("payseTransactionType").deepCopy());
        }
        return value;
    }

    /**
     * 준비된 급여 거래에서 명시 범위를 선택하고 해당 원천·분류만 함께 남긴다.
     * @created 2026-11-01
     * @usedBy 대기 한도·부분 기억 재사용 검사
     */
    private ObjectNode subset(ObjectNode complete, int first, int count) {
        assertTrue(first >= 0 && count > 0 && first + count <= complete.path("items").size());
        ObjectNode result = complete.deepCopy();
        Set<String> ids = new HashSet<>();
        ArrayNode selected = result.putArray("items");
        for (int index = first; index < first + count; index++) {
            JsonNode item = complete.path("items").get(index);
            selected.add(item.deepCopy());
            item.path("evidenceTransactionIds").forEach(id -> ids.add(id.asString()));
        }
        for (String field : List.of("transactions", "currentClassifications")) {
            ArrayNode rows = result.putArray(field);
            for (JsonNode row : complete.path(field)) if (ids.contains(row.path("transactionId").asString())) rows.add(row.deepCopy());
        }
        assertTrue(result.path("relations").isEmpty(), "Subset helper requires independent prepared salary evidence");
        return result;
    }

    /**
     * 만료 작업의 명시 복구 요청에 현재 입력을 연결한다. 일반 접수를 복구로 가장하지 않는다.
     * @created 2026-11-01
     * @usedBy 보관 기산·중요보존 복구 검사
     */
    private ObjectNode recovery(ObjectNode meaning, String previous) {
        ObjectNode value = descriptor(meaning, key()).put("triggerKind", "recovery").put("previousJobId", previous);
        value.set("input", meaning.deepCopy());
        return value;
    }

    /**
     * 결과의 실제 개별 기억 ID에 보관 시각을 대응하여 재사용 기산 변경을 검사한다.
     * @created 2026-11-01
     * @usedBy 보관 기산·중요보존 복구 검사
     */
    private Map<String, String> memoryDates(ObjectNode result) {
        Map<String, String> dates = new HashMap<>();
        for (JsonNode item : result.path("result").path("items")) {
            dates.put(item.path("itemId").asString(), Instant.parse(item.path("storedAt").asString()).toString() + "/" + Instant.parse(item.path("normalExpiresAt").asString()).toString());
        }
        assertFalse(dates.isEmpty());
        return dates;
    }

    /**
     * 이전 응답에 실제 포함된 기억만 DB에서 다시 읽고 오래된 행의 날짜가 보존됐는지 확인한다.
     * @created 2026-11-01
     * @usedBy onlyNewRecoveryAnalysisRestartsRetention
     */
    private Map<String, String> persistedDates(ObjectNode result) {
        Map<String, String> dates = new HashMap<>();
        for (JsonNode item : result.path("result").path("items")) {
            String id = item.path("itemId").asString();
            Map<String, Object> row = admin.queryForMap("SELECT stored_at,normal_expires_at FROM payse.analysis_items WHERE user_id=? AND id=?", owner, UUID.fromString(id));
            Instant stored = ((java.sql.Timestamp) row.get("stored_at")).toInstant();
            Instant expiry = ((java.sql.Timestamp) row.get("normal_expires_at")).toInstant();
            dates.put(id, stored.toString() + "/" + expiry.toString());
        }
        return dates;
    }

    /**
     * 허용된 두 시간 컬럼 중 하나만 준비된 작업 ID·소유자로 읽는다.
     * @created 2026-11-01
     * @usedBy expiresPermitAndExecutionWindow
     */
    private Instant jobTime(String job, String field) {
        assertTrue(Set.of("execution_expires_at", "guard_expires_at").contains(field));
        return admin.queryForObject("SELECT " + field + " FROM payse.analysis_jobs WHERE user_id=? AND id=?",
            java.sql.Timestamp.class, owner, UUID.fromString(job)).toInstant();
    }

    /**
     * 전역 대기 수 검사를 위해 폐기 DB에만 사용자별 두 작업을 관계 ID로 생성한다.
     * @created 2026-11-01
     * @usedBy enforcesGlobalQueueCapacityAcrossOwners
     */
    private List<UUID> seedWaitingUsers(int count) {
        assertEquals("payse_auth_test_analysis", admin.queryForObject("SELECT current_database()", String.class));
        List<UUID> jobs = new ArrayList<>();
        SecureRandom random = new SecureRandom();
        for (int index = 0; index < count; index++) {
            UUID user = UUID.randomUUID();
            String name = "Queue" + (char) ('A' + index);
            String phone = "010" + String.format(java.util.Locale.ROOT, "%08d", random.nextInt(100_000_000));
            assertEquals(1, admin.update("INSERT INTO payse.users (id,name,phone,code_verifier,data_version,created_at) VALUES (?,?,?,'DISABLED',1,clock_timestamp())", user, name, phone));
            for (int item = 0; item < 2; item++) {
                UUID job = UUID.randomUUID();
                String hash = "sha256:" + UUID.randomUUID().toString().replace("-", "") + UUID.randomUUID().toString().replace("-", "");
                assertEquals(1, admin.update("""
                    INSERT INTO payse.analysis_jobs
                      (id,user_id,semantic_kind,trigger_kind,descriptor_hash,accepted_at,guard_expires_at,
                       state,attempt_count,execution_expires_at,detail)
                    VALUES (?,?,'transactionMeaning','A',?,?,?,'queued',0,?,'{}'::jsonb)
                    """, job, user, hash, OffsetDateTime.ofInstant(clock.instant(), ZoneOffset.UTC),
                    clock.instant().atZone(ZoneId.of("Asia/Seoul")).plusMonths(3).toOffsetDateTime(),
                    OffsetDateTime.ofInstant(clock.instant().plusSeconds(180), ZoneOffset.UTC)));
                jobs.add(job);
            }
        }
        return jobs;
    }

    /**
     * 폐기 원천 묶음의 버전만 일관되게 교체하고 선택된 거래 값·관계·분류는 보존한다.
     * @created 2026-11-01
     * @usedBy allowsUnrelatedSourceRefreshDuringExecution
     */
    private void refreshSourceVersion(String version) {
        assertEquals("payse_auth_test_analysis", admin.queryForObject("SELECT current_database()", String.class));
        new TransactionTemplate(new DataSourceTransactionManager(adminPool)).executeWithoutResult(status -> {
            for (String table : List.of("financial_accounts", "financial_cards", "financial_transactions", "card_statements", "statement_items")) {
                admin.update("UPDATE payse." + table + " SET source_version=? WHERE user_id=?", version, owner);
            }
            assertEquals(1, admin.update("UPDATE payse.source_contexts SET source_version=? WHERE user_id=?", version, owner));
            assertEquals(1, admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner));
        });
    }

    /**
     * 빈 결과·중복 결과를 임의 첫 행으로 선택하지 않고 준비 단계에서 실패시킨다.
     * @created 2026-11-01
     * @usedBy credentials, meaningInput, 기억 관계 검사
     */
    private JsonNode unique(JsonNode rows, Predicate<JsonNode> predicate) {
        List<JsonNode> matches = new ArrayList<>();
        for (JsonNode row : rows) if (predicate.test(row)) matches.add(row);
        assertEquals(1, matches.size(), "Expected one fixture relation");
        return matches.getFirst();
    }

    /**
     * 분석 실행 전후 금융 원천·설정·관계·버전이 그대로인지 비교한다.
     * @created 2026-11-01
     * @usedBy start, stop
     */
    private Map<String, String> fingerprint() {
        Map<String, String> result = new HashMap<>();
        for (String table : List.of("source_contexts", "financial_accounts", "financial_cards", "financial_transactions",
                "card_statements", "statement_items", "user_attributes", "institution_links", "obligations", "reserves",
                "reserve_allocations", "write_receipts", "recurring_plans", "recurring_plan_revisions", "recurring_decisions")) {
            result.put(table, admin.queryForObject("SELECT md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
                + "FROM (SELECT to_jsonb(record)::text value FROM payse." + table + " record) rows", String.class));
        }
        result.put("versions", admin.queryForObject("SELECT string_agg(id::text||':'||data_version::text,',' ORDER BY id) FROM payse.users", String.class));
        return result;
    }

    /**
     * HTTP 사용자 작업마다 새 멱등 키를 만들고 테스트에 고정 식별자를 넣지 않는다.
     * @created 2026-11-01
     * @usedBy HTTP 검사
     */
    private String key() { return UUID.randomUUID().toString(); }

    /**
     * Spring 구성에서만 모의 공급자·키 보호기를 주입하며 운영 빈을 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy launch
     */
    @TestConfiguration(proxyBeanMethods = false)
    static class RuntimeConfig {
        /**
         * 검사마다 독립된 실패·지연 제어기를 생성한다.
         * @created 2026-11-01
         * @usedBy Spring 테스트 구성
         */
        @Bean
        ControlledModel controlledModel() { return new ControlledModel(); }

        /**
         * 운영 시계를 바꾸지 않고 각 Spring 검사 인스턴스의 분석 시간 경계만 이동한다.
         * @created 2026-11-01
         * @usedBy Spring 테스트 구성
         */
        @Bean
        @Primary
        TestClock analysisTestClock() { return new TestClock(); }

        /**
         * 운영 KMS를 호출하지 않고 키 감싸기 실패를 독립 제어하는 검사 빈을 만든다.
         * @created 2026-11-01
         * @usedBy Spring 테스트 구성
         */
        @Bean
        TestKeys analysisTestKeys() { return new TestKeys(); }

        /**
         * 실제 공유 AI 검증·실제 봉투 암호화를 모의 공급자와 연결한다.
         * @created 2026-11-01
         * @usedBy Spring 테스트 구성
         */
        @Bean
        @Primary
        AnalysisRuntime analysisTestRuntime(ControlledModel model, TestKeys keys) {
            ObjectNode versions = JsonMapper.builder().build().createObjectNode().put("model", "mock-provider-1")
                .put("prompt", "test-prompt-1").put("response", "PAYSE-ANALYSIS-1").put("policy", "PAYSE-MEANING-1");
            return new AnalysisRuntime(new AnalysisService(model, 6000), new EnvelopeCipher(keys), versions);
        }
    }

    /**
     * 실제 지침·별칭 입력을 받는 네트워크 없는 공급자다. 호출 수·실패·늦은 응답을 제어한다.
     * @created 2026-11-01
     * @usedBy RuntimeConfig
     * @modified 2026-11-01 - 다양한 원천·축소 응답 근거를 사용하는 목록 권한 검사 지원
     */
    static final class ControlledModel implements ModelFactory {
        private final AtomicInteger calls = new AtomicInteger();
        private volatile String failure = "none";
        private volatile boolean important;
        private volatile boolean unknownClassification;
        private volatile boolean minimalEvidence;
        private volatile CountDownLatch returned = new CountDownLatch(1);
        private volatile CountDownLatch entered = new CountDownLatch(0);
        private volatile CountDownLatch release = new CountDownLatch(0);

        /**
         * 다음 생성만 테스트가 해제할 때까지 대기하게 한다.
         * @created 2026-11-01
         * @usedBy 동시 제출·삭제 경합 검사
         */
        void block() { entered = new CountDownLatch(1); release = new CountDownLatch(1); returned = new CountDownLatch(1); }

        /**
         * 모델별 요청 스키마를 실제로 받되 테스트 밖 전송 기능은 만들지 않는다.
         * @created 2026-11-01
         * @usedBy AnalysisService
         */
        @Override
        public ModelGateway create(String instructions, ObjectNode schema) {
            assertTrue(schema.path("properties").has("memories"));
            return new ModelGateway() {
                /**
                 * 테스트 한도를 위한 관측값이며 실제 공급자 토큰 측정값이 아니다.
                 * @created 2026-11-01
                 * @usedBy AnalysisService
                 */
                @Override
                public long countInput(JsonNode input) { return 100; }

                /**
                 * 실제 공유 검증기로 검사할 완결 응답 또는 명시 실패를 한 번 생성한다.
                 * @created 2026-11-01
                 * @usedBy AnalysisService
                 * @modified 2026-11-01 - 목록 검사에만 판단 유보·직접 거래 근거 축소를 명시 적용
                 */
                @Override
                public ModelReply generate(JsonNode input) {
                    calls.incrementAndGet();
                    entered.countDown();
                    try {
                        if (!release.await(15, TimeUnit.SECONDS)) throw new IllegalStateException("Test response was not released");
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        throw new IllegalStateException("Test response interrupted");
                    }
                    if (failure.equals("unknown")) throw new ModelFailure("TRANSMISSION_UNKNOWN", ModelFailure.Stage.GENERATION, true);
                    if (failure.equals("invalid")) return new ModelReply(null, new TokenUsage(100, null, 10), "INCOMPLETE_RESPONSE");
                    var json = JsonMapper.builder().build();
                    ObjectNode response = json.createObjectNode();
                    ObjectNode output = response.putObject("output").put("meaningPolicyVersion", "PAYSE-MEANING-1");
                    ArrayNode rows = output.putArray("items"), memories = response.putArray("memories");
                    for (JsonNode requested : input.path("items")) {
                        String item = requested.path("itemKey").asString();
                        ObjectNode row = rows.addObject().put("itemKey", item).put("reason", RESULT_TEXT);
                        if (minimalEvidence) row.putArray("evidenceTransactionIds").add(requested.path("targetTransactionId").asString());
                        else row.set("evidenceTransactionIds", requested.path("evidenceTransactionIds").deepCopy());
                        row.putObject("meaning").put("status", "unknown").putNull("value").put("reasonCode", "insufficient_evidence");
                        if (unknownClassification) row.putObject("classification").put("status", "unknown").putNull("value").put("reasonCode", "insufficient_evidence");
                        else row.putObject("classification").put("status", "candidate").put("value", "income").put("reasonCode", "supported");
                        memories.addObject().put("itemKey", item).put("active", true).put("isReference", true)
                            .put("important", important).put("referencePolicy", "optional").put("reason", RESULT_TEXT);
                    }
                    returned.countDown();
                    return new ModelReply(response, new TokenUsage(100, null, 80), null);
                }
            };
        }
    }

    /**
     * 분석 시간만 직접 전진시키며 DB·운영 시스템 시계를 변경하지 않는 검사 전용 시계다.
     * @created 2026-11-01
     * @usedBy RuntimeConfig, 시간 경계 검사
     */
    static final class TestClock extends Clock {
        private final AtomicReference<Instant> now = new AtomicReference<>(Instant.now().truncatedTo(ChronoUnit.MILLIS));

        /**
         * 양의 경과만 허용하여 동일 테스트의 저장 시각 역전을 만들지 않는다.
         * @created 2026-11-01
         * @usedBy Q2·실행창·보관 기산 검사
         */
        void advance(Duration duration) {
            assertFalse(duration.isNegative());
            now.updateAndGet(value -> value.plus(duration));
        }

        /**
         * 분석 메타데이터 시계는 UTC 순간이며 보관 달력 변환은 실제 서비스 정책이 담당한다.
         * @created 2026-11-01
         * @usedBy Clock 호출부
         */
        @Override
        public ZoneId getZone() { return ZoneOffset.UTC; }

        /**
         * 별도 시간대를 요청해도 같은 검사 순간을 제공한다.
         * @created 2026-11-01
         * @usedBy Clock 호출부
         */
        @Override
        public Clock withZone(ZoneId zone) { return Clock.fixed(instant(), zone); }

        /**
         * worker와 HTTP 스레드가 같은 원자 시각을 관찰한다.
         * @created 2026-11-01
         * @usedBy AnalysisJobs, AnalysisResults
         */
        @Override
        public Instant instant() { return now.get(); }
    }

    /**
     * 키만 테스트 메모리에 보관하며 사용자·기억 문맥을 확인하는 KMS 대역이다.
     * @created 2026-11-01
     * @usedBy RuntimeConfig
     * @modified 2026-11-01 - 목록별 복호화 호출 수와 권한 변경 경합을 관찰
     */
    static final class TestKeys implements KeyProtector {
        private volatile boolean failWrap;
        private final AtomicInteger unwrapCalls = new AtomicInteger();
        private volatile CountDownLatch unwrapEntered = new CountDownLatch(0);
        private volatile CountDownLatch unwrapRelease = new CountDownLatch(0);
        private final Map<String, byte[]> keys = new ConcurrentHashMap<>();
        private final Map<String, byte[]> contexts = new ConcurrentHashMap<>();

        /**
         * DB 잠금 밖 키 복호화 동안 삭제·로그아웃을 실행하도록 테스트 대기 지점을 설정한다.
         * @created 2026-11-01
         * @usedBy 기억 목록 경합 검사
         */
        void blockUnwrap() { unwrapEntered = new CountDownLatch(1); unwrapRelease = new CountDownLatch(1); }

        /**
         * 독립 데이터 키를 불투명 핸들로 감싸고 입력 배열은 보관하지 않는다.
         * @created 2026-11-01
         * @usedBy EnvelopeCipher
         */
        @Override
        public WrappedKey wrap(byte[] key, byte[] context) {
            if (failWrap) throw new IllegalStateException("Test KMS wrapping failure");
            String id = UUID.randomUUID().toString();
            keys.put(id, key.clone());
            contexts.put(id, context.clone());
            return new WrappedKey("test-only", id.getBytes(StandardCharsets.US_ASCII));
        }

        /**
         * 현재 사용자·기억 문맥이 같은 키만 독립 배열로 반환한다.
         * @created 2026-11-01
         * @usedBy EnvelopeCipher
         * @modified 2026-11-01 - 호출 수와 테스트 제어 대기를 추가하되 AAD 검증 유지
         */
        @Override
        public byte[] unwrap(WrappedKey wrapped, byte[] context) {
            unwrapCalls.incrementAndGet();
            unwrapEntered.countDown();
            try {
                if (!unwrapRelease.await(15, TimeUnit.SECONDS)) throw new IllegalStateException("Test unwrap was not released");
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("Test unwrap interrupted");
            }
            String id = new String(wrapped.ciphertext(), StandardCharsets.US_ASCII);
            if (!"test-only".equals(wrapped.keyRef()) || !Arrays.equals(contexts.get(id), context) || !keys.containsKey(id)) {
                throw new IllegalStateException("Unknown test key context");
            }
            return keys.get(id).clone();
        }
    }
}
