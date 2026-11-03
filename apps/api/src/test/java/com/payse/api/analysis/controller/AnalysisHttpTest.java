package com.payse.api.analysis.controller;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import com.payse.api.ApiTestConstants.AnalysisCodes;
import com.payse.api.ApiTestConstants.AnalysisColumns;
import com.payse.api.ApiTestConstants.AnalysisConfig;
import com.payse.api.ApiTestConstants.AnalysisFields;
import com.payse.api.ApiTestConstants.AnalysisHttp;
import com.payse.api.ApiTestConstants.AnalysisPaths;
import com.payse.api.PayseApiApplication;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.analysis.service.AnalysisEvidence;
import com.payse.api.analysis.service.AnalysisIdentity;
import com.payse.api.analysis.service.AnalysisJobs;
import com.payse.api.analysis.service.AnalysisRuntime;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.mapper.FinancialRepository;
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
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
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
    /**
     * 실제 JPA 최소 권한 연결에서 비용 예약·전송권·별도 정산과 업무 롤백을 확인한다.
     * @created 2026-11-03
     * @usedBy 격리 DB JUnit
     */
    @Test
    void persistsCostsOutsideFinancialTransaction() {
        String project = UUID.randomUUID().toString();
        String version = "test-policy";
        admin.update("""
            INSERT INTO payse.analysis_cost_projects (
              project_id, pricing_version, pricing, opening_micros, limit_micros,
              baseline_verified_at, enabled
            ) VALUES (?, ?, '{}'::jsonb, 0, 45000000000, now(), true)
            """, project, version);
        AnalysisCosts costs = context.getBean(AnalysisCosts.class);
        AuthTransactions transactions = context.getBean(AuthTransactions.class);
        assertTrue(costs.policy(project, version).isEmpty());
        UUID call = UUID.randomUUID();
        transactions.run(() -> {
            costs.reserve(project, call, version, "model", 100);
            return null;
        });
        assertTrue(costs.start(project, call));
        assertFalse(costs.start(project, call));
        costs.settle(project, call, 41);
        UUID rolledBack = UUID.randomUUID();
        assertThrows(IllegalStateException.class, () -> transactions.run(() -> {
            costs.reserve(project, rolledBack, version, "model", 100);
            throw new IllegalStateException("test-rollback");
        }));
        costs.releaseUnstarted(project, call);
        assertEquals(41L, admin.queryForObject(
            "SELECT actual_micros FROM payse.analysis_cost_calls WHERE id=?",
            Long.class,
            call
        ));
        assertEquals(0, admin.queryForObject(
            "SELECT count(*) FROM payse.analysis_cost_calls WHERE id=?",
            Integer.class,
            rolledBack
        ));
    }

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
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     */
    @BeforeAll
    static void requireDatabase() {
        boolean missingEnvironment = System.getenv()
            .keySet()
            .stream()
            .noneMatch(key -> key.startsWith("PAYSE_ANALYSIS_TEST_"));
        assumeFalse(
            missingEnvironment,
            "Run the analysis integration runner with an isolated PostgreSQL directory"
        );
        assertTrue(
            setting("JDBC_URL")
                .matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_analysis")
        );
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
            "payse_auth_test_analysis",
            admin.queryForObject("SELECT current_database()", String.class)
        );
        admin.execute("TRUNCATE payse.users CASCADE");
        admin.execute("TRUNCATE payse.auth_rate_limits");
        prepareSeed();
        JsonNode fixture = json
            .readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots/demo-life.json")));
        owner = UUID.fromString(fixture.path(AnalysisFields.USER_ID).asString());
        assertEquals(
            1,
            admin
                .queryForObject("SELECT count(*) FROM payse.users WHERE id=?", Integer.class, owner)
        );
        credentials = credentials(owner);
        properties = new HashMap<>();
        properties.put(AnalysisConfig.SERVER_PORT, "0");
        properties.put(AnalysisConfig.SERVER_ADDRESS, "127.0.0.1");
        properties.put(AnalysisConfig.BANNER_MODE, "off");
        properties.put(AnalysisConfig.PAYSE_AUTH_PEER_MODE, "direct");
        properties.put(AnalysisConfig.PAYSE_JDBC_URL, setting("JDBC_URL"));
        properties.put(AnalysisConfig.PAYSE_DB_USER, setting("DB_USER"));
        properties.put(AnalysisConfig.PAYSE_DB_PASSWORD, setting("DB_PASSWORD"));
        properties.put(AnalysisConfig.PAYSE_DB_MAX_POOL_SIZE, "6");
        properties.put(AnalysisConfig.PAYSE_DB_CONNECTION_TIMEOUT_MS, "5000");
        properties.put(AnalysisConfig.PAYSE_DB_VALIDATION_TIMEOUT_MS, "1000");
        properties.put(AnalysisConfig.PAYSE_AUTH_CODE_KEY_ID, "analysis-test");
        SecureRandom random = new SecureRandom();
        var secretProperties = List.of(
            AnalysisConfig.PAYSE_AUTH_CODE_KEY_BASE64,
            AnalysisConfig.PAYSE_AUTH_LIMIT_KEY_BASE64,
            AnalysisConfig.PAYSE_FINANCE_CURSOR_KEY_BASE64
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
        source = source(token);
        assertEquals(AnalysisCodes.DRAFT_V4, source.path(AnalysisFields.SCHEMA_VERSION).asString());
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
        app.setAdditionalProfiles(
            analysis ? new String[] {
                "database",
                "auth",
                AnalysisFields.FINANCE,
                "analysis"
            }
                : new String[] {
                    "database",
                    "auth",
                    AnalysisFields.FINANCE
                }
        );
        app.setDefaultProperties(properties);
        context = app.run();
        base = "http://127.0.0.1:"
            + ((WebServerApplicationContext) context).getWebServer().getPort();
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
     * @modified 2026-11-02 - 준비 통계를 최종 제약 검사 전에 갱신하여 재적재 지연 완화
     */
    private void prepareSeed() throws Exception {
        String seed = Files.readString(Path.of(setting("SEED_FILE")));
        var boundary = java.util.regex.Pattern.compile("(?m)^SET CONSTRAINTS ALL IMMEDIATE;\\r?$");
        assertEquals(
            1L,
            boundary.matcher(seed)
                .results()
                .count(),
            "Expected one final seed validation boundary"
        );
        // 폐기 DB의 통계만 갱신한다. 원천 값·제약·RLS·커밋 경계는 동일하게 유지한다.
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
     * 비동기 작업을 해제·종료한 뒤 금융 불변을 확인하고 이 검사 소유 연결만 닫는다.
     * @created 2026-11-01
     * @usedBy JUnit AfterEach
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 기억 목록의 복호화 경합 대기도 종료 전에 해제
     */
    @AfterEach
    void stop() throws Exception {
        try {
            if (model != null) {
                model.release.countDown();
            }
            if (testKeys != null) {
                testKeys.unwrapRelease.countDown();
            }
            if (context != null) {
                context.close();
            }
            if (financialBefore != null) {
                assertEquals(financialBefore, fingerprint(), "Financial data changed");
            }
        } finally {
            if (client != null) {
                client.close();
            }
            if (adminPool != null) {
                adminPool.close();
            }
        }
    }

    /**
     * 실제 접수·상태·본문·암호화 저장·결과 조회와 새 itemKey의 무호출 재사용을 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void storesAndReusesEncryptedResults() throws Exception {
        ObjectNode accepted = accept(input, key());
        assertFalse(accepted.has(AnalysisFields.RESULT));
        String job = accepted.path(AnalysisFields.JOB_ID).asString();
        submit(job, input, key(), false, false);
        ObjectNode completed = await(job, "succeeded");
        assertFalse(completed.has(AnalysisFields.RESULT));
        ObjectNode result = query(input, null, token);
        assertEquals("available", result.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        assertEquals(
            10,
            result.path(AnalysisFields.RESULT)
                .path(AnalysisFields.ITEMS)
                .size()
        );
        assertTrue(result.toString().contains(RESULT_TEXT));
        assertEquals(1, model.calls.get());
        assertEquals(
            10,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_items WHERE user_id=? AND ciphertext IS NOT NULL",
                Integer.class,
                owner
            )
        );
        for (String table : List.of(
            "analysis_jobs",
            "analysis_attempts",
            "analysis_results",
            "analysis_items"
        )) {
            String persisted = admin.queryForObject(
                "SELECT coalesce(jsonb_agg(to_jsonb(t))::text,'[]') FROM payse." + table
                    + " t WHERE user_id=?",
                String.class,
                owner
            );
            assertFalse(persisted.contains(RESULT_TEXT), table + " persisted plaintext");
            assertFalse(
                persisted.contains(AnalysisFields.MERCHANT_NAME),
                table + " persisted financial input"
            );
        }

        ObjectNode renamed = input.deepCopy();
        for (JsonNode item : renamed.path(AnalysisFields.ITEMS)) {
            ((ObjectNode) item).put(
                AnalysisFields.ITEM_KEY,
                "new-screen:" + item.path(AnalysisFields.ITEM_KEY).asString()
            );
        }

        ((ObjectNode) renamed.path(AnalysisFields.CONTEXT)).put(AnalysisFields.INPUT_REVISION, 8)
            .put(AnalysisFields.LOCAL_SESSION_EPOCH, 9);
        ObjectNode reused = query(renamed, result.path(AnalysisFields.RESULT_ID).asString(), token);
        assertEquals("available", reused.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        for (JsonNode item : reused.path(AnalysisFields.RESULT).path(AnalysisFields.ITEMS)) {
            assertTrue(
                item.path(AnalysisFields.INTERPRETATION)
                    .path(AnalysisFields.ITEM_KEY)
                    .asString()
                    .startsWith("new-screen:")
            );
        }

        assertEquals(1, model.calls.get());
    }

    /**
     * 로그아웃·새 세션 이후에도 같은 사용자의 유효 기억을 모델 호출 없이 복구한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void reusesAfterRelogin() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode original = query(input, null, token);
        assertEquals(
            204,
            send(AnalysisHttp.DELETE, AnalysisPaths.CURRENT_SESSION_PATH, null, token, null)
                .statusCode()
        );
        String previous = token;
        token = login(credentials, code);
        assertNotEquals(previous, token);
        ((ObjectNode) input.path(AnalysisFields.CONTEXT))
            .put(AnalysisFields.LOCAL_SESSION_EPOCH, 2);
        ObjectNode recovered = query(
            input,
            original.path(AnalysisFields.RESULT_ID).asString(),
            token
        );
        assertEquals("available", recovered.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        assertEquals(
            original.path(AnalysisFields.RESULT_ID),
            recovered.path(AnalysisFields.RESULT_ID)
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 다른 사용자는 작업·결과·기억을 조회하거나 삭제하지 못하며 자기 캐시도 섞이지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void isolatesUsers() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode result = query(input, null, token);
        JsonNode fixture = json
            .readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots/beta-ready.json")));
        UUID other = UUID.fromString(fixture.path(AnalysisFields.USER_ID).asString());
        assertNotEquals(owner, other);
        setCode(other, code);
        String otherToken = login(credentials(other), code);
        ObjectNode otherInput = meaningInput(source(otherToken), 10);
        assertEquals(
            403,
            send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, otherToken, null)
                .statusCode()
        );
        assertEquals(
            403,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_QUERY_PATH,
                queryBody(otherInput, result.path(AnalysisFields.RESULT_ID).asString()).toString(),
                otherToken,
                null
            ).statusCode()
        );
        JsonNode first = result.path(AnalysisFields.RESULT)
            .path(AnalysisFields.ITEMS)
            .get(0);
        assertEquals(
            403,
            send(
                AnalysisHttp.DELETE,
                AnalysisPaths.ANALYSIS_MEMORY_PATH + first.path(AnalysisFields.ITEM_ID).asString(),
                null,
                otherToken,
                key()
            ).statusCode()
        );
        assertEquals(
            "missing",
            query(otherInput, null, otherToken)
                .path(AnalysisFields.RESULT_AVAILABILITY)
                .asString()
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 동시 제출·동일 키 재전송은 시도 한 건만 만들고 같은 키의 다른 접수 내용은 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     * @modified 2026-11-02 - 기존 자연 정렬을 명시적 수신자 람다로 표현
     */
    @Test
    void serializesIdempotentSubmissions() throws Exception {
        String intakeKey = key();
        ObjectNode descriptor = descriptor(input, intakeKey);
        ObjectNode accepted = body(
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                descriptor.toString(),
                token,
                null
            ),
            202
        );
        String job = accepted.path(AnalysisFields.JOB_ID).asString();
        assertEquals(
            job,
            body(
                send(
                    AnalysisHttp.POST,
                    AnalysisPaths.ANALYSIS_JOBS_PATH,
                    descriptor.toString(),
                    token,
                    null
                ),
                200
            )
                .path(AnalysisFields.JOB_ID)
                .asString()
        );
        ObjectNode changed = descriptor.deepCopy().put(AnalysisFields.TRIGGER_KIND, "B");
        assertEquals(
            409,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                changed.toString(),
                token,
                null
            ).statusCode()
        );
        ObjectNode permit = permit(job);
        ObjectNode request = submission(
            input,
            key(),
            permit.path(AnalysisFields.PERMIT).asString()
        );
        model.block();
        try (var pool = Executors.newFixedThreadPool(2)) {
            var first = pool.submit(
                () -> send(
                    AnalysisHttp.POST,
                    AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.INPUT_SUFFIX,
                    request.toString(),
                    token,
                    null
                )
            );
            var second = pool.submit(
                () -> send(
                    AnalysisHttp.POST,
                    AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.INPUT_SUFFIX,
                    request.toString(),
                    token,
                    null
                )
            );
            List<Integer> codes = new ArrayList<>(
                List.of(
                    first.get(15, TimeUnit.SECONDS).statusCode(),
                    second.get(15, TimeUnit.SECONDS).statusCode()
                )
            );
            codes.sort((left, right) -> left.compareTo(right));
            assertEquals(List.of(200, 202), codes);
        } finally {
            model.release.countDown();
        }

        await(job, "succeeded");
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?",
                Integer.class,
                owner,
                UUID.fromString(job)
            )
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 검증 실패 응답은 저장 성공으로 바꾸지 않고 사용자 재시도에서만 다시 생성한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void retriesFailedOutputOnlyOnRequest() throws Exception {
        model.failure = "invalid";
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "failed");
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_results WHERE user_id=?",
                Integer.class,
                owner
            )
        );
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
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void requiresUnknownAcknowledgement() throws Exception {
        model.failure = "unknown";
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "outcomeUnknown");
        ObjectNode noConsent = submission(input, key(), null)
            .put(AnalysisFields.ACKNOWLEDGE_DUPLICATE_RISK, false);
        assertEquals(
            409,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.RETRY_SUFFIX,
                noConsent.toString(),
                token,
                null
            ).statusCode()
        );
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
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void deletionWinsOverLateResult() throws Exception {
        String firstJob = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(firstJob, input, key(), false, false);
        await(firstJob, "succeeded");
        ObjectNode original = query(input, null, token);
        String firstKey = input.path(AnalysisFields.ITEMS)
            .get(0)
            .path(AnalysisFields.ITEM_KEY)
            .asString();
        JsonNode memory = unique(
            original.path(AnalysisFields.RESULT).path(AnalysisFields.ITEMS),
            row -> firstKey.equals(
                row.path(AnalysisFields.INTERPRETATION)
                    .path(AnalysisFields.ITEM_KEY)
                    .asString()
            )
        );
        clock.advance(Duration.ofMillis(1));
        ObjectNode expanded = meaningInput(source, 11);
        String lateJob = accept(expanded, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        model.block();
        submit(lateJob, expanded, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        String deleteKey = key(), itemId = memory.path(AnalysisFields.ITEM_ID).asString();
        assertEquals(
            204,
            send(
                AnalysisHttp.DELETE,
                AnalysisPaths.ANALYSIS_MEMORY_PATH + itemId,
                null,
                token,
                deleteKey
            ).statusCode()
        );
        assertEquals(
            204,
            send(
                AnalysisHttp.DELETE,
                AnalysisPaths.ANALYSIS_MEMORY_PATH + itemId,
                null,
                token,
                deleteKey
            ).statusCode()
        );
        model.release.countDown();
        await(lateJob, "succeeded");
        ObjectNode result = query(expanded, null, token);
        assertEquals("partial", result.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        assertEquals(
            10,
            result.path(AnalysisFields.RESULT)
                .path(AnalysisFields.ITEMS)
                .size()
        );
        JsonNode status = unique(
            result.path(AnalysisFields.RESULT).path(AnalysisFields.ITEM_AVAILABILITY),
            row -> firstKey.equals(row.path(AnalysisFields.ITEM_KEY).asString())
        );
        assertEquals("deleted", status.path(AnalysisFields.STATE).asString());
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_suppressions WHERE user_id=?",
                Integer.class,
                owner
            )
        );
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_items WHERE user_id=? AND id=? AND ciphertext IS NULL AND crypto_meta IS NULL AND deleted_at IS NOT NULL",
                Integer.class,
                owner,
                UUID.fromString(itemId)
            )
        );
    }

    /**
     * 무효 세션은 잘못된 본문보다 우선하며 인증된 요청은 64KiB를 넘기면 접수하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void authenticatesBeforeReadingBody() throws Exception {
        assertEquals(
            401,
            send(AnalysisHttp.POST, AnalysisPaths.ANALYSIS_JOBS_PATH, "{broken", "invalid", null)
                .statusCode()
        );
        String oversized = " ".repeat(65537);
        assertEquals(
            413,
            send(AnalysisHttp.POST, AnalysisPaths.ANALYSIS_JOBS_PATH, oversized, token, null)
                .statusCode()
        );
        assertEquals(
            0,
            admin.queryForObject("SELECT count(*) FROM payse.analysis_jobs", Integer.class)
        );
        assertEquals(0, model.calls.get());
    }

    /**
     * 분석 프로필이 없으면 경로를 열지 않고 기존 금융 조회는 계속 제공한다.
     * @created 2026-11-01
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
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                descriptor(input, key()).toString(),
                token,
                null
            ).statusCode()
        );
        assertEquals(
            AnalysisCodes.API_V4,
            body(send(AnalysisHttp.GET, AnalysisPaths.SNAPSHOT_PATH, null, token, null), 200)
                .path(AnalysisFields.SCHEMA_VERSION)
                .asString()
        );
    }

    /**
     * 한 건은 60초 전에 전송하지 않고 경계 도달 시에만 같은 작업의 제출 허가를 발급한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void waitsForSingleItemThreshold() throws Exception {
        ObjectNode single = subset(input, 0, 1);
        String job = accept(single, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        ObjectNode waiting = body(
            send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
            200
        );
        assertEquals("queued", waiting.path(AnalysisFields.STATE).asString());
        assertEquals("wait", waiting.path(AnalysisFields.ACTION).asString());
        assertFalse(waiting.has(AnalysisFields.PERMIT));
        clock.advance(Duration.ofSeconds(59));
        assertEquals(
            "wait",
            body(
                send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
                200
            )
                .path(AnalysisFields.ACTION)
                .asString()
        );
        assertEquals(0, model.calls.get());
        clock.advance(Duration.ofSeconds(1));
        ObjectNode ready = permit(job);
        assertEquals(
            clock.instant().plusSeconds(60),
            Instant.parse(ready.path(AnalysisFields.PERMIT_EXPIRES_AT).asString())
        );
        submit(job, single, key(), false, false);
        await(job, "succeeded");
        assertEquals(1, model.calls.get());
        assertEquals(
            1,
            query(single, null, token)
                .path(AnalysisFields.RESULT)
                .path(AnalysisFields.ITEMS)
                .size()
        );
    }

    /**
     * 만료 허가·180초 실행창을 구분하고 사용자 재시도만 새 실행창을 시작한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void expiresPermitAndExecutionWindow() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        ObjectNode first = permit(job);
        Instant initialExpiry = jobTime(job, AnalysisColumns.EXECUTION_EXPIRES_AT);
        clock.advance(Duration.ofSeconds(60));
        ObjectNode stalePermit = submission(
            input,
            key(),
            first.path(AnalysisFields.PERMIT).asString()
        );
        assertEquals(
            409,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.INPUT_SUFFIX,
                stalePermit.toString(),
                token,
                null
            ).statusCode()
        );
        ObjectNode renewed = permit(job);
        assertNotEquals(first.path(AnalysisFields.PERMIT), renewed.path(AnalysisFields.PERMIT));
        assertEquals(initialExpiry, jobTime(job, AnalysisColumns.EXECUTION_EXPIRES_AT));
        clock.advance(Duration.ofSeconds(120));
        ObjectNode missed = body(
            send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
            200
        );
        assertEquals("failed", missed.path(AnalysisFields.STATE).asString());
        assertEquals("retry", missed.path(AnalysisFields.ACTION).asString());
        assertFalse(missed.has(AnalysisFields.PERMIT));
        assertEquals(0, model.calls.get());
        ObjectNode late = submission(input, key(), renewed.path(AnalysisFields.PERMIT).asString());
        assertEquals(
            409,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.INPUT_SUFFIX,
                late.toString(),
                token,
                null
            ).statusCode()
        );
        submit(job, input, key(), true, false);
        await(job, "succeeded");
        assertEquals(
            clock.instant().plusSeconds(180),
            jobTime(job, AnalysisColumns.EXECUTION_EXPIRES_AT)
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 큰 묶음에서 필요한 일부 기억만 재조회할 때 새 itemKey와 무관하게 모델 호출 없이 반환한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void reusesSubsetWithoutWholeBundleIdentity() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode all = query(input, null, token);
        ObjectNode smaller = subset(input, 3, 2);
        for (JsonNode item : smaller.path(AnalysisFields.ITEMS)) {
            ((ObjectNode) item).put(
                AnalysisFields.ITEM_KEY,
                "subset:" + item.path(AnalysisFields.ITEM_KEY).asString()
            );
        }

        ((ObjectNode) smaller.path(AnalysisFields.CONTEXT)).put(AnalysisFields.INPUT_REVISION, 7)
            .put(AnalysisFields.LOCAL_SESSION_EPOCH, 4);
        ObjectNode reused = query(smaller, null, token);
        assertEquals("available", reused.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        assertEquals(all.path(AnalysisFields.RESULT_ID), reused.path(AnalysisFields.RESULT_ID));
        assertEquals(
            2,
            reused.path(AnalysisFields.RESULT)
                .path(AnalysisFields.ITEMS)
                .size()
        );
        Set<String> wanted = new HashSet<>();
        smaller.path(AnalysisFields.ITEMS)
            .forEach(item -> wanted.add(item.path(AnalysisFields.ITEM_KEY).asString()));
        for (JsonNode row : reused.path(AnalysisFields.RESULT).path(AnalysisFields.ITEMS)) {
            assertTrue(
                wanted.remove(
                    row.path(AnalysisFields.INTERPRETATION)
                        .path(AnalysisFields.ITEM_KEY)
                        .asString()
                )
            );
        }

        assertTrue(wanted.isEmpty());
        assertEquals(1, model.calls.get());
    }

    /**
     * 일반 재시도·조회는 최초 저장 기한을 유지하고 만료 후 명시 새 분석만 새 기한을 시작한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void onlyNewRecoveryAnalysisRestartsRetention() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode original = query(input, null, token);
        Map<String, String> originalDates = memoryDates(original);
        clock.advance(Duration.ofSeconds(60));
        ObjectNode repeated = body(
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.RETRY_SUFFIX,
                submission(input, key(), null).toString(),
                token,
                null
            ),
            200
        );
        assertEquals("readResult", repeated.path(AnalysisFields.ACTION).asString());
        assertEquals(originalDates, memoryDates(query(input, null, token)));
        assertEquals(1, model.calls.get());
        clock.advance(Duration.ofDays(100));
        assertEquals(
            "expired",
            body(
                send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
                200
            )
                .path(AnalysisFields.STATE)
                .asString()
        );
        assertEquals(
            "missing",
            query(input, null, token)
                .path(AnalysisFields.RESULT_AVAILABILITY)
                .asString()
        );
        assertEquals(
            409,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.RETRY_SUFFIX,
                submission(input, key(), null).toString(),
                token,
                null
            ).statusCode()
        );
        ObjectNode recovery = recovery(input, job);
        String fresh = body(
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                recovery.toString(),
                token,
                null
            ),
            202
        )
            .path(AnalysisFields.JOB_ID)
            .asString();
        assertNotEquals(job, fresh);
        submit(fresh, input, key(), false, false);
        await(fresh, "succeeded");
        ObjectNode result = query(input, null, token);
        assertEquals("available", result.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        assertNotEquals(
            original.path(AnalysisFields.RESULT_ID),
            result.path(AnalysisFields.RESULT_ID)
        );
        for (JsonNode item : result.path(AnalysisFields.RESULT).path(AnalysisFields.ITEMS)) {
            assertEquals(
                clock.instant(),
                Instant.parse(item.path(AnalysisFields.STORED_AT).asString())
            );
            assertEquals(
                clock.instant()
                    .atZone(ZoneId.of("Asia/Seoul"))
                    .plusMonths(3)
                    .toInstant(),
                Instant.parse(item.path(AnalysisFields.NORMAL_EXPIRES_AT).asString())
            );
        }

        assertEquals(2, model.calls.get());
        assertEquals(originalDates, persistedDates(original));
    }

    /**
     * 만료 작업을 복구해도 중요보존으로 유효한 기억이 있으면 새 분석·저장 기산 없이 재사용한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void recoveryUsesValidImportantMemoryFirst() throws Exception {
        model.important = true;
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode original = query(input, null, token);
        Map<String, String> dates = memoryDates(original);
        clock.advance(Duration.ofDays(100));
        ObjectNode recovered = body(
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                recovery(input, job).toString(),
                token,
                null
            ),
            200
        );
        assertEquals("succeeded", recovered.path(AnalysisFields.STATE).asString());
        assertEquals(
            original.path(AnalysisFields.RESULT_ID),
            recovered.path(AnalysisFields.RESULT_ID)
        );
        assertEquals(dates, memoryDates(query(input, null, token)));
        assertEquals(1, model.calls.get());
        assertEquals(
            10,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_items WHERE user_id=?",
                Integer.class,
                owner
            )
        );
    }

    /**
     * 같은 사용자의 서로 다른 대기 작업 두 개를 허용하고 세 번째 신규 접수만 제한한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void enforcesUserQueueCapacityWithoutBlockingFinance() throws Exception {
        accept(subset(input, 0, 1), key());
        accept(subset(input, 1, 1), key());
        assertEquals(
            429,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                descriptor(subset(input, 2, 1), key()).toString(),
                token,
                null
            ).statusCode()
        );
        assertEquals(
            2,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_jobs WHERE user_id=?",
                Integer.class,
                owner
            )
        );
        assertEquals(
            AnalysisCodes.API_V4,
            body(send(AnalysisHttp.GET, AnalysisPaths.SNAPSHOT_PATH, null, token, null), 200)
                .path(AnalysisFields.SCHEMA_VERSION)
                .asString()
        );
        assertEquals(0, model.calls.get());
    }

    /**
     * 폐기 DB의 다른 사용자 대기 20개가 전체 한도에 포함되고 한 자리 해제 후 정상 접수된다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void enforcesGlobalQueueCapacityAcrossOwners() throws Exception {
        List<UUID> waiting = seedWaitingUsers(10);
        financialBefore = fingerprint();
        ObjectNode single = subset(input, 0, 1);
        assertEquals(20, waiting.size());
        assertEquals(
            429,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                descriptor(single, key()).toString(),
                token,
                null
            ).statusCode()
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_jobs WHERE user_id=?",
                Integer.class,
                owner
            )
        );
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.analysis_jobs SET state='cancelled',finished_at=? WHERE id=?",
                OffsetDateTime.ofInstant(clock.instant(), ZoneOffset.UTC),
                waiting.getFirst()
            )
        );
        accept(single, key());
        assertEquals(
            20,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_jobs WHERE state IN ('queued','awaitingInput')",
                Integer.class
            )
        );
        assertEquals(0, model.calls.get());
    }

    /**
     * 관련 거래가 같으면 원천 묶음 버전 상승만으로 실행 결과를 버리지 않으며 최초 출처는 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void allowsUnrelatedSourceRefreshDuringExecution() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        model.block();
        submit(job, input, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        String nextVersion = "analysis-refresh:" + UUID.randomUUID();
        refreshSourceVersion(nextVersion);
        financialBefore = fingerprint();
        model.release.countDown();
        await(job, "succeeded");
        ObjectNode current = meaningInput(source(token), 10);
        assertEquals(
            nextVersion,
            current.path(AnalysisFields.CONTEXT)
                .path(AnalysisFields.SOURCE_VERSION)
                .asString()
        );
        ObjectNode result = query(current, null, token);
        assertEquals("available", result.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        assertEquals(
            input.path(AnalysisFields.CONTEXT).path(AnalysisFields.SOURCE_VERSION),
            result.path(AnalysisFields.PROVENANCE).path(AnalysisFields.SOURCE_VERSION)
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 실행 중 관련 거래의 사용자 분류가 바뀌면 늦은 응답을 저장·적용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsRelatedClassificationChangeDuringExecution() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        model.block();
        submit(job, input, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        UUID transaction = UUID.fromString(
            input.path(AnalysisFields.ITEMS)
                .get(0)
                .path(AnalysisFields.TARGET_TRANSACTION_ID)
                .asString()
        );
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.financial_transactions SET payse_transaction_type='expense' WHERE user_id=? AND id=?",
                owner,
                transaction
            )
        );
        assertEquals(
            1,
            admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner)
        );
        financialBefore = fingerprint();
        model.release.countDown();
        await(job, "failed");
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_results WHERE user_id=?",
                Integer.class,
                owner
            )
        );
        assertEquals(
            "missing",
            query(meaningInput(source(token), 10), null, token)
                .path(AnalysisFields.RESULT_AVAILABILITY)
                .asString()
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 모델 응답을 기다리던 세션을 로그아웃하면 새 세션이 생겨도 옛 실행이 결과를 저장하지 못한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void logoutBlocksPendingResultAdoption() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        model.block();
        submit(job, input, key(), false, false);
        assertTrue(model.entered.await(10, TimeUnit.SECONDS));
        String ended = token;
        assertEquals(
            204,
            send(AnalysisHttp.DELETE, AnalysisPaths.CURRENT_SESSION_PATH, null, token, null)
                .statusCode()
        );
        token = login(credentials, code);
        assertNotEquals(ended, token);
        assertEquals(
            401,
            send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, ended, null)
                .statusCode()
        );
        model.release.countDown();
        assertTrue(model.returned.await(10, TimeUnit.SECONDS));
        clock.advance(Duration.ofSeconds(181));
        ObjectNode waiting = body(
            send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
            200
        );
        assertEquals("outcomeUnknown", waiting.path(AnalysisFields.STATE).asString());
        assertEquals(
            "missing",
            query(input, null, token)
                .path(AnalysisFields.RESULT_AVAILABILITY)
                .asString()
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_results WHERE user_id=?",
                Integer.class,
                owner
            )
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 공급자 성공 뒤 키 감싸기가 실패해도 관측 사용량을 지우거나 암호화되지 않은 결과를 저장하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void preservesUsageWhenEncryptionFails() throws Exception {
        testKeys.failWrap = true;
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "failed");
        JsonNode attempt = json.readTree(
            admin.queryForObject(
                """
            SELECT to_jsonb(a)::text
            FROM payse.analysis_attempts a
            WHERE user_id=? AND job_id=?
            """,
                String.class,
                owner,
                UUID.fromString(job)
            )
        );
        assertEquals("settled", attempt.path(AnalysisColumns.DISPATCH_STATE).asString());
        assertTrue(
            attempt.path(AnalysisFields.DETAIL)
                .path(AnalysisFields.USAGE_KNOWN)
                .asBoolean()
        );
        assertEquals(
            100,
            attempt.path(AnalysisFields.DETAIL)
                .path(AnalysisFields.INPUT_TOKENS)
                .asInt()
        );
        assertEquals(
            80,
            attempt.path(AnalysisFields.DETAIL)
                .path(AnalysisFields.OUTPUT_TOKENS)
                .asInt()
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_results WHERE user_id=?",
                Integer.class,
                owner
            )
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_items WHERE user_id=?",
                Integer.class,
                owner
            )
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 정상 완료 뒤 중복 실패 콜백이 와도 정산된 사용량·채택 결과를 수정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     * @modified 2026-11-03 - 작업 원천 보충 필드 추가에 맞춰 중복 콜백 검사 유지
     */
    @Test
    void settledUsageSurvivesLateFailureCallback() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        String sql = "SELECT to_jsonb(a)::text FROM payse.analysis_attempts a WHERE user_id=? AND job_id=?";
        JsonNode before = json
            .readTree(admin.queryForObject(sql, String.class, owner, UUID.fromString(job)));
        assertEquals("settled", before.path(AnalysisColumns.DISPATCH_STATE).asString());
        assertEquals(
            100,
            before.path(AnalysisFields.DETAIL)
                .path(AnalysisFields.INPUT_TOKENS)
                .asInt()
        );
        String hash = admin.queryForObject(
            "SELECT input_hash FROM payse.analysis_jobs WHERE user_id=? AND id=?",
            String.class,
            owner,
            UUID.fromString(job)
        );
        Class<?> workType = Class.forName("com.payse.api.analysis.service.AnalysisJobs$Work");
        var constructor = workType.getDeclaredConstructor(
            String.class,
            UUID.class,
            UUID.class,
            UUID.class,
            String.class,
            String.class,
            ObjectNode.class,
            ObjectNode.class
        );
        constructor.setAccessible(true);
        Object work = constructor.newInstance(
            token,
            owner,
            UUID.fromString(job),
            UUID.fromString(before.path(AnalysisFields.ID).asString()),
            hash,
            new AnalysisIdentity().sourceHash(source, input),
            input.deepCopy(),
            new AnalysisEvidence().modelFacts(owner, source, input)
        );
        var callback = AnalysisJobs.class
            .getDeclaredMethod("fail", workType, boolean.class, String.class, TokenUsage.class);
        callback.setAccessible(true);
        callback.invoke(
            context.getBean(AnalysisJobs.class),
            work,
            true,
            "LATE_FAILURE_TEST",
            new TokenUsage(900, null, 900)
        );
        callback.invoke(context.getBean(AnalysisJobs.class), work, true, "LATE_FAILURE_TEST", null);
        JsonNode after = json
            .readTree(admin.queryForObject(sql, String.class, owner, UUID.fromString(job)));
        assertEquals(before, after);
        assertEquals(
            "succeeded",
            body(
                send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
                200
            )
                .path(AnalysisFields.STATE)
                .asString()
        );
        assertEquals(
            "available",
            query(input, null, token)
                .path(AnalysisFields.RESULT_AVAILABILITY)
                .asString()
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 최초 분석의 화면 선택·epoch·revision은 출처로 공개하지 않고 현재 요청 문맥만 반환한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void limitsPublicProvenanceToAnalysisSource() throws Exception {
        String target = input.path(AnalysisFields.ITEMS)
            .get(0)
            .path(AnalysisFields.TARGET_TRANSACTION_ID)
            .asString();
        JsonNode transaction = unique(
            source.path(AnalysisFields.TRANSACTIONS),
            value -> target.equals(value.path(AnalysisFields.TRANSACTION_ID).asString())
        );
        ObjectNode originalContext = (ObjectNode) input.path(AnalysisFields.CONTEXT);
        originalContext.putArray(AnalysisFields.SELECTED_ACCOUNT_IDS)
            .add(transaction.path(AnalysisFields.ACCOUNT_ID).asString());
        originalContext.put(AnalysisFields.LOCAL_SESSION_EPOCH, 5)
            .put(AnalysisFields.INPUT_REVISION, 6);
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "succeeded");
        ObjectNode current = input.deepCopy();
        ObjectNode currentContext = (ObjectNode) current.path(AnalysisFields.CONTEXT);
        currentContext.putArray(AnalysisFields.SELECTED_ACCOUNT_IDS);
        currentContext.put(AnalysisFields.LOCAL_SESSION_EPOCH, 9)
            .put(AnalysisFields.INPUT_REVISION, 10);
        ObjectNode response = query(current, null, token);
        JsonNode provenance = response.path(AnalysisFields.PROVENANCE);
        assertEquals(
            Set.of(
                AnalysisFields.SCHEMA_VERSION,
                AnalysisFields.DATA_VERSION,
                AnalysisFields.SOURCE_VERSION,
                AnalysisFields.RULE_VERSION,
                AnalysisFields.AS_OF,
                AnalysisFields.VERSIONS,
                AnalysisFields.ANALYSIS_INPUT_HASH
            ),
            provenance.propertyNames()
        );
        for (String field : List.of(
            AnalysisFields.SELECTED_ACCOUNT_IDS,
            AnalysisFields.LOCAL_SESSION_EPOCH,
            AnalysisFields.INPUT_REVISION
        )) {
            assertFalse(provenance.has(field));
        }

        assertEquals(currentContext, response.path(AnalysisFields.CONTEXT));
        assertEquals("available", response.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        assertEquals(1, model.calls.get());
    }

    /**
     * 로그아웃은 대기 작업·옛 허가를 취소하고 새 세션의 명시 재시도만 한 번 실행한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void logoutCancelsWaitingPermitButAllowsExplicitRetry() throws Exception {
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        ObjectNode oldPermit = permit(job);
        assertEquals("awaitingInput", oldPermit.path(AnalysisFields.STATE).asString());
        String ended = token;
        assertEquals(
            204,
            send(AnalysisHttp.DELETE, AnalysisPaths.CURRENT_SESSION_PATH, null, token, null)
                .statusCode()
        );
        token = login(credentials, code);
        assertNotEquals(ended, token);
        ((ObjectNode) input.path(AnalysisFields.CONTEXT))
            .put(AnalysisFields.LOCAL_SESSION_EPOCH, 2);
        ObjectNode cancelled = body(
            send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
            200
        );
        assertEquals("cancelled", cancelled.path(AnalysisFields.STATE).asString());
        assertEquals("retry", cancelled.path(AnalysisFields.ACTION).asString());
        assertFalse(cancelled.has(AnalysisFields.PERMIT));
        ObjectNode oldSubmission = submission(
            input,
            key(),
            oldPermit.path(AnalysisFields.PERMIT).asString()
        );
        assertEquals(
            409,
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.INPUT_SUFFIX,
                oldSubmission.toString(),
                token,
                null
            ).statusCode()
        );
        assertEquals(
            0,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?",
                Integer.class,
                owner,
                UUID.fromString(job)
            )
        );
        assertEquals(0, model.calls.get());
        submit(job, input, key(), true, false);
        await(job, "succeeded");
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?",
                Integer.class,
                owner,
                UUID.fromString(job)
            )
        );
        assertEquals(1, model.calls.get());
    }

    /**
     * 실패 이후 관련 DB 금액이 바뀌면 같은 작업 재시도를 거절하고 새 원천 접수로 구분한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void changedAmountRejectsOldRetryBeforeNewAttempt() throws Exception {
        model.failure = "invalid";
        String job = accept(input, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, input, key(), false, false);
        await(job, "failed");
        UUID target = UUID.fromString(
            input.path(AnalysisFields.ITEMS)
                .get(0)
                .path(AnalysisFields.TARGET_TRANSACTION_ID)
                .asString()
        );
        long before = admin.queryForObject(
            "SELECT amount_krw FROM payse.financial_transactions WHERE user_id=? AND id=?",
            Long.class,
            owner,
            target
        );
        assertTrue(before < 9_000_000_000_000L);
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.financial_transactions SET amount_krw=? WHERE user_id=? AND id=?",
                before + 1,
                owner,
                target
            )
        );
        assertEquals(
            1,
            admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner)
        );
        financialBefore = fingerprint();
        ObjectNode refreshed = meaningInput(source(token), 10);
        assertEquals(new AnalysisIdentity().hint(input), new AnalysisIdentity().hint(refreshed));
        HttpResponse<String> rejected = send(
            AnalysisHttp.POST,
            AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.RETRY_SUFFIX,
            submission(refreshed, key(), null).toString(),
            token,
            null
        );
        assertEquals(409, rejected.statusCode());
        assertEquals(
            AnalysisCodes.STALE_DATA,
            json.readTree(rejected.body())
                .path(AnalysisFields.ERROR)
                .path(AnalysisFields.CODE)
                .asString()
        );
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_attempts WHERE user_id=? AND job_id=?",
                Integer.class,
                owner,
                UUID.fromString(job)
            )
        );
        assertEquals(1, model.calls.get());
        model.failure = "none";
        String currentJob = accept(refreshed, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        assertNotEquals(job, currentJob);
        submit(currentJob, refreshed, key(), false, false);
        await(currentJob, "succeeded");
        assertEquals(
            "available",
            query(refreshed, null, token)
                .path(AnalysisFields.RESULT_AVAILABILITY)
                .asString()
        );
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
        String inactive = memoryId(
            input.path(AnalysisFields.ITEMS)
                .get(0)
                .path(AnalysisFields.ITEM_KEY)
                .asString()
        );
        String changed = memoryId(
            input.path(AnalysisFields.ITEMS)
                .get(1)
                .path(AnalysisFields.ITEM_KEY)
                .asString()
        );
        String transaction = input.path(AnalysisFields.ITEMS)
            .get(1)
            .path(AnalysisFields.TARGET_TRANSACTION_ID)
            .asString();
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.analysis_items SET active=false,metadata_version=metadata_version+1 WHERE user_id=? AND id=?",
                owner,
                UUID.fromString(inactive)
            )
        );
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.financial_transactions SET amount_krw=amount_krw+1 WHERE user_id=? AND id=?",
                owner,
                UUID.fromString(transaction)
            )
        );
        assertEquals(
            1,
            admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner)
        );
        financialBefore = fingerprint();
        Map<String, String> dates = allMemoryDates();
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories("", token);
        assertEquals(
            AnalysisCodes.ANALYSIS_CONTRACT,
            listed.path(AnalysisFields.CONTRACT_VERSION).asString()
        );
        assertEquals(10, listed.path(AnalysisFields.ITEMS).size());
        for (JsonNode item : listed.path(AnalysisFields.ITEMS)) {
            assertEquals("unchecked", item.path(AnalysisFields.RESULT_AVAILABILITY).asString());
            assertEquals("available", item.path(AnalysisFields.CONTENT_AVAILABILITY).asString());
            assertTrue(item.has(AnalysisFields.INTERPRETATION));
            assertEquals(RESULT_TEXT, item.path(AnalysisFields.RETENTION_REASON).asString());
            assertFalse(item.has(AnalysisFields.SOURCE_REFS));
            assertFalse(item.has(AnalysisFields.SOURCE_HASH));
            assertFalse(item.has(AnalysisFields.ID));
        }

        assertFalse(
            memory(listed, inactive)
                .path(AnalysisFields.ACTIVE)
                .asBoolean()
        );
        assertEquals(
            2,
            memory(listed, inactive)
                .path(AnalysisFields.METADATA_VERSION)
                .asInt()
        );
        assertTrue(
            memory(listed, changed)
                .path(AnalysisFields.SOURCE_CHANGED)
                .asBoolean()
        );
        assertFalse(
            memory(listed, inactive)
                .path(AnalysisFields.SOURCE_CHANGED)
                .asBoolean()
        );
        assertEquals(10, testKeys.unwrapCalls.get());
        assertEquals(1, model.calls.get());
        assertEquals(dates, allMemoryDates());
    }

    /**
     * 과거 기간 조회도 삭제·일반 만료 본문을 되살리지 않고 중요보존 예외만 복호화한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @Test
    void memoryPeriodsDoNotRestoreExpiredOrDeletedBodies() throws Exception {
        storeMemories(input);
        LocalDate day = clock.instant()
            .atZone(ZoneId.of("Asia/Seoul"))
            .toLocalDate();
        String removed = memoryId(
            input.path(AnalysisFields.ITEMS)
                .get(0)
                .path(AnalysisFields.ITEM_KEY)
                .asString()
        );
        String retained = memoryId(
            input.path(AnalysisFields.ITEMS)
                .get(1)
                .path(AnalysisFields.ITEM_KEY)
                .asString()
        );
        assertEquals(
            204,
            send(
                AnalysisHttp.DELETE,
                AnalysisPaths.ANALYSIS_MEMORY_PATH + removed,
                null,
                token,
                key()
            ).statusCode()
        );
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.analysis_items SET important=true,is_reference=true,metadata_version=metadata_version+1 WHERE user_id=? AND id=?",
                owner,
                UUID.fromString(retained)
            )
        );
        Map<String, String> dates = allMemoryDates();
        clock.advance(Duration.ofDays(100));
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories(period(day, day), token);
        assertEquals(10, listed.path(AnalysisFields.ITEMS).size());
        for (JsonNode item : listed.path(AnalysisFields.ITEMS)) {
            String id = item.path(AnalysisFields.ITEM_ID).asString();
            if (id.equals(retained)) {
                assertEquals(
                    "available",
                    item.path(AnalysisFields.CONTENT_AVAILABILITY).asString()
                );
                assertEquals("unchecked", item.path(AnalysisFields.RESULT_AVAILABILITY).asString());
                assertTrue(item.has(AnalysisFields.INTERPRETATION));
            } else {
                assertHiddenMemory(item, id.equals(removed) ? "deleted" : "expired");
            }
        }

        assertEquals(1, testKeys.unwrapCalls.get());
        testKeys.unwrapCalls.set(0);
        assertTrue(
            listMemories(period(day.plusDays(1), day.plusDays(1)), token)
                .path(AnalysisFields.ITEMS)
                .isEmpty()
        );
        assertEquals(0, testKeys.unwrapCalls.get());
        assertEquals(dates, allMemoryDates());
        assertEquals(1, model.calls.get());
        for (String invalid : List.of(
            "?startDate=" + day,
            "?endDate=" + day,
            "?startDate=2026-02-30&endDate=2026-03-01",
            period(day.plusDays(1), day)
        )) {
            body(
                send(AnalysisHttp.GET, AnalysisPaths.MEMORIES_PATH + invalid, null, token, null),
                422
            );
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
        LocalDate first = clock.instant()
            .atZone(seoul)
            .toLocalDate();
        Instant midnight = first.plusDays(1)
            .atStartOfDay(seoul)
            .toInstant();
        clock.advance(Duration.between(clock.instant(), midnight.minusMillis(1)));
        storeMemories(subset(twenty, 0, 10));
        clock.advance(Duration.ofMillis(2));
        storeMemories(subset(twenty, 10, 10));
        ObjectNode before = listMemories(period(first, first), token);
        ObjectNode after = listMemories(period(first.plusDays(1), first.plusDays(1)), token);
        assertEquals(10, before.path(AnalysisFields.ITEMS).size());
        assertEquals(10, after.path(AnalysisFields.ITEMS).size());
        Set<String> ids = new HashSet<>();
        for (JsonNode item : before.path(AnalysisFields.ITEMS)) {
            assertEquals(
                first,
                Instant.parse(item.path(AnalysisFields.STORED_AT).asString())
                    .atZone(seoul)
                    .toLocalDate()
            );
            assertTrue(ids.add(item.path(AnalysisFields.ITEM_ID).asString()));
        }
        for (JsonNode item : after.path(AnalysisFields.ITEMS)) {
            assertEquals(
                first.plusDays(1),
                Instant.parse(item.path(AnalysisFields.STORED_AT).asString())
                    .atZone(seoul)
                    .toLocalDate()
            );
            assertTrue(ids.add(item.path(AnalysisFields.ITEM_ID).asString()));
        }

        assertEquals(
            20,
            listMemories(period(first, first.plusDays(1)), token)
                .path(AnalysisFields.ITEMS)
                .size()
        );
        assertEquals(2, model.calls.get());
    }

    /**
     * 20건 페이지는 다른 사용자·세션·기간에 재사용되지 않으며 해당 페이지 본문만 복호화한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @Test
    void memoryPagesBindOwnerSessionAndPeriod() throws Exception {
        model.unknownClassification = true;
        storeMemories(independentInput(25));
        LocalDate day = clock.instant()
            .atZone(ZoneId.of("Asia/Seoul"))
            .toLocalDate();
        String range = period(day, day);
        testKeys.unwrapCalls.set(0);
        ObjectNode first = listMemories(range, token);
        assertEquals(20, first.path(AnalysisFields.ITEMS).size());
        assertTrue(
            first.path(AnalysisFields.PAGE_INFO)
                .path(AnalysisFields.HAS_MORE)
                .asBoolean()
        );
        String cursor = first.path(AnalysisFields.PAGE_INFO)
            .path(AnalysisFields.NEXT_CURSOR)
            .asString();
        assertFalse(cursor.isBlank());
        assertEquals(20, testKeys.unwrapCalls.get());
        testKeys.unwrapCalls.set(0);
        ObjectNode second = listMemories(range + "&cursor=" + cursor, token);
        assertEquals(5, second.path(AnalysisFields.ITEMS).size());
        assertFalse(
            second.path(AnalysisFields.PAGE_INFO)
                .path(AnalysisFields.HAS_MORE)
                .asBoolean()
        );
        assertTrue(
            second.path(AnalysisFields.PAGE_INFO)
                .path(AnalysisFields.NEXT_CURSOR)
                .isNull()
        );
        assertEquals(5, testKeys.unwrapCalls.get());
        List<String> actual = new ArrayList<>();
        for (JsonNode page : List.of(first, second)) {
            for (JsonNode item : page.path(AnalysisFields.ITEMS)) {
                assertEquals("unchecked", item.path(AnalysisFields.RESULT_AVAILABILITY).asString());
                actual.add(item.path(AnalysisFields.ITEM_ID).asString());
            }
        }

        assertEquals(25, new HashSet<>(actual).size());
        assertEquals(
            actual.stream()
                .sorted()
                .toList(),
            actual
        );
        assertEquals(
            admin.queryForList(
                "SELECT id::text FROM payse.analysis_items WHERE user_id=? ORDER BY id",
                String.class,
                owner
            ),
            actual
        );
        body(
            send(
                AnalysisHttp.GET,
                AnalysisPaths.MEMORIES_PATH + period(day, day.plusDays(1)) + "&cursor=" + cursor,
                null,
                token,
                null
            ),
            409
        );
        JsonNode beta = json
            .readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots/beta-ready.json")));
        UUID other = UUID.fromString(beta.path(AnalysisFields.USER_ID).asString());
        setCode(other, code);
        String otherToken = login(credentials(other), code);
        assertTrue(
            listMemories("", otherToken)
                .path(AnalysisFields.ITEMS)
                .isEmpty()
        );
        body(
            send(
                AnalysisHttp.GET,
                AnalysisPaths.MEMORIES_PATH + range + "&cursor=" + cursor,
                null,
                otherToken,
                null
            ),
            403
        );
        assertEquals(
            204,
            send(AnalysisHttp.DELETE, AnalysisPaths.CURRENT_SESSION_PATH, null, token, null)
                .statusCode()
        );
        token = login(credentials, code);
        body(
            send(
                AnalysisHttp.GET,
                AnalysisPaths.MEMORIES_PATH + range + "&cursor=" + cursor,
                null,
                token,
                null
            ),
            403
        );
        body(send(AnalysisHttp.GET, "/analysis-memories?cursor=invalid", null, token, null), 400);
        assertEquals(1, model.calls.get());
    }

    /**
     * 모델이 답변 근거를 줄여도 원래 입력의 연결 거래 권한까지 기억 조회에서 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @Test
    void memoryListUsesFullStoredSourcePermissions() throws Exception {
        JsonNode relation = unique(
            source.path(AnalysisFields.TRANSACTION_RELATIONS),
            row -> "fixture-owned-transfer-1".equals(row.path("evidenceRef").asString())
        );
        JsonNode from = unique(
            source.path(AnalysisFields.TRANSACTIONS),
            row -> relation.path(AnalysisFields.FROM_ID)
                .equals(row.path(AnalysisFields.TRANSACTION_ID))
        );
        JsonNode to = unique(
            source.path(AnalysisFields.TRANSACTIONS),
            row -> relation.path(AnalysisFields.TO_ID)
                .equals(row.path(AnalysisFields.TRANSACTION_ID))
        );
        ObjectNode extended = meaningInput(source, 9);
        appendMeaning(extended, from);
        appendMeaning(extended, to);
        ObjectNode link = ((ArrayNode) extended.path(AnalysisFields.RELATIONS)).addObject();
        for (String field : List.of(
            AnalysisFields.KIND,
            AnalysisFields.FROM_ID,
            AnalysisFields.TO_ID
        )) {
            link.set(field, relation.get(field));
        }

        ObjectNode fromItem = (ObjectNode) unique(
            extended.path(AnalysisFields.ITEMS),
            row -> from.path(AnalysisFields.TRANSACTION_ID)
                .equals(row.path(AnalysisFields.TARGET_TRANSACTION_ID))
        );
        ((ArrayNode) fromItem.path(AnalysisFields.EVIDENCE_TRANSACTION_IDS))
            .add(to.path(AnalysisFields.TRANSACTION_ID).asString());
        model.unknownClassification = true;
        model.minimalEvidence = true;
        storeMemories(extended);
        String fromMemory = memoryId(fromItem.path(AnalysisFields.ITEM_KEY).asString());
        String toMemory = memoryId("meaning:" + to.path(AnalysisFields.TRANSACTION_ID).asString());
        ObjectNode original = listMemories("", token);
        assertEquals(
            1,
            memory(original, fromMemory)
                .path(AnalysisFields.INTERPRETATION)
                .path(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
                .size()
        );
        String targetInstitution = institutionFor(to);
        assertNotEquals(institutionFor(from), targetInstitution);
        disconnectInstitution(targetInstitution);
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories("", token);
        assertEquals(11, listed.path(AnalysisFields.ITEMS).size());
        assertHiddenMemory(memory(listed, fromMemory), AnalysisCodes.RESTRICTED);
        assertHiddenMemory(memory(listed, toMemory), AnalysisCodes.RESTRICTED);
        assertEquals(9, testKeys.unwrapCalls.get());
        assertFalse(listed.toString().contains(to.path(AnalysisFields.TRANSACTION_ID).asString()));
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
        String original = memoryId(
            input.path(AnalysisFields.ITEMS)
                .get(0)
                .path(AnalysisFields.ITEM_KEY)
                .asString()
        );
        String legacy = cloneMemory(original, true);
        testKeys.unwrapCalls.set(0);
        ObjectNode listed = listMemories("", token);
        assertEquals(11, listed.path(AnalysisFields.ITEMS).size());
        assertHiddenMemory(memory(listed, legacy), AnalysisCodes.UNVERIFIED);
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
        cloneMemory(
            memoryId(
                input.path(AnalysisFields.ITEMS)
                    .get(0)
                    .path(AnalysisFields.ITEM_KEY)
                    .asString()
            ),
            false
        );
        HttpResponse<String> response = send(
            AnalysisHttp.GET,
            AnalysisPaths.MEMORIES_PATH,
            null,
            token,
            null
        );
        body(response, 503);
        assertFalse(response.body().contains(RESULT_TEXT));
        assertFalse(response.body().contains(AnalysisFields.INTERPRETATION));
    }

    /**
     * 만료 직전 시작한 복호화가 정확한 만료 시각에 끝나면 본문을 반환하지 않고 재조회를 요구한다.
     * @created 2026-11-02
     * @usedBy JUnit
     */
    @Test
    void memoryListRechecksExpiryAfterDecrypt() throws Exception {
        storeMemories(input);
        String itemKey = input.path(AnalysisFields.ITEMS)
            .get(0)
            .path(AnalysisFields.ITEM_KEY)
            .asString();
        String itemId = memoryId(itemKey);
        ObjectNode initial = listMemories("", token);
        JsonNode selected = memory(initial, itemId);
        String expiryText = selected.path(AnalysisFields.NORMAL_EXPIRES_AT).asString();
        Instant expiresAt = Instant.parse(expiryText);
        assertEquals(10, initial.path(AnalysisFields.ITEMS).size());
        for (JsonNode item : initial.path(AnalysisFields.ITEMS)) {
            assertFalse(item.path(AnalysisFields.IMPORTANT).asBoolean());
            assertTrue(item.has(AnalysisFields.INTERPRETATION));
            assertEquals(
                expiresAt,
                Instant.parse(item.path(AnalysisFields.NORMAL_EXPIRES_AT).asString())
            );
        }

        Map<String, String> dates = allMemoryDates();

        Instant beforeExpiry = expiresAt.minusMillis(1);
        clock.advance(Duration.between(clock.instant(), beforeExpiry));
        assertEquals(beforeExpiry, clock.instant());
        testKeys.unwrapCalls.set(0);
        testKeys.blockUnwrap();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var pending = executor.submit(
                () -> send(
                    AnalysisHttp.GET,
                    AnalysisPaths.MEMORIES_PATH,
                    null,
                    token,
                    null
                )
            );
            try {
                assertTrue(testKeys.unwrapEntered.await(10, TimeUnit.SECONDS));
                clock.advance(Duration.ofMillis(1));
                assertEquals(expiresAt, clock.instant());
            } finally {
                testKeys.unwrapRelease.countDown();
            }

            HttpResponse<String> response = pending.get(15, TimeUnit.SECONDS);
            ObjectNode failure = body(response, 409);
            assertEquals(
                AnalysisCodes.STALE_DATA,
                failure.path(AnalysisFields.ERROR)
                    .path(AnalysisFields.CODE)
                    .asString()
            );
            assertFalse(response.body().contains(RESULT_TEXT));
            assertFalse(response.body().contains(AnalysisFields.INTERPRETATION));
        }

        testKeys.unwrapCalls.set(0);
        ObjectNode expired = listMemories("", token);
        assertEquals(10, expired.path(AnalysisFields.ITEMS).size());
        for (JsonNode item : expired.path(AnalysisFields.ITEMS)) {
            assertHiddenMemory(item, "expired");
        }

        assertEquals(0, testKeys.unwrapCalls.get());
        assertEquals(dates, allMemoryDates());
        assertEquals(1, model.calls.get());
    }

    /**
     * 외부 키 복호화 중 삭제된 기억은 뒤늦게 응답되지 않고 변경 충돌로 재조회를 요구한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryListRechecksDeletionAfterDecrypt() throws Exception {
        storeMemories(input);
        String removed = memoryId(
            input.path(AnalysisFields.ITEMS)
                .get(0)
                .path(AnalysisFields.ITEM_KEY)
                .asString()
        );
        testKeys.blockUnwrap();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var pending = executor
                .submit(
                    () -> send(AnalysisHttp.GET, AnalysisPaths.MEMORIES_PATH, null, token, null)
                );
            assertTrue(testKeys.unwrapEntered.await(10, TimeUnit.SECONDS));
            try {
                assertEquals(
                    204,
                    send(
                        AnalysisHttp.DELETE,
                        AnalysisPaths.ANALYSIS_MEMORY_PATH + removed,
                        null,
                        token,
                        key()
                    ).statusCode()
                );
            } finally {
                testKeys.unwrapRelease.countDown();
            }

            HttpResponse<String> response = pending.get(15, TimeUnit.SECONDS);
            body(response, 409);
            assertFalse(response.body().contains(RESULT_TEXT));
        }

        assertHiddenMemory(memory(listMemories("", token), removed), "deleted");
        assertEquals(
            1,
            admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_suppressions WHERE user_id=?",
                Integer.class,
                owner
            )
        );
    }

    /**
     * 복호화 동안 금융사 연결이 해제되면 읽었던 평문을 버리고 새 권한으로 재조회하게 한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @Test
    void memoryListRechecksDisconnectAfterDecrypt() throws Exception {
        storeMemories(input);
        JsonNode transaction = unique(
            source.path(AnalysisFields.TRANSACTIONS),
            row -> input.path(AnalysisFields.ITEMS)
                .get(0)
                .path(AnalysisFields.TARGET_TRANSACTION_ID)
                .equals(row.path(AnalysisFields.TRANSACTION_ID))
        );
        testKeys.blockUnwrap();
        try (var executor = Executors.newVirtualThreadPerTaskExecutor()) {
            var pending = executor
                .submit(
                    () -> send(AnalysisHttp.GET, AnalysisPaths.MEMORIES_PATH, null, token, null)
                );
            assertTrue(testKeys.unwrapEntered.await(10, TimeUnit.SECONDS));
            try {
                disconnectInstitution(institutionFor(transaction));
            } finally {
                testKeys.unwrapRelease.countDown();
            }

            HttpResponse<String> response = pending.get(15, TimeUnit.SECONDS);
            body(response, 409);
            assertFalse(response.body().contains(RESULT_TEXT));
        }

        testKeys.unwrapCalls.set(0);
        for (JsonNode item : listMemories("", token).path(AnalysisFields.ITEMS)) {
            assertHiddenMemory(item, AnalysisCodes.RESTRICTED);
        }

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
            var pending = executor
                .submit(
                    () -> send(AnalysisHttp.GET, AnalysisPaths.MEMORIES_PATH, null, token, null)
                );
            assertTrue(testKeys.unwrapEntered.await(10, TimeUnit.SECONDS));
            try {
                assertEquals(
                    204,
                    send(AnalysisHttp.DELETE, AnalysisPaths.CURRENT_SESSION_PATH, null, token, null)
                        .statusCode()
                );
            } finally {
                testKeys.unwrapRelease.countDown();
            }

            HttpResponse<String> response = pending.get(15, TimeUnit.SECONDS);
            body(response, 401);
            assertFalse(response.body().contains(RESULT_TEXT));
            assertFalse(response.body().contains(AnalysisFields.INTERPRETATION));
        }
    }

    /**
     * 목록도 인증을 필터보다 먼저 검사하며 GET 본문·허용하지 않은 필터를 무시하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void memoryListAuthenticatesBeforeFilters() throws Exception {
        body(
            send(AnalysisHttp.GET, "/analysis-memories?startDate=bad", null, "invalid", null),
            401
        );
        body(send(AnalysisHttp.GET, "/analysis-memories?startDate=bad", null, token, null), 422);
        body(send(AnalysisHttp.GET, "/analysis-memories?limit=1", null, token, null), 400);
        body(send(AnalysisHttp.GET, AnalysisPaths.MEMORIES_PATH, "{}", token, null), 422);
        assertTrue(
            listMemories("?startDate=0001-01-01&endDate=9999-12-31", token)
                .path(AnalysisFields.ITEMS)
                .isEmpty()
        );
        assertEquals(0, model.calls.get());
    }

    /**
     * 실제 접수·입력·비동기 채택 경로로 기억을 준비하며 목록 검사 전 불필요한 복호화는 하지 않는다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private void storeMemories(ObjectNode meaning) throws Exception {
        String job = accept(meaning, key())
            .path(AnalysisFields.JOB_ID)
            .asString();
        submit(job, meaning, key(), false, false);
        await(job, "succeeded");
    }

    /**
     * 검토 목록은 적용용 현재 입력을 제출하지 않는 독립 조회 경로로 읽는다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private ObjectNode listMemories(String query, String bearer) throws Exception {
        return body(
            send(AnalysisHttp.GET, AnalysisPaths.MEMORIES_PATH + query, null, bearer, null),
            200
        );
    }

    /**
     * 준비 입력의 키와 현재 소유자로 기억 한 건을 식별하고 중복·누락은 테스트 실패로 처리한다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private String memoryId(String itemKey) {
        List<UUID> ids = admin.queryForList(
            "SELECT id FROM payse.analysis_items WHERE user_id=? AND item_key=?",
            UUID.class,
            owner,
            itemKey
        );
        assertEquals(1, ids.size());
        return ids.getFirst().toString();
    }

    /**
     * 목록의 공개 기억 ID를 기준으로 한 항목만 선택한다.
     * @created 2026-11-01
     * @usedBy 기억 목록 HTTP 검사
     */
    private JsonNode memory(JsonNode response, String id) {
        return unique(
            response.path(AnalysisFields.ITEMS),
            item -> id.equals(item.path(AnalysisFields.ITEM_ID).asString())
        );
    }

    /**
     * 숨긴 본문·보존 설명·원천 변경 추정이 응답에서 제외되며 적용 상태는 미검증인지 검사한다.
     * @created 2026-11-01
     * @usedBy 만료·삭제·권한·기존 행 검사
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private void assertHiddenMemory(JsonNode item, String state) {
        assertEquals(state, item.path(AnalysisFields.CONTENT_AVAILABILITY).asString());
        assertEquals("unchecked", item.path(AnalysisFields.RESULT_AVAILABILITY).asString());
        for (String field : List.of(
            AnalysisFields.INTERPRETATION,
            AnalysisFields.RETENTION_REASON,
            AnalysisFields.SOURCE_CHANGED,
            AnalysisFields.SOURCE_REFS,
            AnalysisFields.SOURCE_HASH
        )) {
            assertFalse(item.has(field), field);
        }
        for (String field : List.of(
            AnalysisFields.ITEM_ID,
            AnalysisFields.RESULT_ID,
            AnalysisFields.SEMANTIC_TASK_KIND,
            AnalysisFields.ACTIVE,
            AnalysisFields.IS_REFERENCE,
            AnalysisFields.IMPORTANT,
            AnalysisFields.REFERENCE_POLICY,
            AnalysisFields.STORED_AT,
            AnalysisFields.NORMAL_EXPIRES_AT,
            AnalysisFields.METADATA_VERSION
        )) {
            assertTrue(item.has(field), field);
        }
    }

    /**
     * 양끝 저장일을 포함하는 명시 조회 문자열을 만들며 날짜 정책은 서버가 검증한다.
     * @created 2026-11-01
     * @usedBy 날짜 필터·페이지 검사
     */
    private String period(LocalDate start, LocalDate end) {
        return "?startDate=" + start + "&endDate=" + end;
    }

    /**
     * 최초 저장·정상 만료 시각은 전체 기억 ID별로 보존되는지 확인할 비교 자료다.
     * @created 2026-11-01
     * @usedBy 읽기·보존 기산 검사
     */
    private Map<String, String> allMemoryDates() {
        Map<String, String> dates = new HashMap<>();
        for (Map<String, Object> row : admin.queryForList(
            "SELECT id,stored_at,normal_expires_at FROM payse.analysis_items WHERE user_id=?",
            owner
        )) {
            dates.put(
                row.get(AnalysisFields.ID).toString(),
                row.get(AnalysisColumns.STORED_AT_FIELD) + "/"
                    + row.get(AnalysisColumns.NORMAL_EXPIRES_AT_FIELD)
            );
        }

        assertFalse(dates.isEmpty());
        return dates;
    }

    /**
     * 페이지 크기 검사는 기존 금융 거래를 사용하며 관계를 생략한 가짜 근거를 만들지 않는다.
     * @created 2026-11-01
     * @usedBy 페이지·서울 날짜 경계 검사
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode independentInput(int count) {
        Set<String> linked = new HashSet<>();
        for (JsonNode relation : source.path(AnalysisFields.TRANSACTION_RELATIONS)) {
            linked.add(relation.path(AnalysisFields.FROM_ID).asString());
            linked.add(relation.path(AnalysisFields.TO_ID).asString());
        }

        List<JsonNode> rows = new ArrayList<>();
        for (JsonNode row : source.path(AnalysisFields.TRANSACTIONS)) {
            if ("account_entry".equals(row.path(AnalysisFields.RECORD_KIND).asString())
                && row.path(AnalysisFields.ORIGINAL_TRANSACTION_ID).isNull()
                && !linked.contains(row.path(AnalysisFields.TRANSACTION_ID).asString())) {
                rows.add(row);
            }
        }

        rows.sort(Comparator.comparing(row -> row.path(AnalysisFields.TRANSACTION_ID).asString()));
        assertTrue(
            rows.size() >= count,
            "Prepared source must contain enough independent account records"
        );
        ObjectNode result = meaningInput(source, 0);
        for (JsonNode row : rows.subList(0, count)) {
            appendMeaning(result, row);
        }

        return result;
    }

    /**
     * 실제 원천 한 건과 현재 분류를 입력 스키마의 허용 필드로만 투영한다.
     * @created 2026-11-01
     * @usedBy independentInput, 관계 권한 검사
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private void appendMeaning(ObjectNode meaning, JsonNode transaction) {
        assertEquals(owner.toString(), transaction.path(AnalysisFields.USER_ID).asString());
        assertTrue(transaction.path(AnalysisFields.ORIGINAL_TRANSACTION_ID).isNull());
        String id = transaction.path(AnalysisFields.TRANSACTION_ID).asString();
        ObjectNode item = ((ArrayNode) meaning.path(AnalysisFields.ITEMS)).addObject()
            .put(AnalysisFields.ITEM_KEY, "meaning:" + id)
            .put(AnalysisFields.TARGET_TRANSACTION_ID, id)
            .putNull(AnalysisFields.CANDIDATE_KEY);
        item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS).add(id);
        ObjectNode projected = ((ArrayNode) meaning.path(AnalysisFields.TRANSACTIONS)).addObject();
        for (String field : List.of(
            AnalysisFields.TRANSACTION_ID,
            AnalysisFields.RECORD_KIND,
            AnalysisFields.DIRECTION,
            AnalysisFields.STATUS,
            AnalysisFields.REFLECTION_REASON,
            AnalysisFields.MERCHANT_NAME,
            AnalysisFields.DESCRIPTION,
            AnalysisFields.ORIGINAL_TRANSACTION_ID
        )) {
            projected.set(field, transaction.get(field).deepCopy());
        }

        ((ArrayNode) meaning.path(AnalysisFields.CURRENT_CLASSIFICATIONS)).addObject()
            .put(AnalysisFields.TRANSACTION_ID, id)
            .set(
                AnalysisFields.VALUE,
                transaction.path(AnalysisFields.PAYSE_TRANSACTION_TYPE).deepCopy()
            );
    }

    /**
     * 거래의 실제 계좌 관계를 따라 연결 해제할 기관을 찾고 표시명은 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 연결 권한 검사
     */
    private String institutionFor(JsonNode transaction) {
        JsonNode account = unique(
            source.path(AnalysisFields.ACCOUNTS),
            row -> transaction.path(AnalysisFields.ACCOUNT_ID)
                .equals(row.path(AnalysisFields.ACCOUNT_ID))
        );
        return account.path(AnalysisFields.INSTITUTION_CODE).asString();
    }

    /**
     * 폐기 DB의 지정 기관 연결만 해제하고 이후 API가 다른 금융 상태를 바꾸지 않는지 비교한다.
     * @created 2026-11-01
     * @usedBy 연결 해제 경합·관계 권한 검사
     */
    private void disconnectInstitution(String institution) {
        assertFalse(institution.isBlank());
        assertEquals(
            1,
            admin.update(
                "UPDATE payse.institution_links SET disconnected_at=clock_timestamp() WHERE user_id=? AND institution_code=? AND disconnected_at IS NULL",
                owner,
                institution
            )
        );
        assertEquals(
            1,
            admin.update("UPDATE payse.users SET data_version=data_version+1 WHERE id=?", owner)
        );
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
        assertEquals(
            1,
            admin.update(
                """
            INSERT INTO payse.analysis_results
              (id,user_id,semantic_kind,input_hash,provenance,accepted_manifest,committed_at)
            SELECT ?,r.user_id,r.semantic_kind,r.input_hash,r.provenance,r.accepted_manifest,r.committed_at
            FROM payse.analysis_results r JOIN payse.analysis_items i
              ON i.user_id=r.user_id AND i.result_id=r.id
            WHERE i.user_id=? AND i.id=?
            """,
                result,
                owner,
                previous
            )
        );
        String sourceColumns = legacy ? "NULL,NULL" : "source_refs,source_hash";
        assertEquals(
            1,
            admin.update(
                """
            INSERT INTO payse.analysis_items
              (id,user_id,result_id,item_key,semantic_kind,memory_key,evidence_hash,stored_at,normal_expires_at,
               ciphertext,crypto_meta,active,is_reference,important,reference_policy,metadata_version,
               policy_version,policy_actor,deleted_at,purge_requested_at,source_refs,source_hash)
            SELECT ?,user_id,?,item_key,semantic_kind,memory_key,evidence_hash,stored_at,normal_expires_at,
               ciphertext,crypto_meta,active,is_reference,important,reference_policy,metadata_version,
               policy_version,policy_actor,deleted_at,purge_requested_at,
            """ + sourceColumns + " FROM payse.analysis_items WHERE user_id=? AND id=?",
                item,
                result,
                owner,
                previous
            )
        );
        return item.toString();
    }

    /**
     * 요청 경로와 본문을 실제 HTTP로 보내고 세션 쿠키를 만들지 않는지 확인한다.
     * @created 2026-11-01
     * @usedBy HTTP 검사 및 로그인
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private HttpResponse<String> send(
        String method,
        String path,
        String body,
        String bearer,
        String idempotency
    ) throws Exception {
        var request = HttpRequest.newBuilder(URI.create(base + path))
            .timeout(Duration.ofSeconds(20));
        if (bearer != null) {
            request.header(AnalysisHttp.AUTHORIZATION, AnalysisHttp.BEARER_PREFIX + bearer);
        }
        if (idempotency != null) {
            request.header(AnalysisHttp.IDEMPOTENCY_HEADER, idempotency);
        }
        request.header(AnalysisHttp.CONTENT_TYPE, AnalysisHttp.JSON_UTF8);
        request.method(
            method,
            body == null ? HttpRequest.BodyPublishers.noBody()
                : HttpRequest.BodyPublishers.ofString(body)
        );
        var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
        assertTrue(
            response.headers()
                .allValues(AnalysisHttp.SET_COOKIE)
                .isEmpty()
        );
        return response;
    }

    /**
     * 정상 분석 응답의 상태와 no-store를 확인하고 본문 객체를 읽는다.
     * @created 2026-11-01
     * @usedBy API 검사 도우미
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode body(HttpResponse<String> response, int status) {
        assertEquals(status, response.statusCode(), response.body());
        assertTrue(
            response.headers()
                .firstValue(AnalysisHttp.CACHE_CONTROL)
                .orElse("")
                .contains(AnalysisHttp.NO_STORE)
        );
        return (ObjectNode) json.readTree(response.body());
    }

    /**
     * 현재 입력과 같은 대상의 descriptor를 만든다. 본문은 접수에서 보내지 않는다.
     * @created 2026-11-01
     * @usedBy accept, serializesIdempotentSubmissions, disabledProfile
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode descriptor(ObjectNode meaning, String requestKey) {
        ObjectNode value = json.createObjectNode()
            .put(AnalysisFields.TRIGGER_KIND, "A")
            .put(AnalysisFields.SEMANTIC_TASK_KIND, "transactionMeaning")
            .put(AnalysisFields.INPUT_HASH_HINT, new AnalysisIdentity().hint(meaning))
            .put(AnalysisFields.IDEMPOTENCY_KEY, requestKey);
        value.set(AnalysisFields.CONTEXT, meaning.path(AnalysisFields.CONTEXT).deepCopy());
        value.putArray(AnalysisFields.REASON_CODES);
        ArrayNode items = value.putArray(AnalysisFields.ITEMS);
        for (JsonNode item : meaning.path(AnalysisFields.ITEMS)) {
            ObjectNode descriptor = items.addObject()
                .put(AnalysisFields.ITEM_KEY, item.path(AnalysisFields.ITEM_KEY).asString());
            descriptor.set(
                AnalysisFields.EVIDENCE_TRANSACTION_IDS,
                item.path(AnalysisFields.EVIDENCE_TRANSACTION_IDS).deepCopy()
            );
            descriptor.putArray(AnalysisFields.CANDIDATE_IDS);
        }

        return value;
    }

    /**
     * 새 접수의 202 응답만 확인한다.
     * @created 2026-11-01
     * @usedBy 분석 실행 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode accept(ObjectNode meaning, String requestKey) throws Exception {
        return body(
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                descriptor(meaning, requestKey).toString(),
                token,
                null
            ),
            202
        );
    }

    /**
     * 10개 대상의 즉시 제출 허가를 기다리며 상태 조회에서 모델을 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy submit, serializesIdempotentSubmissions
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode permit(String job) throws Exception {
        for (int attempt = 0; attempt < 80; attempt++) {
            ObjectNode response = body(
                send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
                200
            );
            if (response.path(AnalysisFields.ACTION)
                .asString()
                .equals("submitInput")) {
                assertFalse(
                    response.path(AnalysisFields.PERMIT)
                        .asString()
                        .isBlank()
                );
                return response;
            }
            Thread.sleep(50);
        }

        throw new AssertionError(
            "Input permit was not issued for the confirmed ten-item threshold"
        );
    }

    /**
     * 같은 문맥과 명시 사용자 작업 키로 본문 제출/재시도 요청을 만든다.
     * @created 2026-11-01
     * @usedBy submit, serializesIdempotentSubmissions, requiresUnknownAcknowledgement
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode submission(ObjectNode meaning, String requestKey, String permit) {
        ObjectNode value = json.createObjectNode().put(AnalysisFields.IDEMPOTENCY_KEY, requestKey);
        value.set(AnalysisFields.CONTEXT, meaning.path(AnalysisFields.CONTEXT).deepCopy());
        value.set(AnalysisFields.INPUT, meaning.deepCopy());
        if (permit != null) {
            value.put(AnalysisFields.PERMIT, permit);
        }
        return value;
    }

    /**
     * 입력 허가 또는 명시 재시도 경로로 한 번 제출한다. 자동 공급자 재시도는 없다.
     * @created 2026-11-01
     * @usedBy 분석 실행 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private void submit(
        String job,
        ObjectNode meaning,
        String requestKey,
        boolean retry,
        boolean acknowledge
    ) throws Exception {
        ObjectNode request = submission(
            meaning,
            requestKey,
            retry ? null
                : permit(job)
                    .path(AnalysisFields.PERMIT)
                    .asString()
        );
        if (acknowledge) {
            request.put(AnalysisFields.ACKNOWLEDGE_DUPLICATE_RISK, true);
        }
        body(
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOB_PATH + job
                    + (retry ? AnalysisPaths.RETRY_SUFFIX : AnalysisPaths.INPUT_SUFFIX),
                request.toString(),
                token,
                null
            ),
            202
        );
    }

    /**
     * 비동기 DB 채택의 기대 상태를 짧게 관찰하고 다른 종료를 정상으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy 분석 실행 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode await(String job, String expected) throws Exception {
        ObjectNode latest = null;
        for (int attempt = 0; attempt < 200; attempt++) {
            latest = body(
                send(AnalysisHttp.GET, AnalysisPaths.ANALYSIS_JOB_PATH + job, null, token, null),
                200
            );
            if (latest.path(AnalysisFields.STATE)
                .asString()
                .equals(expected)) {
                return latest;
            }
            if (List.of(
                "failed",
                "outcomeUnknown",
                "succeeded",
                "expired"
            ).contains(latest.path(AnalysisFields.STATE).asString())) {
                break;
            }

            Thread.sleep(50);
        }

        throw new AssertionError("Expected " + expected + " but received " + latest);
    }

    /**
     * 결과 조회에서 현재 입력과 선택 결과 ID만 제공한다.
     * @created 2026-11-01
     * @usedBy query, isolatesUsers
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode queryBody(ObjectNode meaning, String resultId) {
        ObjectNode value = json.createObjectNode()
            .put(AnalysisFields.SEMANTIC_TASK_KIND, "transactionMeaning");
        value.set(AnalysisFields.CONTEXT, meaning.path(AnalysisFields.CONTEXT).deepCopy());
        value.set(AnalysisFields.INPUT, meaning.deepCopy());
        if (resultId != null) {
            value.put(AnalysisFields.RESULT_ID, resultId);
        }
        return value;
    }

    /**
     * 상태 조회와 별도로 인증된 현재 입력으로 결과를 복구한다.
     * @created 2026-11-01
     * @usedBy 결과 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode query(ObjectNode meaning, String resultId, String bearer) throws Exception {
        return body(
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_QUERY_PATH,
                queryBody(meaning, resultId).toString(),
                bearer,
                null
            ),
            200
        );
    }

    /**
     * 테스트 자료의 실제 소유 사용자에 대응하는 로그인 한 건만 선택한다.
     * @created 2026-11-01
     * @usedBy start, isolatesUsers
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private JsonNode credentials(UUID user) throws Exception {
        JsonNode users = json
            .readTree(Files.readString(Path.of("fixtures/generated-v4/server-seeds.json")))
            .path(AnalysisFields.USERS);
        return unique(
            users,
            row -> user.toString().equals(row.path(AnalysisFields.USER_ID).asString())
        );
    }

    /**
     * 폐기 DB의 준비 계정에만 임의 시험 코드의 검증값을 설정한다.
     * @created 2026-11-01
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
     * 실제 합성 계정 로그인 API를 호출하고 토큰은 테스트 메모리에만 보관한다.
     * @created 2026-11-01
     * @usedBy start, reusesAfterRelogin, isolatesUsers
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private String login(JsonNode account, String value) throws Exception {
        ObjectNode body = json.createObjectNode()
            .put(AnalysisFields.NAME, account.path(AnalysisFields.NAME).asString())
            .put(AnalysisFields.PHONE, account.path(AnalysisFields.PHONE).asString())
            .put(AnalysisFields.CODE, value);
        return body(
            send(AnalysisHttp.POST, AnalysisPaths.SESSIONS_PATH, body.toString(), null, null),
            201
        )
            .path(AnalysisFields.ACCESS_TOKEN)
            .asString();
    }

    /**
     * 같은 인증 트랜잭션에서 페이지 제한 없는 실제 DB 원천을 준비한다.
     * @created 2026-11-01
     * @usedBy start, isolatesUsers
     */
    private ObjectNode source(String bearer) {
        return context.getBean(AuthTransactions.class)
            .run(
                () -> {
                    var session = context.getBean(AuthRepository.class)
                        .authorize(context.getBean(AuthCrypto.class).tokenDigest(bearer))
                        .orElseThrow();
                    return context.getBean(FinancialRepository.class).load(session.userId());
                }
            );
    }

    /**
     * 안정된 원천 참조로 다른 월의 실제 거래를 선택하고 표본·관계·기존 분류를 명시한다.
     * @created 2026-11-01
     * @usedBy start, isolatesUsers, deletionWinsOverLateResult
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode meaningInput(ObjectNode stored, int count) {
        ObjectNode value = json.createObjectNode()
            .put(AnalysisFields.CONTRACT_VERSION, AnalysisCodes.ANALYSIS_CONTRACT)
            .put(AnalysisFields.SEMANTIC_TASK_KIND, "transactionMeaning");
        ObjectNode context = value.putObject(AnalysisFields.CONTEXT)
            .put(AnalysisFields.SCHEMA_VERSION, AnalysisCodes.API_V4)
            .put(AnalysisFields.INPUT_REVISION, 1)
            .put(AnalysisFields.LOCAL_SESSION_EPOCH, 1);
        for (String field : List.of(
            AnalysisFields.DATA_VERSION,
            AnalysisFields.SOURCE_VERSION,
            AnalysisFields.RULE_VERSION,
            AnalysisFields.AS_OF
        )) {
            context.set(field, stored.get(field));
        }

        context.putArray(AnalysisFields.SELECTED_ACCOUNT_IDS);
        ArrayNode items = value.putArray(AnalysisFields.ITEMS),
            transactions = value.putArray(AnalysisFields.TRANSACTIONS),
            current = value.putArray(AnalysisFields.CURRENT_CLASSIFICATIONS);
        value.putArray(AnalysisFields.RELATIONS);
        value.putArray(AnalysisFields.UNAVAILABLE_REFERENCES);
        value.putArray(AnalysisFields.CANDIDATES);
        List<String> months = List.of(
            "2025-10",
            "2025-11",
            "2025-12",
            "2026-01",
            "2026-02",
            "2026-03",
            "2026-04",
            "2026-05",
            "2026-06",
            "2026-07",
            "2026-08"
        );
        for (String month : months.subList(0, count)) {
            JsonNode transaction = unique(
                stored.path(AnalysisFields.TRANSACTIONS),
                row -> row.path(AnalysisFields.SOURCE_REF)
                    .asString()
                    .endsWith("/salary/" + month)
            );
            assertEquals(
                stored.path(AnalysisFields.USER_ID),
                transaction.path(AnalysisFields.USER_ID)
            );
            assertEquals("account_entry", transaction.path(AnalysisFields.RECORD_KIND).asString());
            assertTrue(transaction.path(AnalysisFields.ORIGINAL_TRANSACTION_ID).isNull());
            String id = transaction.path(AnalysisFields.TRANSACTION_ID).asString();
            ObjectNode item = items.addObject()
                .put(AnalysisFields.ITEM_KEY, "meaning:" + id)
                .put(AnalysisFields.TARGET_TRANSACTION_ID, id)
                .putNull(AnalysisFields.CANDIDATE_KEY);
            item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS).add(id);
            ObjectNode projected = transactions.addObject();
            var sourceFields = List.of(
                AnalysisFields.TRANSACTION_ID,
                AnalysisFields.RECORD_KIND,
                AnalysisFields.DIRECTION,
                AnalysisFields.STATUS,
                AnalysisFields.REFLECTION_REASON,
                AnalysisFields.MERCHANT_NAME,
                AnalysisFields.DESCRIPTION,
                AnalysisFields.ORIGINAL_TRANSACTION_ID
            );
            for (String field : sourceFields) {
                projected.set(field, transaction.get(field).deepCopy());
            }

            current.addObject()
                .put(AnalysisFields.TRANSACTION_ID, id)
                .set(
                    AnalysisFields.VALUE,
                    transaction.path(AnalysisFields.PAYSE_TRANSACTION_TYPE).deepCopy()
                );
        }

        return value;
    }

    /**
     * 준비된 급여 거래에서 명시 범위를 선택하고 해당 원천·분류만 함께 남긴다.
     * @created 2026-11-01
     * @usedBy 대기 한도·부분 기억 재사용 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode subset(ObjectNode complete, int first, int count) {
        assertTrue(
            first >= 0 && count > 0 && first + count <= complete.path(AnalysisFields.ITEMS).size()
        );
        ObjectNode result = complete.deepCopy();
        Set<String> ids = new HashSet<>();
        ArrayNode selected = result.putArray(AnalysisFields.ITEMS);
        for (int index = first; index < first + count; index++) {
            JsonNode item = complete.path(AnalysisFields.ITEMS).get(index);
            selected.add(item.deepCopy());
            item.path(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
                .forEach(id -> ids.add(id.asString()));
        }
        for (String field : List
            .of(AnalysisFields.TRANSACTIONS, AnalysisFields.CURRENT_CLASSIFICATIONS)) {
            ArrayNode rows = result.putArray(field);
            for (JsonNode row : complete.path(field)) {
                if (ids.contains(row.path(AnalysisFields.TRANSACTION_ID).asString())) {
                    rows.add(row.deepCopy());
                }
            }
        }

        assertTrue(
            result.path(AnalysisFields.RELATIONS).isEmpty(),
            "Subset helper requires independent prepared salary evidence"
        );
        return result;
    }

    /**
     * 만료 작업의 명시 복구 요청에 현재 입력을 연결한다. 일반 접수를 복구로 가장하지 않는다.
     * @created 2026-11-01
     * @usedBy 보관 기산·중요보존 복구 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode recovery(ObjectNode meaning, String previous) {
        ObjectNode value = descriptor(meaning, key())
            .put(AnalysisFields.TRIGGER_KIND, "recovery")
            .put(AnalysisFields.PREVIOUS_JOB_ID, previous);
        value.set(AnalysisFields.INPUT, meaning.deepCopy());
        return value;
    }

    /**
     * 결과의 실제 개별 기억 ID에 보관 시각을 대응하여 재사용 기산 변경을 검사한다.
     * @created 2026-11-01
     * @usedBy 보관 기산·중요보존 복구 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private Map<String, String> memoryDates(ObjectNode result) {
        Map<String, String> dates = new HashMap<>();
        for (JsonNode item : result.path(AnalysisFields.RESULT).path(AnalysisFields.ITEMS)) {
            dates.put(
                item.path(AnalysisFields.ITEM_ID).asString(),
                Instant.parse(item.path(AnalysisFields.STORED_AT).asString()).toString() + "/"
                    + Instant.parse(item.path(AnalysisFields.NORMAL_EXPIRES_AT).asString())
                        .toString()
            );
        }

        assertFalse(dates.isEmpty());
        return dates;
    }

    /**
     * 이전 응답에 실제 포함된 기억만 DB에서 다시 읽고 오래된 행의 날짜가 보존됐는지 확인한다.
     * @created 2026-11-01
     * @usedBy onlyNewRecoveryAnalysisRestartsRetention
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private Map<String, String> persistedDates(ObjectNode result) {
        Map<String, String> dates = new HashMap<>();
        for (JsonNode item : result.path(AnalysisFields.RESULT).path(AnalysisFields.ITEMS)) {
            String id = item.path(AnalysisFields.ITEM_ID).asString();
            Map<String, Object> row = admin.queryForMap(
                "SELECT stored_at,normal_expires_at FROM payse.analysis_items WHERE user_id=? AND id=?",
                owner,
                UUID.fromString(id)
            );
            Instant stored = ((java.sql.Timestamp) row.get(AnalysisColumns.STORED_AT_FIELD))
                .toInstant();
            Instant expiry = ((java.sql.Timestamp) row.get(AnalysisColumns.NORMAL_EXPIRES_AT_FIELD))
                .toInstant();
            dates.put(id, stored.toString() + "/" + expiry.toString());
        }

        return dates;
    }

    /**
     * 허용된 두 시간 컬럼 중 하나만 준비된 작업 ID·소유자로 읽는다.
     * @created 2026-11-01
     * @usedBy expiresPermitAndExecutionWindow
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private Instant jobTime(String job, String field) {
        assertTrue(
            Set.of(AnalysisColumns.EXECUTION_EXPIRES_AT, AnalysisColumns.GUARD_EXPIRES_AT)
                .contains(field)
        );
        return admin
            .queryForObject(
                "SELECT " + field + " FROM payse.analysis_jobs WHERE user_id=? AND id=?",
                java.sql.Timestamp.class,
                owner,
                UUID.fromString(job)
            )
            .toInstant();
    }

    /**
     * 전역 대기 수 검사를 위해 폐기 DB에만 사용자별 두 작업을 관계 ID로 생성한다.
     * @created 2026-11-01
     * @usedBy enforcesGlobalQueueCapacityAcrossOwners
     */
    private List<UUID> seedWaitingUsers(int count) {
        assertEquals(
            "payse_auth_test_analysis",
            admin.queryForObject("SELECT current_database()", String.class)
        );
        List<UUID> jobs = new ArrayList<>();
        SecureRandom random = new SecureRandom();
        for (int index = 0; index < count; index++) {
            UUID user = UUID.randomUUID();
            String name = "Queue" + (char) ('A' + index);
            String phone = "010"
                + String.format(java.util.Locale.ROOT, "%08d", random.nextInt(100_000_000));
            assertEquals(
                1,
                admin.update(
                    "INSERT INTO payse.users (id,name,phone,code_verifier,data_version,created_at) VALUES (?,?,?,'DISABLED',1,clock_timestamp())",
                    user,
                    name,
                    phone
                )
            );
            for (int item = 0; item < 2; item++) {
                UUID job = UUID.randomUUID();
                String hash = "sha256:" + UUID.randomUUID()
                    .toString()
                    .replace("-", "")
                    + UUID.randomUUID()
                        .toString()
                        .replace("-", "");
                assertEquals(
                    1,
                    admin.update(
                        """
                    INSERT INTO payse.analysis_jobs
                      (id,user_id,semantic_kind,trigger_kind,descriptor_hash,accepted_at,guard_expires_at,
                       state,attempt_count,execution_expires_at,detail)
                    VALUES (?,?,'transactionMeaning','A',?,?,?,'queued',0,?,'{}'::jsonb)
                    """,
                        job,
                        user,
                        hash,
                        OffsetDateTime.ofInstant(clock.instant(), ZoneOffset.UTC),
                        clock.instant()
                            .atZone(ZoneId.of("Asia/Seoul"))
                            .plusMonths(3)
                            .toOffsetDateTime(),
                        OffsetDateTime.ofInstant(clock.instant().plusSeconds(180), ZoneOffset.UTC)
                    )
                );
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
        assertEquals(
            "payse_auth_test_analysis",
            admin.queryForObject("SELECT current_database()", String.class)
        );
        new TransactionTemplate(new DataSourceTransactionManager(adminPool))
            .executeWithoutResult(
                status -> {
                    for (String table : List.of(
                        "financial_accounts",
                        "financial_cards",
                        "financial_transactions",
                        "card_statements",
                        "statement_items"
                    )) {
                        admin.update(
                            "UPDATE payse." + table + " SET source_version=? WHERE user_id=?",
                            version,
                            owner
                        );
                    }

                    assertEquals(
                        1,
                        admin.update(
                            "UPDATE payse.source_contexts SET source_version=? WHERE user_id=?",
                            version,
                            owner
                        )
                    );
                    assertEquals(
                        1,
                        admin.update(
                            "UPDATE payse.users SET data_version=data_version+1 WHERE id=?",
                            owner
                        )
                    );
                }
            );
    }

    /**
     * 빈 결과·중복 결과를 임의 첫 행으로 선택하지 않고 준비 단계에서 실패시킨다.
     * @created 2026-11-01
     * @usedBy credentials, meaningInput, 기억 관계 검사
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private JsonNode unique(JsonNode rows, Predicate<JsonNode> predicate) {
        List<JsonNode> matches = new ArrayList<>();
        for (JsonNode row : rows) {
            if (predicate.test(row)) {
                matches.add(row);
            }
        }

        assertEquals(1, matches.size(), "Expected one fixture relation");
        return matches.getFirst();
    }

    /**
     * 분석 실행 전후 금융 원천·설정·관계·버전이 그대로인지 비교한다.
     * @created 2026-11-01
     * @usedBy start, stop
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
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
            "user_attributes",
            "institution_links",
            AnalysisFields.OBLIGATIONS,
            "reserves",
            "reserve_allocations",
            "write_receipts",
            "recurring_plans",
            "recurring_plan_revisions",
            "recurring_decisions"
        )) {
            result.put(
                table,
                admin.queryForObject(
                    "SELECT md5(coalesce(string_agg(value,E'\\n' ORDER BY value),'')) "
                        + "FROM (SELECT to_jsonb(record)::text value FROM payse." + table
                        + " record) rows",
                    String.class
                )
            );
        }

        result.put(
            AnalysisFields.VERSIONS,
            admin.queryForObject(
                "SELECT string_agg(id::text||':'||data_version::text,',' ORDER BY id) FROM payse.users",
                String.class
            )
        );
        return result;
    }

    /**
     * HTTP 사용자 작업마다 새 멱등 키를 만들고 테스트에 고정 식별자를 넣지 않는다.
     * @created 2026-11-01
     * @usedBy HTTP 검사
     */
    private String key() {
        return UUID.randomUUID().toString();
    }

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
        ControlledModel controlledModel() {
            return new ControlledModel();
        }

        /**
         * 운영 시계를 바꾸지 않고 각 Spring 검사 인스턴스의 분석 시간 경계만 이동한다.
         * @created 2026-11-01
         * @usedBy Spring 테스트 구성
         */
        @Bean
        @Primary
        TestClock analysisTestClock() {
            return new TestClock();
        }

        /**
         * 운영 KMS를 호출하지 않고 키 감싸기 실패를 독립 제어하는 검사 빈을 만든다.
         * @created 2026-11-01
         * @usedBy Spring 테스트 구성
         */
        @Bean
        TestKeys analysisTestKeys() {
            return new TestKeys();
        }

        /**
         * 실제 공유 AI 검증·실제 봉투 암호화를 모의 공급자와 연결한다.
         * @created 2026-11-01
         * @usedBy Spring 테스트 구성
         * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
         */
        @Bean
        @Primary
        AnalysisRuntime analysisTestRuntime(ControlledModel model, TestKeys keys) {
            ObjectNode versions = JsonMapper.builder()
                .build()
                .createObjectNode()
                .put(AnalysisFields.MODEL, "mock-provider-1")
                .put(AnalysisFields.PROMPT, "test-prompt-1")
                .put(AnalysisFields.RESPONSE, AnalysisCodes.ANALYSIS_CONTRACT)
                .put(AnalysisFields.POLICY, AnalysisCodes.MEANING_POLICY);
            return new AnalysisRuntime(
                new AnalysisService(model, 6000),
                new EnvelopeCipher(keys),
                versions
            );
        }
    }

    /**
     * 실제 지침·별칭 입력을 받는 네트워크 없는 공급자다. 호출 수·실패·늦은 응답을 제어한다.
     * @created 2026-11-01
     * @usedBy RuntimeConfig
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
        void block() {
            entered = new CountDownLatch(1);
            release = new CountDownLatch(1);
            returned = new CountDownLatch(1);
        }

        /**
         * 모델별 요청 스키마를 실제로 받되 테스트 밖 전송 기능은 만들지 않는다.
         * @created 2026-11-01
         * @usedBy AnalysisService
         * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
         */
        @Override
        public ModelGateway create(String instructions, ObjectNode schema) {
            assertTrue(schema.path(AnalysisFields.PROPERTIES).has(AnalysisFields.MEMORIES));
            return new ModelGateway() {
                /**
                 * 테스트 한도를 위한 관측값이며 실제 공급자 토큰 측정값이 아니다.
                 * @created 2026-11-01
                 * @usedBy AnalysisService
                 */
                @Override
                public long countInput(JsonNode input) {
                    return 100;
                }

                /**
                 * 실제 공유 검증기로 검사할 완결 응답 또는 명시 실패를 한 번 생성한다.
                 * @created 2026-11-01
                 * @usedBy AnalysisService
                 * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
                 * @modified 2026-11-02 - 원천 갱신과 응답의 순서를 명시 gate로 동기화
                 * @modified 2026-11-02 - 기억 검사의 판단 유보·일부 응답 근거 제어를 추가하고 명시 대기 유지
                 */
                @Override
                public ModelReply generate(JsonNode input) {
                    calls.incrementAndGet();
                    entered.countDown();
                    try {
                        // 테스트 준비 완료 신호로만 응답한다. 실패 시 stop()도 이 gate를 해제한다.
                        release.await();
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        throw new IllegalStateException("Test response interrupted");
                    }

                    if (failure.equals("unknown")) {
                        throw new ModelFailure(
                            AnalysisCodes.TRANSMISSION_UNKNOWN,
                            ModelFailure.Stage.GENERATION,
                            true
                        );
                    }
                    if (failure.equals("invalid")) {
                        return new ModelReply(
                            null,
                            new TokenUsage(100, null, 10),
                            AnalysisCodes.INCOMPLETE_RESPONSE
                        );
                    }

                    var json = JsonMapper.builder().build();
                    ObjectNode response = json.createObjectNode();
                    ObjectNode output = response.putObject(AnalysisFields.OUTPUT)
                        .put(AnalysisFields.MEANING_POLICY_VERSION, AnalysisCodes.MEANING_POLICY);
                    ArrayNode rows = output.putArray(AnalysisFields.ITEMS),
                        memories = response.putArray(AnalysisFields.MEMORIES);
                    for (JsonNode requested : input.path(AnalysisFields.ITEMS)) {
                        String item = requested.path(AnalysisFields.ITEM_KEY).asString();
                        ObjectNode row = rows.addObject()
                            .put(AnalysisFields.ITEM_KEY, item)
                            .put(AnalysisFields.REASON, RESULT_TEXT);
                        if (minimalEvidence) {
                            row.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
                                .add(
                                    requested.path(AnalysisFields.TARGET_TRANSACTION_ID).asString()
                                );
                        } else {
                            row.set(
                                AnalysisFields.EVIDENCE_TRANSACTION_IDS,
                                requested.path(AnalysisFields.EVIDENCE_TRANSACTION_IDS).deepCopy()
                            );
                        }
                        row.putObject(AnalysisFields.MEANING)
                            .put(AnalysisFields.STATUS, "unknown")
                            .putNull(AnalysisFields.VALUE)
                            .put(AnalysisFields.REASON_CODE, "insufficient_evidence");
                        if (unknownClassification) {
                            row.putObject(AnalysisFields.CLASSIFICATION)
                                .put(AnalysisFields.STATUS, "unknown")
                                .putNull(AnalysisFields.VALUE)
                                .put(AnalysisFields.REASON_CODE, "insufficient_evidence");
                        } else {
                            row.putObject(AnalysisFields.CLASSIFICATION)
                                .put(AnalysisFields.STATUS, "candidate")
                                .put(AnalysisFields.VALUE, "income")
                                .put(AnalysisFields.REASON_CODE, "supported");
                        }
                        memories.addObject()
                            .put(AnalysisFields.ITEM_KEY, item)
                            .put(AnalysisFields.ACTIVE, true)
                            .put(AnalysisFields.IS_REFERENCE, true)
                            .put(AnalysisFields.IMPORTANT, important)
                            .put(AnalysisFields.REFERENCE_POLICY, "optional")
                            .put(AnalysisFields.REASON, RESULT_TEXT);
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
        private final AtomicReference<Instant> now = new AtomicReference<>(
            Instant.now().truncatedTo(ChronoUnit.MILLIS)
        );

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
        public ZoneId getZone() {
            return ZoneOffset.UTC;
        }

        /**
         * 별도 시간대를 요청해도 같은 검사 순간을 제공한다.
         * @created 2026-11-01
         * @usedBy Clock 호출부
         */
        @Override
        public Clock withZone(ZoneId zone) {
            return Clock.fixed(instant(), zone);
        }

        /**
         * worker와 HTTP 스레드가 같은 원자 시각을 관찰한다.
         * @created 2026-11-01
         * @usedBy AnalysisJobs, AnalysisResults
         */
        @Override
        public Instant instant() {
            return now.get();
        }
    }

    /**
     * 키만 테스트 메모리에 보관하며 사용자·기억 문맥을 확인하는 KMS 대역이다.
     * @created 2026-11-01
     * @usedBy RuntimeConfig
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
        void blockUnwrap() {
            unwrapEntered = new CountDownLatch(1);
            unwrapRelease = new CountDownLatch(1);
        }

        /**
         * 독립 데이터 키를 불투명 핸들로 감싸고 입력 배열은 보관하지 않는다.
         * @created 2026-11-01
         * @usedBy EnvelopeCipher
         * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
         */
        @Override
        public WrappedKey wrap(byte[] key, byte[] context) {
            if (failWrap) {
                throw new IllegalStateException("Test KMS wrapping failure");
            }

            String id = UUID.randomUUID().toString();
            keys.put(id, key.clone());
            contexts.put(id, context.clone());
            return new WrappedKey("test-only", id.getBytes(StandardCharsets.US_ASCII));
        }

        /**
         * 현재 사용자·기억 문맥이 같은 키만 독립 배열로 반환한다.
         * @created 2026-11-01
         * @usedBy EnvelopeCipher
         * @modified 2026-11-02 - 호출 수·제어 대기를 추가하되 사용자·기억 AAD 검증 유지
         */
        @Override
        public byte[] unwrap(WrappedKey wrapped, byte[] context) {
            unwrapCalls.incrementAndGet();
            unwrapEntered.countDown();
            try {
                if (!unwrapRelease.await(15, TimeUnit.SECONDS)) {
                    throw new IllegalStateException("Test unwrap was not released");
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IllegalStateException("Test unwrap interrupted");
            }

            String id = new String(wrapped.ciphertext(), StandardCharsets.US_ASCII);
            if (!"test-only".equals(wrapped.keyRef()) || !Arrays.equals(contexts.get(id), context)
                || !keys.containsKey(id)) {
                throw new IllegalStateException("Unknown test key context");
            }

            return keys.get(id).clone();
        }
    }
}
