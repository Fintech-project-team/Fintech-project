package com.payse.api.finance.controller;

import com.payse.api.ApiTestConstants.FinanceCodes;
import com.payse.api.ApiTestConstants.FinanceFields;
import com.payse.api.ApiTestConstants.FinanceHttp;
import com.payse.api.ApiTestConstants.FinancePaths;

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
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void enforcesExactByteLimit() {
        String body = "\"" + "a".repeat(65534) + "\"";
        assertTrue(input.read(request(FinanceHttp.POST, body)).isString());
        assertEquals(
            413,
            assertThrows(
                FinancialException.class,
                () -> input.read(request(FinanceHttp.POST, body + " "))
            ).status()
        );
        assertEquals(
            413,
            assertThrows(
                FinancialException.class,
                () -> input.read(request(FinanceHttp.POST, "가".repeat(21846)))
            ).status()
        );
    }

    /**
     * 중복 키·뒤따른 JSON·잘못된 UTF-8을 묵시 변환하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsAmbiguousJson() {
        for (String body : new String[] {
            "{\"a\":1,\"a\":2}",
            "{} {}",
            "",
            "{"
        }) {
            assertEquals(
                400,
                assertThrows(
                    FinancialException.class,
                    () -> input.read(request(FinanceHttp.POST, body))
                ).status()
            );
        }
        MockHttpServletRequest invalid = request(FinanceHttp.POST, "{}");
        invalid.setContent(new byte[] { (byte) 0xc3, (byte) 0x28 });
        assertEquals(
            400,
            assertThrows(FinancialException.class, () -> input.read(invalid)).status()
        );
    }

    /**
     * DELETE에서만 W 헤더를 쓰고 본문/중복 헤더를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void deleteHasOnePreconditionSource() {
        MockHttpServletRequest request = request(FinanceHttp.DELETE, "");
        request.addHeader(FinanceHttp.DATA_VERSION_HEADER, "1");
        request.addHeader(FinanceHttp.RULE_VERSION_HEADER, FinanceCodes.CALCULATION_RULES);
        request.addHeader(FinanceHttp.IDEMPOTENCY_HEADER, "operation");
        assertEquals(
            "operation",
            input.read(request)
                .get(FinanceFields.IDEMPOTENCY_KEY)
                .asString()
        );
        request.addHeader(FinanceHttp.IDEMPOTENCY_HEADER, "other");
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.read(request)).status()
        );
        MockHttpServletRequest post = request(FinanceHttp.POST, "{}");
        post.addHeader(FinanceHttp.IDEMPOTENCY_HEADER, "operation");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.read(post)).status());
    }

    /**
     * 후속 페이지에는 단일 cursor만 허용하고 offset·중복·본문을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void paginationHasNoAlternateFilters() {
        MockHttpServletRequest request = request(FinanceHttp.GET, "");
        assertNull(input.cursor(request, false));
        assertEquals(
            400,
            assertThrows(FinancialException.class, () -> input.cursor(request, true)).status()
        );
        request.addParameter(FinanceFields.CURSOR, "opaque");
        assertEquals("opaque", input.cursor(request, true));
        request.addParameter("offset", "0");
        assertEquals(
            400,
            assertThrows(FinancialException.class, () -> input.cursor(request, true)).status()
        );
    }

    /**
     * 압축·다른 문자셋·비 JSON 타입을 자동 해석하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsUnsupportedEncoding() {
        MockHttpServletRequest request = request(FinanceHttp.POST, "{}");
        request.setContentType("text/plain");
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.read(request)).status()
        );
        request.setContentType(FinanceHttp.JSON_TYPE);
        request.addHeader(FinanceHttp.CONTENT_ENCODING, "gzip");
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.read(request)).status()
        );
    }

    /**
     * 요청마다 독립 서블릿 입력을 구성한다.
     * @created 2026-10-29
     * @usedBy 위 HTTP 입력 테스트
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private MockHttpServletRequest request(String method, String text) {
        MockHttpServletRequest request = new MockHttpServletRequest(
            method,
            FinancePaths.SETTINGS_PATH
        );
        request.setContentType(FinanceHttp.JSON_TYPE);
        request.setContent(text.getBytes(StandardCharsets.UTF_8));
        return request;
    }
}
