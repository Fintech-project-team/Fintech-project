package com.payse.api.analysis.service;

import java.time.Clock;
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
     */
    @Bean
    @ConditionalOnMissingBean(AnalysisRuntime.class)
    public AnalysisRuntime analysisRuntime() {
        return new AnalysisRuntime();
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
