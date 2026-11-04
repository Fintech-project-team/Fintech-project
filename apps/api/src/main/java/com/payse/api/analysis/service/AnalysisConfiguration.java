package com.payse.api.analysis.service;

import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.config.LlmSettings;
import com.payse.ai.transport.ProviderHttp;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.analysis.provider.CostedKeys;
import com.payse.api.analysis.provider.GoogleKms;
import com.payse.api.constants.ApiConfigConstants.Execution;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
import java.net.http.HttpClient;
import java.nio.file.Path;
import java.time.Clock;
import java.time.Duration;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnMissingBean;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;

/**
 * DB API와 외부 유료 실행 활성화를 분리한다. 로컬 자격 파일을 자동 활성화하지 않는다.
 * @created 2026-11-01
 * @usedBy Spring analysis 프로필
 */
@Configuration(proxyBeanMethods = false)
@Profile("database & auth & finance & analysis")
public class AnalysisConfiguration {
    /**
     * 운영비·공급자·KMS 준비가 승인되기 전에는 전송 차단 경계를 사용한다.
     * @created 2026-11-01
     * @usedBy Spring 생성자 주입
     * @modified 2026-11-03 - 명시 설정·비용 장부 연결 및 Google KMS 양수 단가 확인
     * @modified 2026-11-04 - 실제 프롬프트 내용 지문을 재사용 버전에 연결
     */
    @Bean
    @ConditionalOnMissingBean(AnalysisRuntime.class)
    public AnalysisRuntime analysisRuntime(
        @Value(Execution.SETTINGS_BINDING) String path,
        AnalysisCosts costs
    ) {
        if (path.isBlank()) {
            return new AnalysisRuntime();
        }
        AnalysisSettings settings = AnalysisSettings.read(Path.of(path));
        if (!settings.enabled()) {
            return new AnalysisRuntime();
        }
        LlmSettings llm = LlmSettings.read(settings.llmFile());
        if (!llm.enabled()) {
            throw new IllegalArgumentException(ApiMessageConstants.Execution.INVALID_SETTINGS);
        }
        settings.kmsToken();
        AnalysisPricing pricing = new AnalysisPricing(
            costs.policy(settings.project(), settings.pricingVersion()),
            llm.model()
        );
        if (pricing.kmsMicros() <= 0) {
            throw new IllegalArgumentException(ApiMessageConstants.Execution.INVALID_PRICING);
        }
        HttpClient client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(10))
            .followRedirects(HttpClient.Redirect.NEVER)
            .build();
        ProviderHttp http = new ProviderHttp(client, Duration.ofSeconds(60), 1048576);
        ModelFactory models = llm.factory(http, pricing.inputLimit(), pricing.outputLimit());
        CostedKeys keys = new CostedKeys(
            new GoogleKms(http, settings::kmsToken, settings.kmsKey()),
            costs,
            settings.project(),
            settings.pricingVersion(),
            pricing.kmsMicros()
        );
        var analysis = new AnalysisService(models, pricing.inputLimit());
        var versions = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.MODEL, llm.model())
            .put(ApiFieldConstants.Analysis.PROMPT, analysis.promptVersion())
            .put(ApiFieldConstants.Analysis.RESPONSE, Execution.RESPONSE_VERSION)
            .put(ApiFieldConstants.Analysis.POLICY, settings.pricingVersion());
        var execution = new AnalysisRuntime.Execution(
            models,
            costs,
            pricing,
            settings.project(),
            settings.pricingVersion()
        );
        return new AnalysisRuntime(
            analysis,
            new EnvelopeCipher(keys),
            versions,
            execution
        );
    }

    /**
     * 금융 날짜를 계산하지 않고 작업·보관 시각을 관리할 UTC 시계를 제공한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     */
    @Bean
    public Clock analysisClock() {
        return Clock.systemUTC();
    }
}
