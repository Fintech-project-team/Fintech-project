package com.payse.api.config;

import com.payse.api.ApiTestConstants.AuthConfig;
import com.payse.api.ApiTestConstants.AuthHttp;
import com.payse.api.ApiTestConstants.AuthPaths;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.PayseApiApplication;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.crypto.AuthSecrets;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Base64;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.mock.env.MockEnvironment;

/**
 * 인증 프로필의 설정 필수성·오류 비밀 보호와 bootstrap 비활성 경계를 검사한다.
 * @created 2026-10-22
 * @usedBy Gradle test의 JUnit 실행
 */
class AuthCryptoConfigurationTest {
    /**
     * 비활성 인증 기능에는 비밀 설정과 빈 생성이 필요하지 않다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void skipsInactiveProfile() {
        try (var context = new AnnotationConfigApplicationContext()) {
            context.setEnvironment(new MockEnvironment());
            context.register(AuthCryptoConfiguration.class);
            context.refresh();
            assertTrue(context.getBeansOfType(AuthSecrets.class).isEmpty());
            assertTrue(context.getBeansOfType(AuthCrypto.class).isEmpty());
        }
    }

    /**
     * auth가 활성화된 경우 누락 키를 임의 값으로 대체하지 않고 시작에 실패한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리
     */
    @Test
    void requiresActiveProfileKeys() {
        try (var context = new AnnotationConfigApplicationContext()) {
            var environment = new MockEnvironment();
            environment.setActiveProfiles("auth");
            context.setEnvironment(environment);
            context.register(AuthCryptoConfiguration.class);
            assertThrows(RuntimeException.class, context::refresh);
        }
        var requiredKeys = new String[] {
            AuthConfig.PAYSE_AUTH_CODE_KEY_ID,
            AuthConfig.PAYSE_AUTH_CODE_KEY_BASE64,
            AuthConfig.PAYSE_AUTH_LIMIT_KEY_BASE64
        };
        for (String required : requiredKeys) {
            var environment = validEnvironment();
            environment.setProperty(required, "");
            assertThrows(
                IllegalArgumentException.class,
                () -> new AuthCryptoConfiguration().authSecrets(environment)
            );
        }
    }

    /**
     * 유효한 명시 설정에서만 두 빈이 구성되며 활성화 자체가 HTTP 인증을 구현하지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void loadsValidKeys() {
        try (var context = new AnnotationConfigApplicationContext()) {
            var environment = validEnvironment();
            environment.setActiveProfiles("auth");
            context.setEnvironment(environment);
            context.register(AuthCryptoConfiguration.class);
            context.refresh();
            assertEquals("test_code", context.getBean(AuthSecrets.class).codeKeyId());
            var crypto = context.getBean(AuthCrypto.class);
            var token = crypto.issueToken();
            assertTrue(crypto.verifyToken(token.value(), token.digest()));
        }
    }

    /**
     * 실제 auth 프로필 서버에서도 암호 빈 생성만으로 업무 HTTP가 열리지 않는지 확인한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @throws Exception 로컬 테스트 서버 요청 실패
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리
     */
    @Test
    void blocksBusinessRoutes() throws Exception {
        var environment = validEnvironment();
        var application = new SpringApplication(PayseApiApplication.class);
        application.setDefaultProperties(
            Map.of(
                AuthConfig.PAYSE_AUTH_CODE_KEY_ID,
                environment.getProperty(AuthConfig.PAYSE_AUTH_CODE_KEY_ID),
                AuthConfig.PAYSE_AUTH_CODE_KEY_BASE64,
                environment.getProperty(AuthConfig.PAYSE_AUTH_CODE_KEY_BASE64),
                AuthConfig.PAYSE_AUTH_LIMIT_KEY_BASE64,
                environment.getProperty(AuthConfig.PAYSE_AUTH_LIMIT_KEY_BASE64)
            )
        );
        try (var context = application
            .run("--spring.profiles.active=auth", "--server.address=127.0.0.1", "--server.port=0");
            var client = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(5))
                .build()) {
            int port = ((WebServerApplicationContext) context).getWebServer().getPort();
            String origin = "http://127.0.0.1:" + port;
            assertNotNull(context.getBean(AuthCrypto.class));
            var health = HttpRequest.newBuilder(URI.create(origin + AuthPaths.LIVE_PATH))
                .timeout(Duration.ofSeconds(5))
                .GET()
                .build();
            assertEquals(
                200,
                client.send(health, HttpResponse.BodyHandlers.ofString()).statusCode()
            );
            String token = context.getBean(AuthCrypto.class)
                .issueToken()
                .value();
            var businessRoutes = new String[] {
                AuthPaths.SNAPSHOT_PATH,
                AuthPaths.TRANSACTIONS_PATH,
                AuthPaths.SESSIONS_PATH,
                AuthPaths.INSTITUTION_LINKS_PATH
            };
            for (String route : businessRoutes) {
                var request = HttpRequest.newBuilder(URI.create(origin + route))
                    .timeout(Duration.ofSeconds(5))
                    .header(AuthHttp.AUTHORIZATION, AuthHttp.BEARER_PREFIX + token)
                    .header(AuthHttp.CONTENT_TYPE, AuthHttp.JSON_TYPE)
                    .method(
                        route.equals(AuthPaths.SESSIONS_PATH)
                            || route.equals(AuthPaths.INSTITUTION_LINKS_PATH) ? AuthHttp.POST
                                : AuthHttp.GET,
                        HttpRequest.BodyPublishers.noBody()
                    )
                    .build();
                var response = client.send(request, HttpResponse.BodyHandlers.ofString());
                assertEquals(401, response.statusCode(), route);
                assertTrue(
                    response.headers()
                        .allValues(AuthHttp.LOWER_SET_COOKIE)
                        .isEmpty()
                );
                assertFalse(response.body().contains(token));
            }
        }
    }

    /**
     * 비정규 Base64·잘못된 길이·동일 키·식별자 오류를 일반 오류로 거절한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void redactsInvalidSecrets() {
        var configuration = new AuthCryptoConfiguration();
        var invalidKeys = new String[] {
            "private-secret!",
            "",
            " ",
            "A".repeat(44),
            Base64.getEncoder().encodeToString(new byte[31]),
            Base64.getEncoder().encodeToString(new byte[33]),
            Base64.getEncoder()
                .encodeToString(new byte[32])
                .replace("=", "")
        };
        for (String invalid : invalidKeys) {
            for (String property : new String[] {
                AuthConfig.PAYSE_AUTH_CODE_KEY_BASE64,
                AuthConfig.PAYSE_AUTH_LIMIT_KEY_BASE64 }) {
                var environment = validEnvironment().withProperty(property, invalid);
                var failure = assertThrows(
                    IllegalArgumentException.class,
                    () -> configuration.authSecrets(environment)
                );
                if (!invalid.isBlank()) {
                    assertFalse(failure.toString().contains(invalid));
                }
                assertNull(failure.getCause());
            }
        }
        var sameKey = validEnvironment();
        sameKey.setProperty(
            AuthConfig.PAYSE_AUTH_LIMIT_KEY_BASE64,
            sameKey.getProperty(AuthConfig.PAYSE_AUTH_CODE_KEY_BASE64)
        );
        assertThrows(IllegalArgumentException.class, () -> configuration.authSecrets(sameKey));
        var badId = validEnvironment()
            .withProperty(AuthConfig.PAYSE_AUTH_CODE_KEY_ID, "private:id");
        var failure = assertThrows(
            IllegalArgumentException.class,
            () -> configuration.authSecrets(badId)
        );
        assertFalse(failure.toString().contains("private:id"));
    }

    /**
     * 비밀값이 아닌 공개 테스트 벡터만 주입한 독립 환경을 준비한다.
     * @created 2026-10-22
     * @usedBy AuthCryptoConfigurationTest 각 검사
     * @return 기본 운영 설정에 영향을 주지 않는 테스트 환경
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private static MockEnvironment validEnvironment() {
        byte[] code = new byte[32];
        byte[] limit = new byte[32];
        for (int index = 0; index < 32; index++) {
            code[index] = (byte) index;
            limit[index] = (byte) (index + 32);
        }
        return new MockEnvironment().withProperty(AuthConfig.PAYSE_AUTH_CODE_KEY_ID, "test_code")
            .withProperty(
                AuthConfig.PAYSE_AUTH_CODE_KEY_BASE64,
                Base64.getEncoder().encodeToString(code)
            )
            .withProperty(
                AuthConfig.PAYSE_AUTH_LIMIT_KEY_BASE64,
                Base64.getEncoder().encodeToString(limit)
            );
    }
}
