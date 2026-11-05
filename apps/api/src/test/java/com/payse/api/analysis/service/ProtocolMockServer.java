package com.payse.api.analysis.service;

import com.payse.api.PayseApiApplication;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.Properties;
import org.springframework.boot.SpringApplication;
import org.springframework.core.env.MapPropertySource;

/**
 * 운영 JAR 밖의 테스트 classpath에서만 실행하는 프로토콜 연동 서버다.
 * @created 2026-11-04
 * @usedBy testing/protocol/mock_server.py
 */
public final class ProtocolMockServer {
    /**
     * 실행 진입점만 제공한다.
     * @created 2026-11-04
     * @usedBy 없음: 인스턴스화 금지
     */
    private ProtocolMockServer() {
    }

    /**
     * 새 폐기 DB·제한 역할·loopback 설정만 받고 외부 공급자 설정은 요구하지 않는다.
     * @created 2026-11-04
     * @usedBy JVM
     */
    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 1
            || !"isolated".equals(System.getenv("PAYSE_PROTOCOL_MOCK"))) {
            throw new IllegalStateException("Use testing/protocol/mock_server.py");
        }
        Properties settings = new Properties();
        try (var reader = Files.newBufferedReader(Path.of(arguments[0]))) {
            settings.load(reader);
        }
        String url = settings.getProperty("PAYSE_JDBC_URL", "");
        String login = settings.getProperty("PAYSE_DB_USER", "");
        if (!url.matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_protocol")
            || !login.matches("payse_protocol_[0-9a-f]{32}")
            || !"127.0.0.1".equals(settings.getProperty("server.address"))) {
            throw new IllegalStateException("Isolated protocol settings required");
        }
        Map<String, Object> configuration = new HashMap<>();
        settings.forEach((key, value) -> configuration.put(key.toString(), value));
        SpringApplication app = new SpringApplication(
            PayseApiApplication.class,
            ProtocolMockConfig.class
        );
        app.setAdditionalProfiles(
            "database",
            "auth",
            "finance",
            "analysis"
        );
        // application.properties의 운영 기본 포트보다 검증한 격리 설정을 우선한다.
        app.addInitializers(context -> context.getEnvironment().getPropertySources().addFirst(
            new MapPropertySource("protocolIsolated", configuration)
        ));
        app.run();
    }
}
