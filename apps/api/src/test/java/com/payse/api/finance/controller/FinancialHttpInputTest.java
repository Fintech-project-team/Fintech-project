package com.payse.api.finance.controller;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.finance.error.FinancialException;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
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
     * 날짜 쌍은 최초 페이지와 후속 페이지에 동일하게 전달하며 윤일도 실제 달력대로 읽는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void readsPeriodWithOptionalCursor() {
        MockHttpServletRequest request = request("GET", "");
        request.addParameter("startDate", "2024-02-29");
        request.addParameter("endDate", "2026-10-19");
        var first = input.transactions(request);
        assertNull(first.cursor());
        assertEquals(LocalDate.of(2024, 2, 29), first.startDate());
        assertEquals(LocalDate.of(2026, 10, 19), first.endDate());
        request.addParameter("cursor", "opaque");
        assertEquals("opaque", input.transactions(request).cursor());
        assertEquals(422, assertThrows(FinancialException.class, () -> input.cursor(request, false)).status());
    }

    /**
     * 기간 없는 기존 후속 조회는 cursor 하나만 받는 규칙을 그대로 지킨다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesLegacyTransactionQuery() {
        MockHttpServletRequest request = request("GET", "");
        assertEquals(400, assertThrows(FinancialException.class, () -> input.transactions(request)).status());
        request.addParameter("cursor", "opaque");
        assertEquals("opaque", input.transactions(request).cursor());
        assertFalse(input.transactions(request).hasPeriod());
        request.addParameter("offset", "0");
        assertEquals(400, assertThrows(FinancialException.class, () -> input.transactions(request)).status());
    }

    /**
     * 일부 날짜·중복 인자·역전·없는 날짜·공백·시각·본문을 임의 보정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsAmbiguousPeriods() {
        for (String start : new String[]{"2025-02-29", "2026-13-01", "2026-11-01", "0000-01-01",
                "2026-1-01", " 2026-01-01", "2026-01-01T00:00:00Z"}) {
            MockHttpServletRequest request = period(start, "2026-10-19");
            assertEquals(422, assertThrows(FinancialException.class, () -> input.transactions(request)).status(), start);
        }
        MockHttpServletRequest missing = request("GET", "");
        missing.addParameter("startDate", "2026-01-01");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.transactions(missing)).status());
        MockHttpServletRequest duplicate = period("2026-01-01", "2026-10-19");
        duplicate.addParameter("startDate", "2026-01-02");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.transactions(duplicate)).status());
        MockHttpServletRequest unrelated = period("2026-01-01", "2026-10-19");
        unrelated.addParameter("ownerId", "foreign");
        assertEquals(422, assertThrows(FinancialException.class, () -> input.transactions(unrelated)).status());
        MockHttpServletRequest body = period("2026-01-01", "2026-10-19");
        body.setContent("{}".getBytes(StandardCharsets.UTF_8));
        assertEquals(422, assertThrows(FinancialException.class, () -> input.transactions(body)).status());
    }

    /**
     * 단일 날짜 양끝을 포함하는 요청도 정상 범위다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsSingleDayPeriod() {
        var query = input.transactions(period("2026-10-19", "2026-10-19"));
        assertEquals(query.startDate(), query.endDate());
    }

    /**
     * 각 검증에 독립적인 조회 요청과 날짜 쌍을 준비한다.
     * @created 2026-11-01
     * @usedBy rejectsAmbiguousPeriods, acceptsSingleDayPeriod
     */
    private MockHttpServletRequest period(String start, String end) {
        MockHttpServletRequest request = request("GET", "");
        request.addParameter("startDate", start);
        request.addParameter("endDate", end);
        return request;
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
