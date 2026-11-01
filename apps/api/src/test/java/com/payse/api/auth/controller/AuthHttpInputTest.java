package com.payse.api.auth.controller;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.auth.error.AuthStoreException;
import java.net.InetAddress;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;
import org.springframework.mock.web.MockHttpServletRequest;

/**
 * 직접 연결과 명시한 loopback 프록시의 IP 신뢰 경계를 검사한다. 실제 외부 프록시 동작 검증과 구분한다.
 * @created 2026-10-30
 * @usedBy Gradle JUnit
 */
class AuthHttpInputTest {
    /**
     * 테스트별 접속 모드와 자동 전달 헤더 비활성 설정을 준비한다.
     * @created 2026-10-30
     * @usedBy 모든 테스트
     */
    private MockEnvironment environment(String mode) {
        return new MockEnvironment().withProperty("PAYSE_AUTH_PEER_MODE", mode)
            .withProperty("server.forward-headers-strategy", "none");
    }

    /**
     * 프록시 모드는 지정한 loopback 바인딩을 포함해 구성한다.
     * @created 2026-10-30
     * @usedBy 프록시 IP 테스트
     */
    private AuthHttpInput proxyInput() {
        return new AuthHttpInput(environment("loopback-proxy").withProperty("server.address", "127.0.0.1"));
    }

    /**
     * DNS나 네트워크 없이 원격지와 전달 헤더를 구성한다.
     * @created 2026-10-30
     * @usedBy 모든 peer 테스트
     */
    private MockHttpServletRequest request(String remote, String forwarded) {
        var request = new MockHttpServletRequest();
        request.setRemoteAddr(remote);
        if (forwarded != null) request.addHeader("X-Payse-Client-IP", forwarded);
        return request;
    }

    /**
     * 기존 direct는 바인딩 추가 설정 없이 연결 IP를 쓰고 모든 전달 헤더를 무시한다.
     * @created 2026-10-30
     * @usedBy JUnit test
     */
    @Test
    void directIgnoresSpoofedHeaders() throws Exception {
        var input = new AuthHttpInput(environment("direct"));
        var request = request("192.0.2.8", "198.51.100.6");
        request.addHeader("X-Payse-Client-IP", "203.0.113.5");
        request.addHeader("X-Forwarded-For", "198.51.100.7");
        request.addHeader("Forwarded", "for=203.0.113.9");
        assertEquals(InetAddress.getByName("192.0.2.8"), input.peer(request));
    }

    /**
     * direct의 IPv6 해석을 유지하고 기존에 허용하지 않던 hostname·주소 목록은 계속 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit test
     */
    @Test
    void directKeepsNumericAddressRules() throws Exception {
        var input = new AuthHttpInput(environment("direct"));
        assertEquals(InetAddress.getByName("2001:db8::8"), input.peer(request("2001:db8::8", null)));
        for (String remote : new String[]{"example.invalid", "127.0.0.1:80", "192.0.2.8,198.51.100.1",
                "::ffff:192.0.2.8", "999.0.0.1"}) {
            assertThrows(AuthStoreException.class, () -> input.peer(request(remote, null)), remote);
        }
    }

    /**
     * opt-in proxy는 loopback 바인딩과 전달 헤더 자동 변환 금지를 동시에 요구한다.
     * @created 2026-10-30
     * @usedBy JUnit test
     */
    @Test
    void proxyRequiresSafeBinding() {
        assertThrows(IllegalStateException.class, () -> new AuthHttpInput(environment("loopback-proxy")));
        for (String address : new String[]{"0.0.0.0", "::", "::1", "localhost", "127.0.0.1 "}) {
            assertThrows(IllegalStateException.class,
                () -> new AuthHttpInput(environment("loopback-proxy").withProperty("server.address", address)), address);
        }
        for (String forwarding : new String[]{"native", "framework"}) {
            assertThrows(IllegalStateException.class, () -> new AuthHttpInput(environment("loopback-proxy")
                .withProperty("server.address", "127.0.0.1").withProperty("server.forward-headers-strategy", forwarding)));
        }
        assertDoesNotThrow(this::proxyInput);
    }

    /**
     * 잘못된 모드를 direct나 proxy로 자동 보정하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit test
     */
    @Test
    void rejectsUnknownModes() {
        for (String mode : new String[]{"proxy", "", "direct ", "LOOPBACK-PROXY"}) {
            assertThrows(IllegalStateException.class, () -> new AuthHttpInput(environment(mode)));
        }
    }

    /**
     * 신뢰한 loopback peer의 단일 숫자 IPv4·IPv6만 받고 mapped IPv6는 같은 IPv4로 해석한다.
     * @created 2026-10-30
     * @usedBy JUnit test
     */
    @Test
    void proxyAcceptsNumericAddresses() throws Exception {
        var input = proxyInput();
        for (String address : new String[]{"192.0.2.8", "2001:db8::8", "::ffff:192.0.2.8"}) {
            assertEquals(InetAddress.getByName(address), input.peer(request("127.0.0.1", address)));
        }
        assertEquals(InetAddress.getByName("192.0.2.8"), input.peer(request("::1", "192.0.2.8")));
    }

    /**
     * 외부 peer는 전용 헤더 값이 정상이어도 신뢰하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit test
     */
    @Test
    void proxyRejectsExternalPeers() {
        var input = proxyInput();
        for (String remote : new String[]{"192.0.2.8", "10.0.0.1", "2001:db8::8", "example.invalid"}) {
            assertThrows(AuthStoreException.class, () -> input.peer(request(remote, "198.51.100.4")));
        }
    }

    /**
     * 헤더 누락·중복·목록·hostname·port·공백·zone은 원격 loopback 주소로 대체하지 않고 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit test
     */
    @Test
    void proxyRejectsAmbiguousHeaders() {
        var input = proxyInput();
        assertThrows(AuthStoreException.class, () -> input.peer(request("127.0.0.1", null)));
        var duplicate = request("127.0.0.1", "192.0.2.8");
        duplicate.addHeader("X-Payse-Client-IP", "192.0.2.8");
        assertThrows(AuthStoreException.class, () -> input.peer(duplicate));
        for (String address : new String[]{"", " ", "192.0.2.8 ", "192.0.2.8,198.51.100.4",
                "192.0.2.8:443", "[2001:db8::8]:443", "[2001:db8::8]", "example.invalid",
                "999.1.1.1", "192.0.2", "1234", "2001:db8:::8", "fe80::1%3", "0".repeat(46)}) {
            var failure = assertThrows(AuthStoreException.class,
                () -> input.peer(request("127.0.0.1", address)), address);
            assertEquals("Authentication storage failed", failure.getMessage());
        }
    }
}
