package com.payse.api.analysis.vo;

import com.payse.api.finance.error.FinancialException;
import java.time.Instant;
import java.time.LocalDate;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import java.util.Map;
import java.util.Set;

/**
 * 최초 저장일의 한국 날짜 범위와 다음 페이지 위치다. 보관 기한을 변경하지 않는다.
 * @created 2026-11-01
 * @usedBy MemoryController.list, MemoryCatalog.select
 */
public record MemoryQuery(String cursor, LocalDate startDate, LocalDate endDate) {
    private static final ZoneId SEOUL = ZoneId.of("Asia/Seoul");

    /**
     * 인증 후 허용한 단일 query 값과 양끝 포함 날짜 쌍만 읽는다.
     * @created 2026-11-01
     * @usedBy MemoryController.list
     */
    public static MemoryQuery parse(Map<String, String[]> parameters) {
        if (!Set.of("cursor", "startDate", "endDate").containsAll(parameters.keySet())) {
            throw new FinancialException(400, "VALIDATION_FAILED");
        }
        String cursor = value(parameters, "cursor");
        if (cursor != null && (cursor.isBlank() || cursor.length() > 2048)) {
            throw new FinancialException(400, "INVALID_CURSOR");
        }
        String start = value(parameters, "startDate");
        String end = value(parameters, "endDate");
        if ((start == null) != (end == null)) throw invalid();
        LocalDate first = start == null ? null : date(start);
        LocalDate last = end == null ? null : date(end);
        if (first != null && first.isAfter(last)) throw invalid();
        return new MemoryQuery(cursor, first, last);
    }

    /**
     * 시작일 한국 자정을 DB의 포함 시각 경계로 전달한다.
     * @created 2026-11-01
     * @usedBy MemoryCatalog.select
     */
    public Instant start() { return startDate == null ? null : startDate.atStartOfDay(SEOUL).toInstant(); }

    /**
     * 종료일 다음 한국 자정을 제외 경계로 전달한다.
     * @created 2026-11-01
     * @usedBy MemoryCatalog.select
     */
    public Instant end() { return endDate == null ? null : endDate.plusDays(1).atStartOfDay(SEOUL).toInstant(); }

    /**
     * 중복 query 값이 서로 다른 필터로 해석되지 않게 거절한다.
     * @created 2026-11-01
     * @usedBy parse
     */
    private static String value(Map<String, String[]> parameters, String key) {
        String[] values = parameters.get(key);
        if (values == null) return null;
        if (values.length != 1 || values[0] == null) throw new FinancialException(400, "VALIDATION_FAILED");
        return values[0];
    }

    /**
     * 존재하는 4자리 연도 ISO 날짜만 허용하며 월말을 임의 보정하지 않는다.
     * @created 2026-11-01
     * @usedBy parse
     */
    private static LocalDate date(String value) {
        try {
            if (!value.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")) throw invalid();
            LocalDate date = LocalDate.parse(value);
            if (date.getYear() < 1) throw invalid();
            return date;
        } catch (DateTimeParseException failure) { throw invalid(); }
    }

    /**
     * 날짜 의미 오류를 기존 업무 검증 오류로 반환한다.
     * @created 2026-11-01
     * @usedBy parse, date
     */
    private static FinancialException invalid() { return new FinancialException(422, "VALIDATION_FAILED"); }

    /**
     * 암호화 페이지 토큰을 자동 로그에 노출하지 않는다.
     * @created 2026-11-01
     * @usedBy Java 문자열 변환
     */
    @Override public String toString() { return "MemoryQuery[REDACTED]"; }
}
