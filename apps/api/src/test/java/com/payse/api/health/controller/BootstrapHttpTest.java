package com.payse.api.health.controller;

import com.payse.api.ApiTestConstants.HealthHttp;
import com.payse.api.ApiTestConstants.HealthPaths;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.PayseApiApplication;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.TestInstance;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.ConfigurableApplicationContext;

/**
 * 실제 HTTP 서버에서 생존 확인과 기본 접근 차단을 검사한다.
 * @created 2026-10-20
 * @usedBy Gradle test의 JUnit 실행
 */
@TestInstance(TestInstance.Lifecycle.PER_CLASS)
class BootstrapHttpTest {
    private ConfigurableApplicationContext context;
    private int port;
    private final HttpClient client = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(5))
        .build();

    /**
     * 임의 로컬 포트에서 실제 서버를 시작한다. 외부 DB와 모킹 에이전트가 필요 없다.
     * @created 2026-10-20
     * @usedBy JUnit BeforeAll
     */
    @BeforeAll
    void startServer() {
        context = SpringApplication.run(PayseApiApplication.class, "--server.port=0");
        port = ((WebServerApplicationContext) context).getWebServer().getPort();
    }

    /**
     * 테스트가 연 서버와 HTTP 자원을 종료한다.
     * @created 2026-10-20
     * @usedBy JUnit AfterAll
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    @AfterAll
    void stopServer() {
        if (context != null) {
            context.close();
        }
        client.close();
    }

    /**
     * 공개 생존 응답에 금융 자료·DB 세부 정보·로그인 쿠키가 없는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void exposesOnlyHealthStatus() throws Exception {
        var response = get(HealthPaths.LIVE_PATH, null);
        assertEquals(200, response.statusCode());
        assertEquals("{\"status\":\"UP\"}", response.body());
        assertTrue(
            response.headers()
                .firstValue(HealthHttp.LOWER_CONTENT_TYPE)
                .orElse("")
                .contains(HealthHttp.JSON_TYPE)
        );
        assertTrue(
            response.headers()
                .allValues(HealthHttp.LOWER_SET_COOKIE)
                .isEmpty()
        );
    }

    /**
     * 인증 구현 전 금융 경로가 공개되지 않는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void blocksBusinessRoutes() throws Exception {
        for (String route : new String[] {
            HealthPaths.SNAPSHOT_PATH,
            HealthPaths.TRANSACTIONS_PATH,
            HealthPaths.SESSIONS_PATH,
            HealthPaths.ACTUATOR_ENV_PATH
        }) {
            var response = get(route, null);
            assertEquals(401, response.statusCode(), route);
            assertTrue(
                response.headers()
                    .allValues(HealthHttp.LOWER_SET_COOKIE)
                    .isEmpty()
            );
            assertFalse(response.body().contains("token"));
        }
    }

    /**
     * 임의 토큰·기본 인증 헤더가 접근을 허용하지 않는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsInvalidCredentials() throws Exception {
        assertEquals(401, get(HealthPaths.SNAPSHOT_PATH, "Bearer demo-token").statusCode());
        assertEquals(401, get(HealthPaths.SNAPSHOT_PATH, "Basic dXNlcjpwYXNz").statusCode());
    }

    /**
     * 쓰기 시도와 사용자 사칭 입력을 차단하고 로그인 쿠키를 만들지 않는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void blocksUnauthenticatedWrites() throws Exception {
        var request = HttpRequest
            .newBuilder(URI.create("http://127.0.0.1:" + port + HealthPaths.SNAPSHOT_PATH))
            .timeout(Duration.ofSeconds(5))
            .header(HealthHttp.CONTENT_TYPE, HealthHttp.JSON_TYPE)
            .POST(HttpRequest.BodyPublishers.ofString("{\"userId\":\"other-user\"}"))
            .build();
        var response = client.send(request, HttpResponse.BodyHandlers.ofString());
        assertEquals(401, response.statusCode());
        assertTrue(
            response.headers()
                .allValues(HealthHttp.LOWER_SET_COOKIE)
                .isEmpty()
        );
    }

    /**
     * 로컬 서버에 GET을 보내 응답을 반환한다.
     * @created 2026-10-20
     * @usedBy 이 클래스의 HTTP 접근 검사 메서드
     * @param route 검사 경로
     * @param authorization 테스트용 헤더 또는 null
     * @return 실제 HTTP 응답
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private HttpResponse<String> get(String route, String authorization) throws Exception {
        var builder = HttpRequest.newBuilder(URI.create("http://127.0.0.1:" + port + route))
            .timeout(Duration.ofSeconds(5));
        if (authorization != null) {
            builder.header(HealthHttp.AUTHORIZATION, authorization);
        }
        return client.send(builder.GET().build(), HttpResponse.BodyHandlers.ofString());
    }
}
