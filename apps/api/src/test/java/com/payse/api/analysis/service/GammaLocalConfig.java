package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisCodes;
import com.payse.api.ApiTestConstants.AnalysisFields;
import com.payse.api.ApiTestConstants.AnalysisHttp;
import com.payse.api.ApiTestConstants.GammaLocal;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFactory;
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
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialRepository;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.net.http.HttpClient;
import java.nio.file.Path;
import java.time.Duration;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerInterceptor;
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
     * @modified 2026-11-04 - 시험에서도 실제 프롬프트 지문을 재사용 판정에 반영
     */
    @Bean
    @Primary
    AnalysisRuntime gammaRuntime(
        GammaLocalKeys keys,
        AnalysisCosts costs,
        @Value("${payse.gamma-local.llm-file:}") String file,
        @Value("${payse.gamma-local.project:}") String project,
        @Value("${payse.gamma-local.pricing:}") String version
    ) {
        if (file.isBlank() || !Path.of(file).isAbsolute()
            || project.isBlank() || version.isBlank()) {
            throw new IllegalStateException(GammaLocal.INCOMPLETE);
        }
        LlmSettings llm = LlmSettings.read(Path.of(file));
        AnalysisPricing pricing = new AnalysisPricing(costs.policy(project, version), llm.model());
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
        var factory = llm.factory(http, pricing.inputLimit(), pricing.outputLimit());
        ModelFactory models = (instructions, schema) ->
            new ObservedModel(factory.create(instructions, schema));
        var analysis = new AnalysisService(models, pricing.inputLimit());
        ObjectNode versions = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.MODEL, llm.model())
            .put(AnalysisFields.PROMPT, analysis.promptVersion())
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
     */
    @Bean
    WebMvcConfigurer gammaGuard(
        AuthTransactions transactions,
        AuthRepository auth,
        AuthCrypto crypto,
        FinancialRepository finances,
        @Value("${payse.gamma-local.source-version:}") String sourceVersion
    ) {
        if (!sourceVersion.matches("fixture:gamma-(year|challenge):1:[0-9-]+:[0-9]+")) {
            throw new IllegalStateException(GammaLocal.MISSING_SOURCE);
        }
        Guard guard = new Guard(transactions, auth, crypto, finances, owner(), sourceVersion);
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

    /**
     * 분석 API에만 추가 시험 범위를 적용한다. 일반 로그인·금융 조회는 기존 경로를 유지한다.
     * @created 2026-11-03
     * @usedBy gammaGuard, GammaLocalTest
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
         * @created 2026-11-03
         * @usedBy gammaGuard, GammaLocalTest
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
         * @created 2026-11-03
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
            String header = request.getHeader(AnalysisHttp.AUTHORIZATION);
            String token = header != null && header.startsWith(AnalysisHttp.BEARER_PREFIX)
                ? header.substring(7) : null;
            transactions.run(() -> {
                String digest;
                try {
                    digest = crypto.tokenDigest(token);
                } catch (IllegalArgumentException failure) {
                    digest = null;
                }
                var session = auth.authorize(digest)
                    .orElseThrow(() -> new FinancialException(401, GammaLocal.SESSION_INVALID));
                if (!owner.equals(session.userId())) {
                    throw new FinancialException(403, AnalysisCodes.RESOURCE_FORBIDDEN);
                }
                ObjectNode source = finances.load(session.userId());
                if (!sourceVersion.equals(source.path(AnalysisFields.SOURCE_VERSION).asString())) {
                    throw new FinancialException(409, AnalysisCodes.STALE_DATA);
                }
                return null;
            });
            return true;
        }
    }
}
