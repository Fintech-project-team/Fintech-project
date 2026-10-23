package com.payse.api.auth;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.PayseApiApplication;
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
     */
    @Test
    void inactiveProfileDoesNotRequireKeys() {
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
     */
    @Test
    void activeProfileFailsClosedWithoutKeys() {
        try (var context = new AnnotationConfigApplicationContext()) {
            var environment = new MockEnvironment();
            environment.setActiveProfiles("auth");
            context.setEnvironment(environment);
            context.register(AuthCryptoConfiguration.class);
            assertThrows(RuntimeException.class, context::refresh);
        }
        for (String required : new String[]{"PAYSE_AUTH_CODE_KEY_ID", "PAYSE_AUTH_CODE_KEY_BASE64", "PAYSE_AUTH_LIMIT_KEY_BASE64"}) {
            var environment = validEnvironment();
            environment.setProperty(required, "");
            assertThrows(IllegalArgumentException.class, () -> new AuthCryptoConfiguration().authSecrets(environment));
        }
    }

    /**
     * 유효한 명시 설정에서만 두 빈이 구성되며 활성화 자체가 HTTP 인증을 구현하지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     */
    @Test
    void activeProfileInjectsValidatedKeys() {
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
     * @throws Exception 로컬 테스트 서버 요청 실패
     */
    @Test
    void activeProfileStillDeniesBusinessHttpRoutes() throws Exception {
        var environment = validEnvironment();
        var application = new SpringApplication(PayseApiApplication.class);
        application.setDefaultProperties(Map.of(
            "PAYSE_AUTH_CODE_KEY_ID", environment.getProperty("PAYSE_AUTH_CODE_KEY_ID"),
            "PAYSE_AUTH_CODE_KEY_BASE64", environment.getProperty("PAYSE_AUTH_CODE_KEY_BASE64"),
            "PAYSE_AUTH_LIMIT_KEY_BASE64", environment.getProperty("PAYSE_AUTH_LIMIT_KEY_BASE64")));
        try (var context = application.run("--spring.profiles.active=auth", "--server.address=127.0.0.1", "--server.port=0");
             var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build()) {
            int port = ((WebServerApplicationContext) context).getWebServer().getPort();
            String origin = "http://127.0.0.1:" + port;
            assertNotNull(context.getBean(AuthCrypto.class));
            var health = HttpRequest.newBuilder(URI.create(origin + "/internal/health/live"))
                .timeout(Duration.ofSeconds(5)).GET().build();
            assertEquals(200, client.send(health, HttpResponse.BodyHandlers.ofString()).statusCode());
            String token = context.getBean(AuthCrypto.class).issueToken().value();
            for (String route : new String[]{"/snapshot", "/transactions", "/demo-sessions", "/institution-links"}) {
                var request = HttpRequest.newBuilder(URI.create(origin + route)).timeout(Duration.ofSeconds(5))
                    .header("Authorization", "Bearer " + token).header("Content-Type", "application/json")
                    .method(route.equals("/demo-sessions") || route.equals("/institution-links") ? "POST" : "GET",
                        HttpRequest.BodyPublishers.noBody()).build();
                var response = client.send(request, HttpResponse.BodyHandlers.ofString());
                assertEquals(401, response.statusCode(), route);
                assertTrue(response.headers().allValues("set-cookie").isEmpty());
                assertFalse(response.body().contains(token));
            }
        }
    }

    /**
     * 비정규 Base64·잘못된 길이·동일 키·식별자 오류를 일반 오류로 거절한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     */
    @Test
    void invalidConfigurationNeverEchoesSecretInput() {
        var configuration = new AuthCryptoConfiguration();
        for (String invalid : new String[]{"private-secret!", "", " ", "A".repeat(44),
                Base64.getEncoder().encodeToString(new byte[31]), Base64.getEncoder().encodeToString(new byte[33]),
                Base64.getEncoder().encodeToString(new byte[32]).replace("=", "")}) {
            for (String property : new String[]{"PAYSE_AUTH_CODE_KEY_BASE64", "PAYSE_AUTH_LIMIT_KEY_BASE64"}) {
                var environment = validEnvironment().withProperty(property, invalid);
                var failure = assertThrows(IllegalArgumentException.class, () -> configuration.authSecrets(environment));
                if (!invalid.isBlank()) assertFalse(failure.toString().contains(invalid));
                assertNull(failure.getCause());
            }
        }
        var sameKey = validEnvironment();
        sameKey.setProperty("PAYSE_AUTH_LIMIT_KEY_BASE64", sameKey.getProperty("PAYSE_AUTH_CODE_KEY_BASE64"));
        assertThrows(IllegalArgumentException.class, () -> configuration.authSecrets(sameKey));
        var badId = validEnvironment().withProperty("PAYSE_AUTH_CODE_KEY_ID", "private:id");
        var failure = assertThrows(IllegalArgumentException.class, () -> configuration.authSecrets(badId));
        assertFalse(failure.toString().contains("private:id"));
    }

    /**
     * 비밀값이 아닌 공개 테스트 벡터만 주입한 독립 환경을 준비한다.
     * @created 2026-10-22
     * @usedBy AuthCryptoConfigurationTest 각 검사
     * @return 기본 운영 설정에 영향을 주지 않는 테스트 환경
     */
    private static MockEnvironment validEnvironment() {
        byte[] code = new byte[32];
        byte[] limit = new byte[32];
        for (int index = 0; index < 32; index++) {
            code[index] = (byte) index;
            limit[index] = (byte) (index + 32);
        }
        return new MockEnvironment().withProperty("PAYSE_AUTH_CODE_KEY_ID", "test_code")
            .withProperty("PAYSE_AUTH_CODE_KEY_BASE64", Base64.getEncoder().encodeToString(code))
            .withProperty("PAYSE_AUTH_LIMIT_KEY_BASE64", Base64.getEncoder().encodeToString(limit));
    }
}
