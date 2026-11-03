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
     * @modified 2026-11-03 - 명시 설정·승인 비용 장부·공급자·KMS를 운영 실행에 연결
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
        var versions = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.MODEL, llm.model())
            .put(ApiFieldConstants.Analysis.PROMPT, Execution.PROMPT_VERSION)
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
            new AnalysisService(models, pricing.inputLimit()),
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
