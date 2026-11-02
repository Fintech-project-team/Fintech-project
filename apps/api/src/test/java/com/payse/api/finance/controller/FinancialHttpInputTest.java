package com.payse.api.finance.controller;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.ApiTestConstants.FinanceCodes;
import com.payse.api.ApiTestConstants.FinanceFields;
import com.payse.api.ApiTestConstants.FinanceHttp;
import com.payse.api.ApiTestConstants.FinancePaths;
import com.payse.api.finance.dto.TransactionQuery;
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
     * 날짜 쌍은 최초 페이지와 후속 페이지에 동일하게 전달하며 윤일도 실제 달력대로 읽는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void readsPeriodWithOptionalCursor() {
        MockHttpServletRequest request = request(FinanceHttp.GET, "");
        request.addParameter(FinanceFields.START_DATE, "2024-02-29");
        request.addParameter(FinanceFields.END_DATE, "2026-10-19");
        var first = input.transactions(request);
        assertNull(first.cursor());
        assertEquals(LocalDate.of(2024, 2, 29), first.startDate());
        assertEquals(LocalDate.of(2026, 10, 19), first.endDate());
        request.addParameter(FinanceFields.CURSOR, "opaque");
        assertEquals("opaque", input.transactions(request).cursor());
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.cursor(request, false)).status()
        );
    }

    /**
     * 기간 없는 기존 후속 조회는 cursor 하나만 받는 규칙을 그대로 지킨다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesLegacyTransactionQuery() {
        MockHttpServletRequest request = request(FinanceHttp.GET, "");
        assertEquals(
            400,
            assertThrows(FinancialException.class, () -> input.transactions(request)).status()
        );
        request.addParameter(FinanceFields.CURSOR, "opaque");
        assertEquals("opaque", input.transactions(request).cursor());
        assertFalse(input.transactions(request).hasPeriod());
        request.addParameter("offset", "0");
        assertEquals(
            400,
            assertThrows(FinancialException.class, () -> input.transactions(request)).status()
        );
    }

    /**
     * 일부 날짜·중복 인자·역전·없는 날짜·공백·시각·본문을 임의 보정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsAmbiguousPeriods() {
        for (String start : new String[] {
            "2025-02-29",
            "2026-13-01",
            "2026-11-01",
            "0000-01-01",
            "2026-1-01",
            " 2026-01-01",
            "2026-01-01T00:00:00Z"
        }) {
            MockHttpServletRequest request = period(start, "2026-10-19");
            assertEquals(
                422,
                assertThrows(FinancialException.class, () -> input.transactions(request)).status(),
                start
            );
        }

        MockHttpServletRequest missing = request(FinanceHttp.GET, "");
        missing.addParameter(FinanceFields.START_DATE, "2026-01-01");
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.transactions(missing)).status()
        );
        MockHttpServletRequest duplicate = period("2026-01-01", "2026-10-19");
        duplicate.addParameter(FinanceFields.START_DATE, "2026-01-02");
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.transactions(duplicate)).status()
        );
        MockHttpServletRequest unrelated = period("2026-01-01", "2026-10-19");
        unrelated.addParameter(FinanceFields.OWNER_ID, "foreign");
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.transactions(unrelated)).status()
        );
        MockHttpServletRequest body = period("2026-01-01", "2026-10-19");
        body.setContent("{}".getBytes(StandardCharsets.UTF_8));
        assertEquals(
            422,
            assertThrows(FinancialException.class, () -> input.transactions(body)).status()
        );
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
     * 날짜 쌍 직접 생성에서도 누락·역전·연도 한계를 업무 오류로 거절한다.
     * @created 2026-11-02
     * @usedBy JUnit
     */
    @Test
    void validatesOptionalPeriodPair() {
        LocalDate first = LocalDate.of(1, 1, 1);
        LocalDate last = LocalDate.of(9999, 12, 31);
        assertFalse(new TransactionQuery(null, null, null).hasPeriod());
        assertTrue(new TransactionQuery(null, first, last).hasPeriod());

        LocalDate[][] invalidPeriods = {
            { null, last },
            { first, null },
            { last, first },
            { first.minusDays(1), last },
            { first, last.plusDays(1) }
        };
        for (LocalDate[] period : invalidPeriods) {
            FinancialException failure = assertThrows(
                FinancialException.class,
                () -> new TransactionQuery(null, period[0], period[1])
            );
            assertEquals(422, failure.status());
        }
    }

    /**
     * 각 검증에 독립적인 조회 요청과 날짜 쌍을 준비한다.
     * @created 2026-11-01
     * @usedBy rejectsAmbiguousPeriods, acceptsSingleDayPeriod
     */
    private MockHttpServletRequest period(String start, String end) {
        MockHttpServletRequest request = request(FinanceHttp.GET, "");
        request.addParameter(FinanceFields.START_DATE, start);
        request.addParameter(FinanceFields.END_DATE, end);
        return request;
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
