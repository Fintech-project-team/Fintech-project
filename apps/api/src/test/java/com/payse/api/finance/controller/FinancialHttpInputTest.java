package com.payse.api.finance.controller;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.finance.error.FinancialException;
import java.nio.charset.StandardCharsets;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

/**
 * HTTP 바이트 상한·엄격 JSON·헤더/쿼리의 단일 권위를 검사한다.
 * @created 2026-10-29
 * @usedBy Gradle JUnit
 */
class FinancialHttpInputTest {
    private final FinancialHttpInput input = new FinancialHttpInput();

    /**
     * 64 KiB는 읽고 1바이트 초과는 부분 파싱 없이 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void enforcesExactByteLimit() {
        String body = "\"" + "a".repeat(65534) + "\"";
        assertTrue(input.read(request("POST", body)).isString());
        assertEquals(413, assertThrows(FinancialException.class,
            () -> input.read(request("POST", body + " "))).status());
        assertEquals(413, assertThrows(FinancialException.class,
            () -> input.read(request("POST", "가".repeat(21846)))).status());
    }

    /**
     * 중복 키·뒤따른 JSON·잘못된 UTF-8을 묵시 변환하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void rejectsAmbiguousJson() {
        for (String body : new String[]{"{\"a\":1,\"a\":2}", "{} {}", "", "{"}) {
            assertEquals(400, assertThrows(FinancialException.class,
                () -> input.read(request("POST", body))).status());
        }
        MockHttpServletRequest invalid = request("POST", "{}");
        invalid.setContent(new byte[]{(byte) 0xc3, (byte) 0x28});
        assertEquals(400, assertThrows(FinancialException.class, () -> input.read(invalid)).status());
    }

    /**
     * DELETE에서만 W 헤더를 쓰고 본문/중복 헤더를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void deleteHasOnePreconditionSource() {
        MockHttpServletRequest request = request("DELETE", "");
        request.addHeader("Payse-Expected-Data-Version", "1");
        request.addHeader("Payse-Rule-Version", "PAYSE-CALC-1");
        request.addHeader("Idempotency-Key", "operation");
        assertEquals("operation", input.read(request).get("idempotencyKey").asString());
        request.addHeader("Idempotency-Key", "other");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.read(request)).status());
        MockHttpServletRequest post = request("POST", "{}");
        post.addHeader("Idempotency-Key", "operation");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.read(post)).status());
    }

    /**
     * 후속 페이지에는 단일 cursor만 허용하고 offset·중복·본문을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void paginationHasNoAlternateFilters() {
        MockHttpServletRequest request = request("GET", "");
        assertNull(input.cursor(request, false));
        assertEquals(400, assertThrows(FinancialException.class, () -> input.cursor(request, true)).status());
        request.addParameter("cursor", "opaque");
        assertEquals("opaque", input.cursor(request, true));
        request.addParameter("offset", "0");
        assertEquals(400, assertThrows(FinancialException.class, () -> input.cursor(request, true)).status());
    }

    /**
     * 압축·다른 문자셋·비 JSON 타입을 자동 해석하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void rejectsUnsupportedEncoding() {
        MockHttpServletRequest request = request("POST", "{}");
        request.setContentType("text/plain");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.read(request)).status());
        request.setContentType("application/json");
        request.addHeader("Content-Encoding", "gzip");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.read(request)).status());
    }

    /**
     * 요청마다 독립 서블릿 입력을 구성한다.
     * @created 2026-10-29
     * @usedBy 위 HTTP 입력 테스트
     */
    private MockHttpServletRequest request(String method, String text) {
        MockHttpServletRequest request = new MockHttpServletRequest(method, "/settings");
        request.setContentType("application/json");
        request.setContent(text.getBytes(StandardCharsets.UTF_8));
        return request;
    }
}
