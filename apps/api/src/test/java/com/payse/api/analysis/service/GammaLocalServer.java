package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisConfig;
import com.payse.api.ApiTestConstants.GammaLocal;
import com.payse.api.PayseApiApplication;
import org.springframework.boot.SpringApplication;

/**
 * 별도 테스트 classpath에서만 감마 로컬 키 서버를 시작한다.
 * @created 2026-11-03
 * @usedBy Gradle gammaLocalServer
 */
public final class GammaLocalServer {
    /**
     * 생성하지 않는 실행 진입점이다.
     * @created 2026-11-03
     * @usedBy JVM
     */
    private GammaLocalServer() {
    }

    /**
     * 비공개 설정 파일은 명시 인자로 받으며 기본 접속은 loopback으로 제한한다.
     * @created 2026-11-03
     * @usedBy JVM
     */
    public static void main(String[] args) {
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
        application.setDefaultProperties(
            java.util.Map.of(AnalysisConfig.SERVER_ADDRESS, GammaLocal.LOOPBACK)
        );
        application.run(args);
    }
}
