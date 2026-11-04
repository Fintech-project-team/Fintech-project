package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisFields;
import com.payse.api.ApiTestConstants.GammaLocal;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.CompactModel;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.config.LlmSettings;
import com.payse.ai.transport.ProviderHttp;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.mapper.FinancialRepository;
import java.net.http.HttpClient;
import java.nio.file.Path;
import java.time.Duration;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;
import tools.jackson.databind.node.ObjectNode;
import tools.jackson.databind.JsonNode;

/**
 * 명시적으로 선택하는 감마 시험 구성이다. 사용자 판정은 인증 DB, 원천 판정은 현재 DB로 한다.
 * @created 2026-11-03
 * @usedBy GammaLocalServer.main, GammaLiveTest
 */
@TestConfiguration(proxyBeanMethods = false)
public class GammaLocalConfig {
    /**
     * 명시 감마 평가에만 1..6개 작업을 허용한다. 일반 구성은 기존 용량을 유지한다.
     * @created 2026-11-04
     * @usedBy gammaCapacity, GammaLiveTest
     */
    static int parallelism() {
        String value = System.getenv(GammaLocal.ENV_PARALLEL);
        if (value == null) {
            return 1;
        }
        if (!GammaLocal.APPROVED.equals(System.getenv(GammaLocal.ENV_EVALUATION))
            || !value.matches("[1-6]")) {
            throw new IllegalStateException(GammaLocal.INCOMPLETE);
        }
        return Integer.parseInt(value);
    }

    /**
     * 감마 전용 인증 가드가 있는 시험 구성에서만 용량을 바꾼다.
     * @created 2026-11-04
     * @usedBy AnalysisJobs 생성자
     */
    @Bean
    @Primary
    AnalysisCapacity gammaCapacity() {
        int parallel = parallelism();
        return new AnalysisCapacity(Math.max(2, parallel), 20, parallel, Math.max(2, parallel));
    }

    /**
     * 저장소의 감마 초기 사례 한 건만 선택한다. 표시명이나 클라이언트 userId를 사용하지 않는다.
     * @created 2026-11-03
     * @usedBy gammaKeys, gammaGuard
     */
    static UUID owner() {
        try {
            var seeds = AnalysisJson.JSON.readTree(
                Path.of(GammaLocal.SEEDS).toFile()
            );
            UUID selected = null;
            for (var user : seeds.path(AnalysisFields.USERS)) {
                if (user.path(GammaLocal.INITIAL_CASE).asString().equals(GammaLocal.GAMMA_CASE)) {
                    if (selected != null) {
                        throw new IllegalStateException();
                    }
                    selected = UUID.fromString(user.path(AnalysisFields.USER_ID).asString());
                }
            }
            if (selected == null) {
                throw new IllegalStateException();
            }
            return selected;
        } catch (Exception failure) {
            throw new IllegalStateException(GammaLocal.IDENTITY_UNAVAILABLE);
        }
    }

    /**
     * 승인된 별도 키 파일만 읽고 시험 구성의 명시 활성화를 요구한다.
     * @created 2026-11-03
     * @usedBy Spring 시험 구성
     */
    @Bean(destroyMethod = "close")
    GammaLocalKeys gammaKeys(
        @Value("${payse.gamma-local.enabled:false}") boolean enabled,
        @Value("${payse.gamma-local.key-file:}") String file
    ) {
        if (!enabled || file.isBlank()) {
            throw new IllegalStateException(GammaLocal.DISABLED);
        }
        return new GammaLocalKeys(Path.of(file), owner());
    }

    /**
     * 로컬 키 작업은 외부 비용이 없고 모델 호출에는 기존 DB 비용 장부를 그대로 적용한다.
     * @created 2026-11-03
     * @usedBy Spring 시험 구성
     * @modified 2026-11-03 - 승인된 연간 평가에만 별도 토큰 상한을 적용
     * @modified 2026-11-04 - 프롬프트 지문 및 독립 재검토·추론 설정의 별도 버전 반영
     * @modified 2026-11-04 - Fast 비교의 보수 단가와 별도 캐시 버전 확인
     * @modified 2026-11-04 - 명시적 출력 압축 비교와 별도 버전 연결
     */
    @Bean
    @Primary
    AnalysisRuntime gammaRuntime(
        GammaLocalKeys keys,
        AnalysisCosts costs,
        @Value("${payse.gamma-local.llm-file:}") String file,
        @Value("${payse.gamma-local.project:}") String project,
        @Value("${payse.gamma-local.pricing:}") String version,
        @Value("${payse.gamma-local.review-file:}") String reviewFile
    ) {
        if (file.isBlank() || !Path.of(file).isAbsolute()
            || project.isBlank() || version.isBlank()) {
            throw new IllegalStateException(GammaLocal.INCOMPLETE);
        }
        LlmSettings llm = LlmSettings.read(Path.of(file));
        ObjectNode rates = costs.policy(project, version);
        AnalysisPricing pricing = new AnalysisPricing(rates, llm.model());
        boolean evaluation = GammaLocal.APPROVED.equals(System.getenv(GammaLocal.ENV_EVALUATION));
        int inputLimit = evaluation ? 12000 : 6000;
        int outputLimit = evaluation ? 4000 : 1200;
        if (!llm.enabled() || pricing.kmsMicros() != 0
            || pricing.inputLimit() > inputLimit || pricing.outputLimit() > outputLimit) {
            throw new IllegalStateException(GammaLocal.INVALID_POLICY);
        }
        HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();
        ProviderHttp http = new ProviderHttp(client, Duration.ofSeconds(20), 1048576);
        String review = reviewer(reviewFile);
        boolean fast = GammaLocal.APPROVED.equals(System.getenv(GammaLocal.ENV_FAST));
        if (fast && (rates.path("inputMicrosPerMillion").asLong() < 1_500_000_000L
            || rates.path("cachedMicrosPerMillion").asLong() < 1_500_000_000L
            || rates.path("outputMicrosPerMillion").asLong() < 3_000_000_000L)) {
            throw new IllegalStateException(GammaLocal.INVALID_POLICY);
        }
        boolean compact = GammaLocal.APPROVED.equals(System.getenv(GammaLocal.ENV_COMPACT));
        var factory = llm.factory(
            http,
            pricing.inputLimit(),
            pricing.outputLimit(),
            fast ? GammaLocal.SERVICE_FAST : GammaLocal.SERVICE_DEFAULT,
            compact ? GammaLocal.VERBOSITY_LOW : null
        );
        ModelFactory observed = (instructions, schema) ->
            new ObservedModel(factory.create(instructions + review, schema));
        ModelFactory models = compact ? CompactModel.factory(observed) : observed;
        var analysis = new AnalysisService(models, pricing.inputLimit());
        ObjectNode versions = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.MODEL, llm.model())
            .put(AnalysisFields.PROMPT, comparisonVersion(analysis.promptVersion(),
                fast ? llm.reasoningEffort() + "/fast" : llm.reasoningEffort(),
                compact ? review + CompactModel.version() : review))
            .put(AnalysisFields.RESPONSE, GammaLocal.VERSION)
            .put(AnalysisFields.POLICY, version);
        var execution = new AnalysisRuntime.Execution(models, costs, pricing, project, version);
        return new AnalysisRuntime(
            analysis,
            new EnvelopeCipher(keys),
            versions,
            execution
        );
    }

    /**
     * 별도 비교 실행에서만 도구 없는 1회 재검토·짧은 응답 지시를 읽는다.
     * @created 2026-11-04
     * @usedBy gammaRuntime
     * @modified 2026-11-04 - 상시 분석의 짧은 응답 지시 형식을 비교에 허용
     */
    private static String reviewer(String path) {
        if (path.isBlank()) {
            return "";
        }
        try {
            Path file = Path.of(path);
            if (!file.isAbsolute() || java.nio.file.Files.size(file) > 8192) {
                throw new IllegalArgumentException();
            }
            var review = AnalysisJson.JSON.readTree(file.toFile());
            if (!java.util.Set.of("payse-bounded-reviewer-v1", "payse-bounded-guidance-v1")
                .contains(review.path("format").asString())
                || review.path("maximumCallsPerBatch").asInt() != 1
                || !review.path("instructions").isString()) {
                throw new IllegalArgumentException();
            }
            return "\n" + review.path("instructions").asString();
        } catch (Exception failure) {
            throw new IllegalStateException(GammaLocal.INCOMPLETE);
        }
    }

    /**
     * 추론 설정·추가 지시가 다른 비교 결과를 같은 캐시 버전으로 저장하지 않는다.
     * @created 2026-11-04
     * @usedBy gammaRuntime
     */
    private static String comparisonVersion(String prompt, String effort, String review) {
        if ("none".equals(effort) && review.isEmpty()) {
            return prompt;
        }
        try {
            byte[] bytes = (prompt + "\n" + effort + review).getBytes(java.nio.charset.StandardCharsets.UTF_8);
            return "PAYSE-AGENT-1:" + java.util.HexFormat.of().formatHex(
                java.security.MessageDigest.getInstance("SHA-256").digest(bytes));
        } catch (Exception failure) {
            throw new IllegalStateException(GammaLocal.INCOMPLETE);
        }
    }

    /**
     * 시험 실패 원인을 본문 없이 계수·고정 오류 코드로만 남긴다.
     * @created 2026-11-03
     * @usedBy gammaRuntime
     */
    private record ObservedModel(ModelGateway delegate) implements ModelGateway {
        /**
         * 새 호출 없이 실제 계수 결과와 제한된 오류 코드만 기록한다.
         * @created 2026-11-03
         * @usedBy AnalysisService
         */
        @Override
        public long countInput(JsonNode input) {
            var log = org.slf4j.LoggerFactory.getLogger(GammaLocalConfig.class);
            try {
                long count = delegate.countInput(input);
                log.info(GammaLocal.COUNT_TOKENS, count);
                return count;
            } catch (ModelFailure failure) {
                String code = failure.getMessage();
                if (code != null && code.matches("[A-Z0-9_:-]{1,80}")) {
                    log.warn(GammaLocal.COUNT_FAILURE, code);
                }
                throw failure;
            }
        }

        /**
         * 생성 본문은 관찰하거나 복사하지 않고 기존 모델로 한 번만 전달한다.
         * @created 2026-11-03
         * @usedBy AnalysisService
         */
        @Override
        public ModelReply generate(JsonNode input) {
            return delegate.generate(input);
        }
    }

    /**
     * 분석 controller 진입 전에 감마 인증과 현재 연간 시험 원천을 확인한다.
     * @created 2026-11-03
     * @usedBy Spring MVC
     * @modified 2026-11-03 - 명시적 난도 확장 시험 원천 버전도 대조
     * @modified 2026-11-04 - 동결 원천 버전 허용 및 실제 배포와 인증/원천 가드 공유
     */
    @Bean
    WebMvcConfigurer gammaGuard(
        AuthTransactions transactions,
        AuthRepository auth,
        AuthCrypto crypto,
        FinancialRepository finances,
        @Value("${payse.gamma-local.source-version:}") String sourceVersion
    ) {
        boolean original = sourceVersion.matches("fixture:gamma-(year|challenge):1:[0-9-]+:[0-9]+");
        boolean fresh = sourceVersion.matches("fixture:gamma-fresh:(development|holdout):[0-9]+");
        if (!original && !fresh) {
            throw new IllegalStateException(GammaLocal.MISSING_SOURCE);
        }
        var guard = new GammaDeployment.Guard(
            transactions, auth, crypto, finances, owner(), sourceVersion);
        return new WebMvcConfigurer() {
            /**
             * 모든 분석 controller를 경로 별칭과 무관하게 보호한다.
             * @created 2026-11-03
             * @usedBy Spring MVC
             */
            @Override
            public void addInterceptors(InterceptorRegistry registry) {
                registry.addInterceptor(guard);
            }
        };
    }

}
