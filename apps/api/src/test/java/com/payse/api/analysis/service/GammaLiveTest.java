package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.ApiTestConstants.AnalysisConfig;
import com.payse.api.ApiTestConstants.AnalysisFields;
import com.payse.api.ApiTestConstants.AnalysisHttp;
import com.payse.api.ApiTestConstants.AnalysisPaths;
import com.payse.api.ApiTestConstants.GammaLocal;
import com.payse.api.PayseApiApplication;
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
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.jdbc.core.JdbcTemplate;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 명시 승인한 실행기에서만 실제 OpenAI·폐기 DB·HTTP·로컬 키 저장을 검증한다.
 * @created 2026-11-03
 * @usedBy Gradle gammaLiveTest, gamma_local.py
 */
class GammaLiveTest {
    private ConfigurableApplicationContext context;
    private JdbcTemplate admin;
    private final Map<String, Object> properties = new HashMap<>();
    private final HttpClient client = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .build();
    private String base;
    private String token;
    private final ObjectNode summary = AnalysisJson.JSON.createObjectNode();

    /**
     * 연간 감마 자료의 세 해석을 실제 실행하고 재시작·재조회에서 추가 모델 호출이 없음을 확인한다.
     * @created 2026-11-03
     * @usedBy 명시 승인된 JUnit 실행
     */
    @Test
    void verifiesLiveAnalysisAndEncryptedRecovery() throws Exception {
        assertEquals(GammaLocal.APPROVED, setting(GammaLocal.ENV_LIVE));
        String jdbc = setting(GammaLocal.ENV_JDBC_URL);
        assertTrue(jdbc.matches(
            "jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_gamma_local"
        ));
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(setting(GammaLocal.ENV_JDBC_URL));
        config.setUsername(setting(GammaLocal.ENV_ADMIN_USER));
        config.setPassword(setting(GammaLocal.ENV_ADMIN_PASSWORD));
        config.setMaximumPoolSize(2);
        try (var pool = new HikariDataSource(config)) {
            admin = new JdbcTemplate(pool);
            assertEquals(
                GammaLocal.DATABASE,
                admin.queryForObject("SELECT current_database()", String.class)
            );
            configure();
            launch();
            UUID gamma = GammaLocalConfig.owner();
            token = login(gamma);
            var source = source(token);
            assertEquals(1825, source.path(AnalysisFields.TRANSACTIONS).size());
            assertEquals(9, source.path(AnalysisFields.ACCOUNTS).size());
            Map<String, String> before = fingerprint();
            summary.put(
                GammaLocal.SOURCE_TRANSACTIONS,
                source.path(AnalysisFields.TRANSACTIONS).size()
            );
            summary.put(GammaLocal.SOURCE_ACCOUNTS, source.path(AnalysisFields.ACCOUNTS).size());

            JsonNode seeds = AnalysisJson.JSON.readTree(Path.of(GammaLocal.SEEDS).toFile());
            for (JsonNode account : seeds.path(AnalysisFields.USERS)) {
                UUID other = UUID.fromString(account.path(AnalysisFields.USER_ID).asString());
                if (!other.equals(gamma)) {
                    String otherToken = login(other);
                    send(
                        AnalysisHttp.POST,
                        AnalysisPaths.ANALYSIS_JOBS_PATH,
                        AnalysisJson.JSON.createObjectNode(),
                        otherToken,
                        403
                    );
                    send(AnalysisHttp.GET, AnalysisPaths.SNAPSHOT_PATH, null, otherToken, 200);
                }
            }
            send(
                AnalysisHttp.POST,
                AnalysisPaths.ANALYSIS_JOBS_PATH,
                AnalysisJson.JSON.createObjectNode(),
                null,
                401
            );
            assertEquals(0, calls());
            summary.put(GammaLocal.OTHERS_BLOCKED, true);

            Path inputFile = Path.of(setting(GammaLocal.ENV_INPUTS));
            JsonNode cases = AnalysisJson.JSON.readTree(inputFile.toFile());
            var outcomes = summary.putArray(GammaLocal.CASES);
            List<ObjectNode> requests = new ArrayList<>();
            List<String> resultIds = new ArrayList<>();
            for (JsonNode testCase : cases) {
                ObjectNode input = ((ObjectNode) testCase.path(AnalysisFields.INPUT)).deepCopy();
                ObjectNode inputContext = (ObjectNode) input.path(AnalysisFields.CONTEXT);
                var versionFields = List.of(
                    AnalysisFields.DATA_VERSION,
                    AnalysisFields.SOURCE_VERSION,
                    AnalysisFields.AS_OF,
                    AnalysisFields.RULE_VERSION
                );
                for (String field : versionFields) {
                    inputContext.set(field, source.get(field));
                }
                String name = testCase.path(AnalysisFields.NAME).asString();
                ObjectNode outcome = outcomes.addObject().put(AnalysisFields.NAME, name);
                String job = submit(input);
                ObjectNode status = await(job, GammaLocal.SUCCEEDED);
                outcome.put(AnalysisFields.STATE, status.path(AnalysisFields.STATE).asString());
                if (!status.path(AnalysisFields.STATE).asString().equals(GammaLocal.SUCCEEDED)) {
                    outcome.set(AnalysisFields.ERROR, status.path(AnalysisFields.ERROR).deepCopy());
                }
                assertEquals(
                    GammaLocal.SUCCEEDED,
                    status.path(AnalysisFields.STATE).asString(),
                    GammaLocal.ANALYSIS_FAILED
                );
                String result = status.path(AnalysisFields.RESULT_ID).asString();
                assertFalse(result.isBlank());
                ObjectNode retrieved = query(input, result);
                outcome.set(
                    AnalysisFields.RESULT_AVAILABILITY,
                    retrieved.path(AnalysisFields.RESULT_AVAILABILITY)
                );
                assertEquals(
                    GammaLocal.AVAILABLE,
                    retrieved.path(AnalysisFields.RESULT_AVAILABILITY).asString()
                );
                assertEquals(result, retrieved.path(AnalysisFields.RESULT_ID).asString());
                outcome.put(GammaLocal.STORED_AND_RETRIEVED, true);
                outcome.set(GammaLocal.MEANING_CODES, meaningCodes(retrieved));
                requests.add(input);
                resultIds.add(result);
                Files.writeString(
                    Path.of(setting(GammaLocal.ENV_REPORT)),
                    summary.toPrettyString()
                );
            }
            long modelCalls = admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_cost_calls WHERE category='model' "
                    + "AND dispatched_at IS NOT NULL",
                Long.class
            );
            assertEquals(3L, modelCalls);
            long kmsCalls = admin.queryForObject(
                "SELECT count(*) FROM payse.analysis_cost_calls WHERE category='kms'",
                Long.class
            );
            assertEquals(0L, kmsCalls);
            long beforeRestart = calls();
            context.close();
            context = null;
            launch();
            for (int index = 0; index < requests.size(); index++) {
                ObjectNode restored = query(requests.get(index), resultIds.get(index));
                assertEquals(
                    GammaLocal.AVAILABLE,
                    restored.path(AnalysisFields.RESULT_AVAILABILITY).asString()
                );
                assertEquals(
                    resultIds.get(index),
                    restored.path(AnalysisFields.RESULT_ID).asString()
                );
            }
            assertEquals(beforeRestart, calls());
            assertEquals(before, fingerprint());
            summary.put(GammaLocal.RESTART_RECOVERY, true);
            summary.put(GammaLocal.SOURCES_PRESERVED, true);
            summary.put(GammaLocal.KMS_CALLS, 0);
            summary.put(GammaLocal.PASSED, true);
        } finally {
            if (context != null) {
                context.close();
            }
            Files.writeString(Path.of(setting(GammaLocal.ENV_REPORT)), summary.toPrettyString());
        }
    }

    /**
     * DB 자격은 하위 프로세스 환경에서만 읽고 테스트 인증 키는 메모리에 생성한다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private void configure() {
        properties.put(AnalysisConfig.SERVER_PORT, "0");
        properties.put(AnalysisConfig.SERVER_ADDRESS, GammaLocal.LOOPBACK);
        properties.put(AnalysisConfig.BANNER_MODE, GammaLocal.BANNER_OFF);
        properties.put(AnalysisConfig.PAYSE_AUTH_PEER_MODE, GammaLocal.PEER_DIRECT);
        properties.put(AnalysisConfig.PAYSE_JDBC_URL, setting(GammaLocal.ENV_JDBC_URL));
        properties.put(AnalysisConfig.PAYSE_DB_USER, setting(GammaLocal.ENV_DB_USER));
        properties.put(AnalysisConfig.PAYSE_DB_PASSWORD, setting(GammaLocal.ENV_DB_PASSWORD));
        properties.put(AnalysisConfig.PAYSE_DB_MAX_POOL_SIZE, "5");
        properties.put(AnalysisConfig.PAYSE_DB_CONNECTION_TIMEOUT_MS, "5000");
        properties.put(AnalysisConfig.PAYSE_DB_VALIDATION_TIMEOUT_MS, "1000");
        properties.put(AnalysisConfig.PAYSE_AUTH_CODE_KEY_ID, GammaLocal.AUTH_KEY_ID);
        var secretProperties = List.of(
            AnalysisConfig.PAYSE_AUTH_CODE_KEY_BASE64,
            AnalysisConfig.PAYSE_AUTH_LIMIT_KEY_BASE64,
            AnalysisConfig.PAYSE_FINANCE_CURSOR_KEY_BASE64
        );
        for (String name : secretProperties) {
            byte[] secret = new byte[32];
            new SecureRandom().nextBytes(secret);
            properties.put(name, Base64.getEncoder().encodeToString(secret));
            java.util.Arrays.fill(secret, (byte) 0);
        }
        properties.put(GammaLocal.ENABLED_PROPERTY, GammaLocal.ENABLED);
        var localProperties = Map.of(
            GammaLocal.KEY_FILE_PROPERTY,
            GammaLocal.ENV_KEY_FILE,
            GammaLocal.LLM_FILE_PROPERTY,
            GammaLocal.ENV_LLM_FILE,
            GammaLocal.PROJECT_PROPERTY,
            GammaLocal.ENV_PROJECT,
            GammaLocal.PRICING_PROPERTY,
            GammaLocal.ENV_PRICING,
            GammaLocal.SOURCE_PROPERTY,
            GammaLocal.ENV_SOURCE_VERSION
        );
        for (var entry : localProperties.entrySet()) {
            properties.put(GammaLocal.PREFIX + entry.getKey(), setting(entry.getValue()));
        }
    }

    /**
     * 기존 서버와 별개인 임의 loopback 포트의 API를 시작한다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private void launch() {
        SpringApplication application = new SpringApplication(
            PayseApiApplication.class,
            GammaLocalConfig.class
        );
        application.setAdditionalProfiles(
            GammaLocal.PROFILE_DATABASE,
            GammaLocal.PROFILE_AUTH,
            GammaLocal.PROFILE_FINANCE,
            GammaLocal.PROFILE_ANALYSIS
        );
        application.setDefaultProperties(properties);
        context = application.run();
        base = GammaLocal.HTTP_LOOPBACK
            + ((WebServerApplicationContext) context).getWebServer().getPort();
    }

    /**
     * 검증된 합성 사용자에게만 임시 인증 코드를 부여하고 실제 API로 로그인한다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private String login(UUID owner) throws Exception {
        var users = AnalysisJson.JSON
            .readTree(Path.of(GammaLocal.SEEDS).toFile())
            .path(AnalysisFields.USERS);
        JsonNode selected = null;
        for (var user : users) {
            if (owner.toString().equals(user.path(AnalysisFields.USER_ID).asString())) {
                assertTrue(selected == null);
                selected = user;
            }
        }
        assertTrue(selected != null);
        String code = String.format(
            java.util.Locale.ROOT,
            "%06d",
            new SecureRandom().nextInt(1_000_000)
        );
        int updated = admin.update(
            "UPDATE payse.users SET code_verifier=? WHERE id=?",
            context.getBean(AuthCrypto.class).codeVerifier(owner, code),
            owner
        );
        assertEquals(1, updated);
        ObjectNode body = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.NAME, selected.path(AnalysisFields.NAME).asString())
            .put(AnalysisFields.PHONE, selected.path(AnalysisFields.PHONE).asString())
            .put(AnalysisFields.CODE, code);
        return send(AnalysisHttp.POST, AnalysisPaths.SESSIONS_PATH, body, null, 201)
            .path(AnalysisFields.ACCESS_TOKEN)
            .asString();
    }

    /**
     * 인증된 동일 DB 연결의 원천을 사용하며 합성 verified 표식을 신뢰하지 않는다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private ObjectNode source(String bearer) {
        return context.getBean(AuthTransactions.class).run(() -> {
            String digest = context.getBean(AuthCrypto.class).tokenDigest(bearer);
            var session = context.getBean(AuthRepository.class)
                .authorize(digest)
                .orElseThrow();
            return context.getBean(FinancialRepository.class).load(session.userId());
        });
    }

    /**
     * 실제 descriptor→허용→입력 제출 순서를 한 번 실행하고 자동 재시도하지 않는다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private String submit(ObjectNode input) throws Exception {
        String kind = input.path(AnalysisFields.SEMANTIC_TASK_KIND).asString();
        ObjectNode descriptor = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.TRIGGER_KIND, GammaLocal.TRIGGER_NORMAL)
            .put(AnalysisFields.SEMANTIC_TASK_KIND, kind)
            .put(AnalysisFields.INPUT_HASH_HINT, new AnalysisIdentity().hint(input))
            .put(AnalysisFields.IDEMPOTENCY_KEY, UUID.randomUUID().toString());
        descriptor.set(AnalysisFields.CONTEXT, input.path(AnalysisFields.CONTEXT));
        descriptor.putArray(AnalysisFields.REASON_CODES);
        var items = descriptor.putArray(AnalysisFields.ITEMS);
        for (var item : input.path(AnalysisFields.ITEMS)) {
            String itemKey = item.path(AnalysisFields.ITEM_KEY).asString();
            var target = items.addObject().put(AnalysisFields.ITEM_KEY, itemKey);
            target.set(
                AnalysisFields.EVIDENCE_TRANSACTION_IDS,
                item.path(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
            );
            var candidates = target.putArray(AnalysisFields.CANDIDATE_IDS);
            if (item.path(AnalysisFields.CANDIDATE_KEY).isString()) {
                candidates.add(item.path(AnalysisFields.CANDIDATE_KEY).asString());
            }
        }
        String job = send(
            AnalysisHttp.POST,
            AnalysisPaths.ANALYSIS_JOBS_PATH,
            descriptor,
            token,
            202
        ).path(AnalysisFields.JOB_ID).asString();
        ObjectNode permit = await(job, GammaLocal.AWAITING_INPUT);
        assertEquals(GammaLocal.SUBMIT_INPUT, permit.path(AnalysisFields.ACTION).asString());
        ObjectNode request = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.IDEMPOTENCY_KEY, UUID.randomUUID().toString())
            .put(AnalysisFields.PERMIT, permit.path(AnalysisFields.PERMIT).asString());
        request.set(AnalysisFields.CONTEXT, input.path(AnalysisFields.CONTEXT));
        request.set(AnalysisFields.INPUT, input);
        String path = AnalysisPaths.ANALYSIS_JOB_PATH + job + AnalysisPaths.INPUT_SUFFIX;
        send(AnalysisHttp.POST, path, request, token, 202);
        return job;
    }

    /**
     * 상태만 관찰하며 실패나 완료 불명일 때 새 공급자 요청을 만들지 않는다.
     * @created 2026-11-03
     * @usedBy submit, verifiesLiveAnalysisAndEncryptedRecovery
     */
    private ObjectNode await(String job, String expected) throws Exception {
        for (int iteration = 0; iteration < 85; iteration++) {
            ObjectNode state = send(
                AnalysisHttp.GET,
                AnalysisPaths.ANALYSIS_JOB_PATH + job,
                null,
                token,
                200
            );
            String actual = state.path(AnalysisFields.STATE).asString();
            if (actual.equals(expected) || actual.equals(GammaLocal.FAILED)
                || actual.equals(GammaLocal.UNKNOWN)
                || actual.equals(GammaLocal.EXPIRED) || actual.equals(GammaLocal.CANCELLED)) {
                return state;
            }
            Thread.sleep(1000);
        }
        throw new IllegalStateException(GammaLocal.STATE_TIMEOUT);
    }

    /**
     * 현재 입력으로 저장 결과를 복구하며 공급자 호출 여부는 별도 비용 행으로 대조한다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private ObjectNode query(ObjectNode input, String id) throws Exception {
        String kind = input.path(AnalysisFields.SEMANTIC_TASK_KIND).asString();
        ObjectNode query = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.SEMANTIC_TASK_KIND, kind)
            .put(AnalysisFields.RESULT_ID, id);
        query.set(AnalysisFields.CONTEXT, input.path(AnalysisFields.CONTEXT));
        query.set(AnalysisFields.INPUT, input);
        return send(AnalysisHttp.POST, AnalysisPaths.ANALYSIS_QUERY_PATH, query, token, 200);
    }

    /**
     * 실제 loopback HTTP 요청만 전송하고 오류에도 본문·토큰을 테스트 출력에 넣지 않는다.
     * @created 2026-11-03
     * @usedBy login, submit, await, query
     */
    private ObjectNode send(String method, String path, JsonNode body, String bearer, int expected)
        throws Exception {
        var request = HttpRequest.newBuilder(URI.create(base + path))
            .timeout(Duration.ofSeconds(15))
            .header(AnalysisHttp.CONTENT_TYPE, GammaLocal.JSON_TYPE);
        if (bearer != null) {
            request.header(AnalysisHttp.AUTHORIZATION, AnalysisHttp.BEARER_PREFIX + bearer);
        }
        var publisher = body == null ? HttpRequest.BodyPublishers.noBody()
            : HttpRequest.BodyPublishers.ofString(body.toString());
        request.method(method, publisher);
        var response = client.send(request.build(), HttpResponse.BodyHandlers.ofString());
        summary.put(GammaLocal.LAST_HTTP_STATUS, response.statusCode());
        assertEquals(expected, response.statusCode(), GammaLocal.HTTP_MISMATCH);
        return (ObjectNode) AnalysisJson.JSON.readTree(response.body());
    }

    /**
     * 모델 본문 없이 전송을 시작한 비용 행 수만 센다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private long calls() {
        return admin.queryForObject(
            "SELECT count(*) FROM payse.analysis_cost_calls WHERE dispatched_at IS NOT NULL",
            Long.class
        );
    }

    /**
     * 분석 저장·인증 갱신과 별개인 모든 금융 원천과 설정의 동일성을 대조한다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private Map<String, String> fingerprint() {
        Map<String, String> result = new HashMap<>();
        var tables = admin.queryForList(
            "SELECT tablename FROM pg_tables WHERE schemaname='payse' "
                + "AND tablename NOT LIKE 'analysis_%' AND tablename NOT IN "
                + "('users','demo_sessions','auth_rate_limits') ORDER BY tablename",
            String.class
        );
        for (String table : tables) {
            assertTrue(table.matches("[a-z_]+"));
            String digest = admin.queryForObject(
                "SELECT md5(coalesce(string_agg(value,E'\\n' "
                    + "ORDER BY value),'')) FROM (SELECT to_jsonb(row)::text value FROM payse."
                    + table + " row) entries",
                String.class
            );
            result.put(table, digest);
        }
        String versions = admin.queryForObject(
            "SELECT md5(string_agg(id::text || ':' "
                + "|| data_version::text,',' ORDER BY id)) FROM payse.users",
            String.class
        );
        result.put(GammaLocal.USER_VERSIONS, versions);
        return result;
    }

    /**
     * 본문·거래 ID·이유를 저장하지 않고 제한된 분류 코드만 보고한다.
     * @created 2026-11-03
     * @usedBy verifiesLiveAnalysisAndEncryptedRecovery
     */
    private JsonNode meaningCodes(JsonNode node) {
        var codes = AnalysisJson.JSON.createArrayNode();
        var fields = List.of(
            AnalysisFields.PAYSE_TRANSACTION_TYPE,
            GammaLocal.EXPENSE_MEANING,
            AnalysisFields.STATUS
        );
        for (String field : fields) {
            for (JsonNode value : node.findValues(field)) {
                if (value.isString() && value.asString().matches("[a-z_]{1,40}")) {
                    codes.addObject()
                        .put(GammaLocal.FIELD, field)
                        .put(AnalysisFields.VALUE, value.asString());
                }
            }
        }
        return codes;
    }

    /**
     * 명시 실행기의 값만 읽고 누락을 다른 서버·자격으로 대체하지 않는다.
     * @created 2026-11-03
     * @usedBy GammaLiveTest
     */
    private static String setting(String name) {
        String value = System.getenv(GammaLocal.ENV_PREFIX + name);
        if (value == null || value.isBlank()) {
            throw new IllegalStateException(GammaLocal.MISSING_SETTING);
        }
        return value;
    }
}
