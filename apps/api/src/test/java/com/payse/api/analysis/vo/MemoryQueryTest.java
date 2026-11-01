package com.payse.api.analysis.vo;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.finance.error.FinancialException;
import java.time.Instant;
import java.time.LocalDate;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;

/**
 * 실제 관리 조회 파서의 허용 필드·길이·날짜 범위와 서울 시각 경계를 검증한다.
 * @created 2026-11-01
 * @usedBy Gradle JUnit
 */
class MemoryQueryTest {
    /**
     * 날짜가 없으면 전체 목록을 조회하며 임의 기간이나 페이지를 만들지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsNoPeriod() {
        MemoryQuery query = MemoryQuery.parse(Map.of());
        assertNull(query.cursor());
        assertNull(query.startDate());
        assertNull(query.endDate());
        assertNull(query.start());
        assertNull(query.end());
    }

    /**
     * 단일 서울 저장일의 시작은 포함하고 다음 날 자정은 제외하는 경계로 변환한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void mapsInclusiveSeoulDateToExclusiveEnd() {
        MemoryQuery query = MemoryQuery.parse(period("2026-11-01", "2026-11-01"));
        assertEquals(LocalDate.of(2026, 11, 1), query.startDate());
        assertEquals(query.startDate(), query.endDate());
        assertEquals(Instant.parse("2026-10-31T15:00:00Z"), query.start());
        assertEquals(Instant.parse("2026-11-01T15:00:00Z"), query.end());
    }

    /**
     * 윤일·월말·연말의 존재하는 날짜를 유지하고 달력 경계 다음 날만 제외 시각으로 쓴다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsCalendarBoundaries() {
        MemoryQuery leap = MemoryQuery.parse(period("2024-02-29", "2024-03-01"));
        assertEquals(Instant.parse("2024-02-28T15:00:00Z"), leap.start());
        assertEquals(Instant.parse("2024-03-01T15:00:00Z"), leap.end());
        MemoryQuery year = MemoryQuery.parse(period("2026-12-31", "2026-12-31"));
        assertEquals(Instant.parse("2026-12-31T15:00:00Z"), year.end());
    }

    /**
     * 날짜 한쪽 누락·존재하지 않는 날짜·역전·다른 형식을 업무 검증 오류로 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidPeriods() {
        rejects(Map.of("startDate", new String[]{"2026-11-01"}), 422, "VALIDATION_FAILED");
        rejects(Map.of("endDate", new String[]{"2026-11-01"}), 422, "VALIDATION_FAILED");
        rejects(period("2026-11-02", "2026-11-01"), 422, "VALIDATION_FAILED");
        for (String invalid : List.of("", "2026-02-29", "2026-04-31", "2026-13-01", "0000-01-01",
                "2026-1-01", "2026/11/01", "2026-11-01T00:00:00+09:00", " 2026-11-01", "2026-11-01 ", "10000-01-01")) {
            rejects(period(invalid, invalid), 422, "VALIDATION_FAILED");
        }
    }

    /**
     * 허용하지 않은 필드와 중복·빈 배열은 서로 다른 파서 해석으로 통과하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsUnknownOrRepeatedParameters() {
        rejects(Map.of("userId", new String[]{"other-owner"}), 400, "VALIDATION_FAILED");
        rejects(Map.of("limit", new String[]{"100"}), 400, "VALIDATION_FAILED");
        rejects(Map.of("cursor", new String[]{"first", "second"}), 400, "VALIDATION_FAILED");
        rejects(Map.of("startDate", new String[]{"2026-11-01", "2026-11-01"},
            "endDate", new String[]{"2026-11-01"}), 400, "VALIDATION_FAILED");
        rejects(Map.of("cursor", new String[0]), 400, "VALIDATION_FAILED");
        rejects(Map.of("cursor", new String[]{null}), 400, "VALIDATION_FAILED");
    }

    /**
     * 커서 길이는 2048자를 상한으로 검사한다. 값의 진위·소유권은 별도 암호화 검증이 담당한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void boundsCursorWithoutTreatingItAsAuthenticated() {
        String boundary = "a".repeat(2048);
        MemoryQuery query = MemoryQuery.parse(Map.of("cursor", new String[]{boundary}));
        assertEquals(boundary, query.cursor());
        assertNull(query.startDate());
        rejects(Map.of("cursor", new String[]{"a".repeat(2049)}), 400, "INVALID_CURSOR");
        for (String blank : List.of("", " ", "\t", "\n")) {
            rejects(Map.of("cursor", new String[]{blank}), 400, "INVALID_CURSOR");
        }
        assertEquals("MemoryQuery[REDACTED]", query.toString());
        assertFalse(query.toString().contains(boundary));
    }

    /**
     * 실제 HTTP 파서와 같은 단일 문자열 배열로 날짜쌍을 준비한다.
     * @created 2026-11-01
     * @usedBy 날짜 경계·오류 검사
     */
    private Map<String, String[]> period(String start, String end) {
        return Map.of("startDate", new String[]{start}, "endDate", new String[]{end});
    }

    /**
     * 예외 발생만 보지 않고 기존 HTTP 변환에 쓰는 상태와 오류 코드까지 확인한다.
     * @created 2026-11-01
     * @usedBy 입력 거절 검사
     */
    private void rejects(Map<String, String[]> parameters, int status, String code) {
        FinancialException failure = assertThrows(FinancialException.class, () -> MemoryQuery.parse(parameters));
        assertEquals(status, failure.status());
        assertEquals(code, failure.code());
    }
}
