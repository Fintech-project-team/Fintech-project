package com.payse.api.finance.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.ApiTestConstants.FinanceCodes;
import com.payse.api.ApiTestConstants.FinanceConfig;
import com.payse.api.ApiTestConstants.FinanceFields;
import com.payse.api.ApiTestConstants.FinancePaths;
import com.payse.api.finance.dto.PageSlice;
import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 요청 기간과 실제 확보 범위를 분리하고 v4 공개 관계·100건 페이지·원천 불변을 검사한다.
 * @created 2026-11-01
 * @usedBy Gradle JUnit
 */
class FinancialPeriodTest {
    private final FinancialProjection projection = new FinancialProjection();
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 2년 요청에는 보유한 과거 관계 거래도 포함하지만 coverage를 완전 확보로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void includesStoredHistoryWithoutExtendingCoverage() throws Exception {
        ObjectNode source = source("refund-outside-window");
        ObjectNode before = source.deepCopy();
        LocalDate end = LocalDate.parse(
            source.path(FinanceFields.COVERAGE)
                .get(0)
                .path(FinanceFields.REQUESTED_END)
                .asString()
        );
        LocalDate start = end.minusYears(2);
        Set<String> historical = ids(source.path(FinanceFields.RELATED_TRANSACTIONS));
        assertFalse(historical.isEmpty());

        List<String> received = readAll(source, codes(source), start, end);
        Set<String> expected = ids(source.path(FinanceFields.TRANSACTIONS));
        expected.addAll(historical);
        assertEquals(
            expected.stream()
                .sorted()
                .toList(),
            received
        );
        assertTrue(received.size() > 100);
        assertEquals(before, source);

        var page = projection.project(source, codes(source), "1", null, true, start, end).body();
        assertEquals(FinanceCodes.API_V4, page.path(FinanceFields.SCHEMA_VERSION).asString());
        assertEquals(source.get(FinanceFields.COVERAGE), page.get(FinanceFields.COVERAGE));
        assertFalse(page.has(FinanceFields.SETTINGS));
        assertFalse(page.has(FinanceFields.ACCOUNTS));
    }

    /**
     * 날짜 경계 안의 거래만 본문에 두고 기간 밖 환불 원거래는 연결 근거로 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void retainsOutsidePeriodOriginalAsEvidence() throws Exception {
        ObjectNode source = source("refund-outside-window");
        Set<String> historical = ids(source.path(FinanceFields.RELATED_TRANSACTIONS));
        List<JsonNode> matches = new ArrayList<>();
        source.path(FinanceFields.TRANSACTIONS)
            .forEach(
                row -> {
                    if (historical
                        .contains(row.path(FinanceFields.ORIGINAL_TRANSACTION_ID).asString())) {
                        matches.add(row);
                    }
                }
            );

        assertEquals(1, matches.size());
        JsonNode refund = matches.getFirst();
        LocalDate day = eventDate(refund);

        var page = projection.project(source, codes(source), "1", null, true, day, day).body();
        assertTrue(
            ids(page.path(FinanceFields.TRANSACTIONS))
                .contains(refund.path(FinanceFields.TRANSACTION_ID).asString())
        );
        assertTrue(
            ids(page.path(FinanceFields.RELATED_TRANSACTIONS))
                .contains(refund.path(FinanceFields.ORIGINAL_TRANSACTION_ID).asString())
        );
        for (JsonNode row : page.path(FinanceFields.TRANSACTIONS)) {
            assertEquals(day, eventDate(row));
        }
    }

    /**
     * 은행 입출금·구매·환불·승인 취소는 각 원천 업무일을 사용하며 양끝 날짜를 포함한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void usesEachTransactionDateKind() throws Exception {
        ObjectNode source = source("refund-outside-window");
        var transactionKinds = List.of(
            FinanceCodes.ACCOUNT_ENTRY,
            FinanceCodes.CARD_PURCHASE,
            FinanceCodes.CARD_REFUND,
            FinanceCodes.CARD_CANCELLATION
        );
        for (String kind : transactionKinds) {
            List<JsonNode> candidates = new ArrayList<>();
            source.path(FinanceFields.TRANSACTIONS)
                .forEach(
                    row -> {
                        if (kind.equals(row.path(FinanceFields.RECORD_KIND).asString())) {
                            candidates.add(row);
                        }
                    }
                );

            assertFalse(candidates.isEmpty(), kind);
            JsonNode target = candidates.getFirst();
            LocalDate day = eventDate(target);
            List<String> received = readAll(source, codes(source), day, day);
            assertTrue(
                received.contains(target.path(FinanceFields.TRANSACTION_ID).asString()),
                kind
            );

            List<String> expected = new ArrayList<>();
            var transactionGroups = List.of(
                FinanceFields.TRANSACTIONS,
                FinanceFields.RELATED_TRANSACTIONS
            );
            for (String group : transactionGroups) {
                for (JsonNode row : source.path(group)) {
                    if (eventDate(row).equals(day)) {
                        expected.add(row.path(FinanceFields.TRANSACTION_ID).asString());
                    }
                }
            }

            assertEquals(
                expected.stream()
                    .sorted()
                    .toList(),
                received,
                kind
            );
        }
    }

    /**
     * 요청 기간을 넓혀도 미연결 은행의 거래나 계좌 식별자를 공개하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void periodDoesNotExpandInstitutionAccess() throws Exception {
        ObjectNode source = source("demo-ready");
        Set<String> cardCodes = new HashSet<>();
        source.path(FinanceFields.CARDS)
            .forEach(card -> cardCodes.add(card.path(FinanceFields.INSTITUTION_CODE).asString()));

        LocalDate end = LocalDate.parse(
            source.path(FinanceFields.COVERAGE)
                .get(0)
                .path(FinanceFields.REQUESTED_END)
                .asString()
        );
        Set<String> actual = new HashSet<>(readAll(source, cardCodes, end.minusYears(2), end));
        for (JsonNode row : source.path(FinanceFields.TRANSACTIONS)) {
            if (FinanceCodes.ACCOUNT_ENTRY.equals(row.path(FinanceFields.RECORD_KIND).asString())) {
                assertFalse(actual.contains(row.path(FinanceFields.TRANSACTION_ID).asString()));
            }
        }

        assertFalse(actual.isEmpty());
    }

    /**
     * 데이터가 없는 정상 기간은 빈 페이지이고 확보 범위를 확대하거나 원천을 생성하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void emptyPeriodPreservesCoverageAndSource() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode before = source.deepCopy();
        LocalDate day = LocalDate.parse(
            source.path(FinanceFields.COVERAGE)
                .get(0)
                .path(FinanceFields.REQUESTED_START)
                .asString()
        ).minusYears(2);
        PageSlice page = projection.project(source, codes(source), "1", null, true, day, day);

        assertTrue(
            page.body()
                .path(FinanceFields.TRANSACTIONS)
                .isEmpty()
        );
        assertTrue(
            page.body()
                .path(FinanceFields.RELATED_TRANSACTIONS)
                .isEmpty()
        );
        assertFalse(page.hasMore());
        assertNull(page.lastId());
        assertEquals(source.path(FinanceFields.COVERAGE), page.body().path(FinanceFields.COVERAGE));
        assertEquals(before, source);
    }

    /**
     * 날짜 미확보를 임의 날짜·정상 빈 결과로 숨기지 않으며 새 필터도 기존503을 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void missingEventDateStillFailsClosed() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode target = FinancialProjection.rows(source, FinanceFields.TRANSACTIONS)
            .stream()
            .filter(
                row -> FinanceCodes.ACCOUNT_ENTRY
                    .equals(row.path(FinanceFields.RECORD_KIND).asString())
            )
            .findFirst()
            .orElseThrow();
        target.putNull(FinanceFields.BOOKING_DATE)
            .putNull(FinanceFields.OCCURRED_AT);

        var failure = assertThrows(
            FinancialException.class,
            () -> projection.project(
                source,
                codes(source),
                "1",
                null,
                true,
                LocalDate.of(2024, 1, 1),
                LocalDate.of(2026, 10, 19)
            )
        );
        assertEquals(503, failure.status());
    }

    /**
     * 같은 업무 종류의 시각만 서울 날짜로 변환하고 다른 occurredAtBasis를 대신 쓰지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void timestampFallbackRequiresMatchingBasis() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode target = FinancialProjection.rows(source, FinanceFields.TRANSACTIONS)
            .stream()
            .filter(
                row -> FinanceCodes.ACCOUNT_ENTRY
                    .equals(row.path(FinanceFields.RECORD_KIND).asString())
            )
            .findFirst()
            .orElseThrow();
        LocalDate day = eventDate(target);
        target.putNull(FinanceFields.BOOKING_DATE)
            .put(FinanceFields.OCCURRED_AT, day + "T00:30:00+09:00")
            .put(FinanceFields.OCCURRED_AT_BASIS, FinanceCodes.BOOKING);

        assertTrue(
            readAll(source, codes(source), day, day)
                .contains(target.path(FinanceFields.TRANSACTION_ID).asString())
        );

        target.put(FinanceFields.OCCURRED_AT_BASIS, FinanceCodes.PURCHASE);
        assertEquals(
            503,
            assertThrows(
                FinancialException.class,
                () -> projection.project(source, codes(source), "1", null, true, day, day)
            ).status()
        );
    }

    /**
     * 존재하는 거래가 원천 확보 구간과 모순되면 기간 지정으로 오류를 숨기지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    @Test
    void declaredCoverageGapStillFailsClosed() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode target = FinancialProjection.rows(source, FinanceFields.TRANSACTIONS)
            .stream()
            .filter(
                row -> FinanceCodes.ACCOUNT_ENTRY
                    .equals(row.path(FinanceFields.RECORD_KIND).asString())
            )
            .findFirst()
            .orElseThrow();
        ObjectNode range = FinancialProjection.rows(source, FinanceFields.COVERAGE)
            .stream()
            .filter(
                row -> row.path(FinanceFields.TARGET_ID)
                    .equals(target.path(FinanceFields.ACCOUNT_ID))
            )
            .findFirst()
            .orElseThrow();
        range.putArray(FinanceFields.COVERED_RANGES);
        LocalDate day = eventDate(target);

        assertEquals(
            503,
            assertThrows(
                FinancialException.class,
                () -> projection.project(source, codes(source), "1", null, true, day, day)
            ).status()
        );
    }

    /**
     * 고정 UUID·표시명 대신 지정 사례의 관계를 읽고 독립 복사본을 사용한다.
     * @created 2026-11-01
     * @usedBy FinancialPeriodTest
     */
    private ObjectNode source(String scenario) throws Exception {
        return (ObjectNode) json.readTree(
            Files.readString(Path.of(FinancePaths.SNAPSHOTS_DIRECTORY, scenario + ".json"))
        );
    }

    /**
     * 실제 사례의 기관만 연결된 것으로 준비한다.
     * @created 2026-11-01
     * @usedBy FinancialPeriodTest
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    private Set<String> codes(ObjectNode source) {
        Set<String> values = new LinkedHashSet<>();
        source.path(FinanceFields.INSTITUTIONS)
            .forEach(row -> values.add(row.path(FinanceFields.CODE).asString()));
        return values;
    }

    /**
     * 검증된 자료에서 거래 식별 집합을 읽으며 같은 ID 중복을 거절한다.
     * @created 2026-11-01
     * @usedBy FinancialPeriodTest
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    private Set<String> ids(JsonNode rows) {
        Set<String> values = new HashSet<>();
        rows.forEach(
            row -> assertTrue(values.add(row.path(FinanceFields.TRANSACTION_ID).asString()))
        );
        return values;
    }

    /**
     * 공개 계약의 종류별 날짜를 테스트 기대값으로 읽고 임의 날짜를 만들지 않는다.
     * @created 2026-11-01
     * @usedBy FinancialPeriodTest
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    private LocalDate eventDate(JsonNode row) {
        String field = switch (row.path(FinanceFields.RECORD_KIND).asString()) {
        case FinanceCodes.ACCOUNT_ENTRY -> FinanceFields.BOOKING_DATE;
        case FinanceCodes.CARD_PURCHASE -> FinanceFields.PURCHASE_DATE;
        case FinanceCodes.CARD_REFUND -> FinanceFields.REFUND_DATE;
        case FinanceCodes.CARD_CANCELLATION -> FinanceFields.CANCELLATION_DATE;
        default -> throw new AssertionError("Unknown fixture transaction kind");
        };
        if (row.path(field).isString()) {
            return LocalDate.parse(row.path(field).asString());
        }

        assertEquals(
            field.substring(0, field.length() - 4),
            row.path(FinanceFields.OCCURRED_AT_BASIS).asString()
        );
        return OffsetDateTime.parse(row.path(FinanceFields.OCCURRED_AT).asString())
            .atZoneSameInstant(ZoneId.of(FinanceConfig.SEOUL_ZONE))
            .toLocalDate();
    }

    /**
     * 같은 기간·UUID 순서를 끝까지 읽고 중복·페이지 상한·원천 coverage 변형을 검사한다.
     * @created 2026-11-01
     * @usedBy FinancialPeriodTest
     * @modified 2026-11-02 - 계약 상수 참조·제어문 본문 구분
     */
    private List<String> readAll(
        ObjectNode source,
        Set<String> codes,
        LocalDate start,
        LocalDate end
    ) {
        List<String> values = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        UUID after = null;
        do {
            PageSlice page = projection.project(source, codes, "1", after, true, start, end);
            List<String> pageIds = new ArrayList<>();
            page.body()
                .path(FinanceFields.TRANSACTIONS)
                .forEach(row -> pageIds.add(row.path(FinanceFields.TRANSACTION_ID).asString()));

            assertTrue(pageIds.size() <= 100);
            assertEquals(
                pageIds.stream()
                    .sorted()
                    .toList(),
                pageIds
            );
            pageIds.forEach(id -> assertTrue(seen.add(id)));
            values.addAll(pageIds);

            if (!page.hasMore()) {
                break;
            }

            assertNotNull(page.lastId());
            assertNotEquals(after, page.lastId());
            after = page.lastId();
        } while (true);

        return values;
    }
}
