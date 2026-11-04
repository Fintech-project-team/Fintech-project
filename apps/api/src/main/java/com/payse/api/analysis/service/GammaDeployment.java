package com.payse.api.analysis.service;

import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.config.LlmSettings;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.transport.ProviderHttp;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.constants.ApiCodeConstants.Analysis;
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants.GammaLocal;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants.Readiness;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialRepository;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.net.http.HttpClient;
import java.nio.file.Path;
import java.time.Duration;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.context.annotation.Profile;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerInterceptor;
import org.springframework.web.servlet.config.annotation.InterceptorRegistry;
import org.springframework.web.servlet.config.annotation.WebMvcConfigurer;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 명시적으로 선택하는 감마 시험 구성이다. 사용자 판정은 인증 DB, 원천 판정은 현재 DB로 한다.
 * @created 2026-11-04
 * @usedBy Spring gamma-local 프로필
 */
@Configuration(proxyBeanMethods = false)
@Profile("database & auth & finance & analysis & gamma-local")
public class GammaDeployment {
    /**
     * 설치 도구로 만든 비공개 상태 폴더를 명시적으로 선택한다.
     * @created 2026-11-04
     * @usedBy deployedGammaCapacity, deployedGammaRuntime
     */
    @Bean(destroyMethod = "close")
    AnalysisReadiness gammaReadiness(
        @Value("${payse.gamma-local.state-directory:}") String directory
    ) {
        return new AnalysisReadiness(Path.of(directory));
    }

    /**
     * 번들 성능 프로필에 검증된 동시성만 적용한다.
     * @created 2026-11-04
     * @usedBy AnalysisJobs 생성자
     */
    @Bean
    @Primary
    AnalysisCapacity deployedGammaCapacity(AnalysisReadiness readiness) {
        int parallel = readiness.profile().path(Readiness.PARALLELISM).asInt();
        if (parallel < 1 || parallel > 6) {
            throw new IllegalStateException(ApiMessageConstants.GammaLocal.INCOMPLETE);
        }
        return new AnalysisCapacity(Math.max(2, parallel), 20, parallel, Math.max(2, parallel));
    }

    /**
     * 저장소의 감마 초기 사례 한 건만 선택한다. 표시명이나 클라이언트 userId를 사용하지 않는다.
     * @created 2026-11-04
     * @usedBy deployedGammaKeys, deployedGammaGuard
     */
    static UUID owner() {
        try (var resource = GammaDeployment.class.getResourceAsStream(GammaLocal.IDENTITY)) {
            String userId = AnalysisJson.JSON.readTree(resource).path(Readiness.USER_ID).asString();
            return UUID.fromString(userId);
        } catch (Exception failure) {
            throw new IllegalStateException(ApiMessageConstants.GammaLocal.IDENTITY_UNAVAILABLE);
        }
    }

    /**
     * 승인된 별도 키 파일만 읽고 시험 구성의 명시 활성화를 요구한다.
     * @created 2026-11-04
     * @usedBy Spring 시험 구성
     */
    @Bean(destroyMethod = "close")
    GammaLocalKeys deployedGammaKeys(
        @Value("${payse.gamma-local.enabled:false}") boolean enabled,
        @Value("${payse.gamma-local.key-file:}") String file
    ) {
        if (!enabled || file.isBlank()) {
            throw new IllegalStateException(ApiMessageConstants.GammaLocal.DISABLED);
        }
        return new GammaLocalKeys(Path.of(file), owner());
    }

    /**
     * 로컬 키 작업은 외부 비용이 없고 모델 호출에는 기존 DB 비용 장부를 그대로 적용한다.
     * @created 2026-11-04
     * @usedBy Spring 시험 구성
     */
    @Bean
    @Primary
    AnalysisRuntime deployedGammaRuntime(
        GammaLocalKeys keys,
        AnalysisReadiness readiness,
        AnalysisCosts costs,
        @Value("${payse.gamma-local.llm-file:}") String file,
        @Value("${payse.gamma-local.project:}") String project,
        @Value("${payse.gamma-local.pricing:}") String version,
        @Value("${payse.gamma-local.source-version:}") String sourceVersion,
        @Value("${payse.analysis.settings-file:}") String kmsSettings
    ) {
        if (!kmsSettings.isBlank() || !validSource(sourceVersion)
            || file.isBlank() || !Path.of(file).isAbsolute()
            || project.isBlank() || version.isBlank()) {
            throw new IllegalStateException(ApiMessageConstants.GammaLocal.INCOMPLETE);
        }
        LlmSettings llm = LlmSettings.read(Path.of(file));
        AnalysisPricing pricing = new AnalysisPricing(costs.policy(project, version), llm.model());
        ObjectNode profile = readiness.profile();
        if (!llm.enabled() || pricing.kmsMicros() != 0
            || !llm.model().equals(profile.path(Readiness.MODEL).asString())
            || !llm.reasoningEffort().equals(profile.path(Readiness.REASONING_EFFORT).asString())
            || pricing.inputLimit() != profile.path(Readiness.INPUT_LIMIT).asInt()
            || pricing.outputLimit() != profile.path(Readiness.OUTPUT_LIMIT).asInt()) {
            throw new IllegalStateException(ApiMessageConstants.GammaLocal.INVALID_POLICY);
        }
        HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();
        int timeoutSeconds = profile.path(Readiness.REQUEST_TIMEOUT_SECONDS).asInt();
        Duration timeout = Duration.ofSeconds(timeoutSeconds);
        ProviderHttp http = new ProviderHttp(client, timeout, 1048576);
        var factory = llm.factory(http, pricing.inputLimit(), pricing.outputLimit());
        ModelFactory models = (instructions, schema) ->
            new ObservedModel(factory.create(instructions, schema), readiness);
        var analysis = new AnalysisService(models, pricing.inputLimit());
        ObjectNode versions = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.MODEL, llm.model())
            .put(ApiFieldConstants.Analysis.PROMPT, analysis.promptVersion())
            .put(ApiFieldConstants.Analysis.RESPONSE, GammaLocal.VERSION)
            .put(ApiFieldConstants.Analysis.POLICY, version);
        var execution = new AnalysisRuntime.Execution(models, costs, pricing, project, version);
        String configuration = llm.configurationFingerprint() + keys.fingerprint()
            + project + ":" + version + sourceVersion;
        readiness.prepare(analysis.promptVersion(), configuration);
        return new AnalysisRuntime(
            analysis,
            new EnvelopeCipher(keys),
            versions,
            execution,
            readiness
        );
    }

    /**
     * 시험 실패 원인을 본문 없이 계수·고정 오류 코드로만 남긴다.
     * @created 2026-11-04
     * @usedBy deployedGammaRuntime
     */
    private record ObservedModel(
        ModelGateway delegate, AnalysisReadiness readiness
    ) implements ModelGateway {
        /**
         * 실제 계수 응답이 있었을 때만 공급자 연결 성공을 기록한다.
         * @created 2026-11-04
         * @usedBy AnalysisService
         */
        @Override
        public long countInput(JsonNode input) {
            try {
                long count = delegate.countInput(input);
                readiness.observe(ApiCodeConstants.Readiness.PROVIDER_SUCCESS);
                return count;
            } catch (RuntimeException failure) {
                readiness.observe(ApiCodeConstants.Readiness.PROVIDER_FAILURE);
                throw failure;
            }
        }

        /**
         * 유료 결과와 실패를 구분하며 진단을 위해 새 호출을 만들지 않는다.
         * @created 2026-11-04
         * @usedBy AnalysisService
         */
        @Override
        public ModelReply generate(JsonNode input) {
            try {
                ModelReply result = delegate.generate(input);
                String event = result.failure() == null
                    ? ApiCodeConstants.Readiness.PROVIDER_SUCCESS
                    : ApiCodeConstants.Readiness.PROVIDER_FAILURE;
                readiness.observe(event);
                return result;
            } catch (RuntimeException failure) {
                readiness.observe(ApiCodeConstants.Readiness.PROVIDER_FAILURE);
                throw failure;
            }
        }
    }

    /**
     * 분석 controller 진입 전에 감마 인증과 현재 연간 시험 원천을 확인한다.
     * @created 2026-11-04
     * @usedBy Spring MVC
     */
    @Bean
    WebMvcConfigurer deployedGammaGuard(
        AuthTransactions transactions,
        AuthRepository auth,
        AuthCrypto crypto,
        FinancialRepository finances,
        @Value("${payse.gamma-local.source-version:}") String sourceVersion
    ) {
        if (!validSource(sourceVersion)) {
            throw new IllegalStateException(ApiMessageConstants.GammaLocal.MISSING_SOURCE);
        }
        Guard guard = new Guard(transactions, auth, crypto, finances, owner(), sourceVersion);
        return new WebMvcConfigurer() {
            /**
             * 모든 분석 controller를 경로 별칭과 무관하게 보호한다.
             * @created 2026-11-04
             * @usedBy Spring MVC
             */
            @Override
            public void addInterceptors(InterceptorRegistry registry) {
                registry.addInterceptor(guard);
            }
        };
    }

    /**
     * 명시적 합성 원천 범위를 시작 및 요청 가드에서 동일하게 제한한다.
     * @created 2026-11-04
     * @usedBy deployedGammaRuntime, deployedGammaGuard
     */
    private static boolean validSource(String sourceVersion) {
        return sourceVersion.matches("fixture:gamma-(year|challenge):1:[0-9-]+:[0-9]+")
            || sourceVersion.matches("fixture:gamma-fresh:(development|holdout):[0-9]+");
    }

    /**
     * 분석 API에만 추가 시험 범위를 적용한다. 일반 로그인·금융 조회는 기존 경로를 유지한다.
     * @created 2026-11-04
     * @usedBy deployedGammaGuard, GammaLocalTest
     */
    static final class Guard implements HandlerInterceptor {
        private final AuthTransactions transactions;
        private final AuthRepository auth;
        private final AuthCrypto crypto;
        private final FinancialRepository finances;
        private final UUID owner;
        private final String sourceVersion;

        /**
         * 인증 및 원천 저장소와 서버 측 허용 대상을 받는다.
         * @created 2026-11-04
         * @usedBy deployedGammaGuard, GammaLocalTest
         */
        Guard(
            AuthTransactions transactions,
            AuthRepository auth,
            AuthCrypto crypto,
            FinancialRepository finances,
            UUID owner,
            String sourceVersion
        ) {
            this.transactions = transactions;
            this.auth = auth;
            this.crypto = crypto;
            this.finances = finances;
            this.owner = owner;
            this.sourceVersion = sourceVersion;
        }

        /**
         * 클라이언트 본문을 읽기 전에 세션 사용자와 현재 원천 버전을 확인한다.
         * @created 2026-11-04
         * @usedBy Spring MVC
         */
        @Override
        public boolean preHandle(
            HttpServletRequest request,
            HttpServletResponse response,
            Object handler
        ) {
            if (!(handler instanceof HandlerMethod method)
                || !method.getBeanType().getPackageName()
                    .equals(GammaLocal.CONTROLLER_PACKAGE)) {
                return true;
            }
            String header = request.getHeader(ApiConfigConstants.Auth.AUTHORIZATION);
            boolean bearer = header != null
                && header.startsWith(ApiConfigConstants.Auth.BEARER_PREFIX);
            String token = bearer
                ? header.substring(7) : null;
            transactions.run(() -> {
                String digest;
                try {
                    digest = crypto.tokenDigest(token);
                } catch (IllegalArgumentException failure) {
                    digest = null;
                }
                var session = auth.authorize(digest)
                    .orElseThrow(() -> new FinancialException(
                        401, ApiCodeConstants.Analysis.SESSION_INVALID));
                if (!owner.equals(session.userId())) {
                    throw new FinancialException(403, Analysis.RESOURCE_FORBIDDEN);
                }
                ObjectNode source = finances.load(session.userId());
                String current = source.path(ApiFieldConstants.Analysis.SOURCE_VERSION).asString();
                if (!sourceVersion.equals(current)) {
                    throw new FinancialException(409, Analysis.STALE_DATA);
                }
                return null;
            });
            return true;
        }
    }
}
