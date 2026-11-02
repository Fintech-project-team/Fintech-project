package com.payse.ai.transport;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.AiTestConstants.ProviderCodes;
import com.payse.ai.AiTestConstants.ProviderValues;
import com.payse.ai.testing.ProviderStub;
import com.payse.ai.transport.ProviderHttp.ProviderFailure;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;

/**
 * 공급자 HTTP 경계의 비밀 제외·단일 전송·응답 제한을 검증한다.
 * @created 2026-11-01
 * @usedBy JUnit 5
 */
class ProviderHttpTest {
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 정상 JSON과 헤더를 한 번 전송한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void postsOnce() throws Exception {
        try (var stub = new ProviderStub()) {
            stub.reply(200, "{\"ok\":true}");
            ProviderHttp http = stub.http();
            var endpoint = stub.endpoint();
            var request = json.createObjectNode().put(ProviderValues.INPUT, "synthetic");
            var response = http.post(endpoint, "test-key", request);
            assertTrue(response.path("ok").asBoolean());
            assertEquals(1, stub.requests().size());
            assertEquals(
                "Bearer test-key",
                stub.requests()
                    .getFirst()
                    .authorization()
            );
            assertEquals(
                "synthetic",
                stub.requests()
                    .getFirst()
                    .body()
                    .path(ProviderValues.INPUT)
                    .asString()
            );
        }
    }

    /**
     * 제어문자·공백 자격은 원문 없는 오류이며 전송하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void rejectsInvalidCredentialsBeforeSend() throws Exception {
        try (var stub = new ProviderStub()) {
            String[] invalidCredentials = {
                null,
                "",
                " ",
                "sentinel\r",
                "sentinel\n",
                "sentinel\u0000",
                "sentinel\u007f",
                "sentinel key"
            };
            for (String credential : invalidCredentials) {
                ProviderFailure failure = assertThrows(
                    ProviderFailure.class,
                    () -> stub.http().post(stub.endpoint(), credential, json.createObjectNode())
                );
                assertEquals(ProviderCodes.CREDENTIAL_UNAVAILABLE, failure.getMessage());
                assertFalse(failure.mayHaveBeenSent());
                assertNull(failure.getCause());
                assertFalse(failure.toString().contains("sentinel"));
            }
            assertEquals(0, stub.requests().size());
        }
    }

    /**
     * 429·서버 오류·리디렉션 모두 자동으로 따라가거나 재전송하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void doesNotRetryOrRedirect() throws Exception {
        try (var stub = new ProviderStub()) {
            for (int status : new int[] {
                302,
                429,
                500
            }) {
                int before = stub.requests().size();
                stub.reply(status, "secret-response-body");
                ProviderFailure failure = assertThrows(
                    ProviderFailure.class,
                    () -> stub.http().post(stub.endpoint(), "test-key", json.createObjectNode())
                );
                assertEquals(ProviderCodes.HTTP_FAILURE_PREFIX + status, failure.getMessage());
                assertTrue(failure.mayHaveBeenSent());
                assertNull(failure.getCause());
                assertEquals(before + 1, stub.requests().size());
            }
        }
    }

    /**
     * JSON 뒤 추가 객체·문법 오류·비객체 본문을 부분 성공으로 받지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsAmbiguousJson() throws Exception {
        try (var stub = new ProviderStub()) {
            for (String response : new String[] {
                "{} {}",
                "{} trailing-secret",
                "[]",
                "null",
                "not-json"
            }) {
                stub.reply(200, response);
                ProviderFailure failure = assertThrows(
                    ProviderFailure.class,
                    () -> stub.http().post(stub.endpoint(), "test-key", json.createObjectNode())
                );
                assertEquals(ProviderCodes.INVALID_PROVIDER_JSON, failure.getMessage());
                assertTrue(failure.mayHaveBeenSent());
                assertNull(failure.getCause());
            }
        }
    }

    /**
     * 바이트 상한은 정확히 허용하고 한 바이트 초과는 수신 중 중단한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void enforcesResponseLimit() throws Exception {
        try (var stub = new ProviderStub()) {
            stub.reply(200, "{}");
            ProviderHttp http = stub.http(Duration.ofSeconds(2), 2);
            var endpoint = stub.endpoint();
            var response = http.post(endpoint, "test-key", json.createObjectNode());
            assertTrue(response.isObject());
            ProviderFailure failure = assertThrows(
                ProviderFailure.class,
                () -> stub.http(Duration.ofSeconds(2), 1)
                    .post(stub.endpoint(), "test-key", json.createObjectNode())
            );
            assertEquals(ProviderCodes.RESPONSE_TOO_LARGE, failure.getMessage());
            assertTrue(failure.mayHaveBeenSent());
        }
    }

    /**
     * 헤더 후 본문이 멈춰도 반환하며 이미 전송한 요청을 미전송으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void boundsStalledBody() throws Exception {
        try (var stub = new ProviderStub()) {
            stub.reply(200, "{}");
            stub.delayBody(1200);
            ProviderFailure failure = assertTimeoutPreemptively(
                Duration.ofSeconds(3),
                () -> {
                    return assertThrows(
                        ProviderFailure.class,
                        () -> {
                            ProviderHttp http = stub.http(Duration.ofMillis(500), 1024);
                            var endpoint = stub.endpoint();
                            var request = json.createObjectNode();
                            http.post(endpoint, "test-key", request);
                        }
                    );
                }
            );
            assertEquals(ProviderCodes.TRANSMISSION_UNKNOWN, failure.getMessage());
            assertTrue(failure.mayHaveBeenSent());
            assertEquals(1, stub.requests().size());
        }
    }
}
