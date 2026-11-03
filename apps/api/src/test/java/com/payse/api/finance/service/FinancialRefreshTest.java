package com.payse.api.finance.service;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.payse.api.ApiTestConstants.FinanceFields;
import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.List;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 원천 시각·잔액·거래 날짜의 갱신 경계를 v3/v4 공개 전에 확인한다.
 * @created 2026-11-02
 * @usedBy Gradle JUnit
 */
class FinancialRefreshTest {
    /**
     * 각 사실 날짜는 원천의 서울 업무 날짜를 넘을 수 없다.
     * @created 2026-11-02
     * @usedBy JUnit
     */
    @Test
    void futureTransactionDatesAreRejected() throws Exception {
        List<String> fields = List.of(
            FinanceFields.PURCHASE_DATE,
            FinanceFields.WITHDRAWAL_DATE,
            FinanceFields.REFUND_DATE,
            FinanceFields.CANCELLATION_DATE,
            FinanceFields.BOOKING_DATE
        );
        for (String directory : List.of("generated", "generated-v4")) {
            for (String field : fields) {
                ObjectNode source = source(directory);
                var transactions = FinancialProjection.rows(source, FinanceFields.TRANSACTIONS);
                assertFalse(transactions.isEmpty());
                for (ObjectNode transaction : transactions) {
                    transaction.put(field, "2026-10-20");
                }
                assertThrows(FinancialException.class, () -> FinancialShape.validate(source));
            }
        }
    }

    /**
     * 같은 날이어도 확보 시각 이후의 사실을 공개하지 않으며 보조 거래에도 적용한다.
     * @created 2026-11-02
     * @usedBy JUnit
     */
    @Test
    void futureInstantsAreRejectedInBothCollections() throws Exception {
        for (String group : List.of(
            FinanceFields.TRANSACTIONS,
            FinanceFields.RELATED_TRANSACTIONS
        )) {
            ObjectNode source = source("generated-v4");
            var transactions = FinancialProjection.rows(source, FinanceFields.TRANSACTIONS);
            assertFalse(transactions.isEmpty());
            source.putArray(FinanceFields.TRANSACTIONS);
            var selected = source.putArray(group);
            for (ObjectNode transaction : transactions) {
                ObjectNode changed = transaction.deepCopy();
                changed.put(FinanceFields.OCCURRED_AT, "2026-10-19T03:00:01Z");
                selected.add(changed);
            }
            assertThrows(FinancialException.class, () -> FinancialShape.validate(source));
        }
    }

    /**
     * 잔액은 같은 순간이어야 하며 동일 순간의 다른 UTC offset 표기는 보존한다.
     * @created 2026-11-02
     * @usedBy JUnit
     */
    @Test
    void balancesUseTheSameInstant() throws Exception {
        ObjectNode source = source("generated-v4");
        var accounts = FinancialProjection.rows(source, FinanceFields.ACCOUNTS);
        assertFalse(accounts.isEmpty());
        for (ObjectNode account : accounts) {
            account.put(FinanceFields.AS_OF, "2026-10-19T03:00:00Z");
        }
        ObjectNode before = source.deepCopy();
        assertDoesNotThrow(() -> FinancialShape.validate(source));
        assertEquals(before, source);
        for (ObjectNode account : accounts) {
            account.put(FinanceFields.AS_OF, "2026-10-19T03:00:01Z");
        }
        assertThrows(FinancialException.class, () -> FinancialShape.validate(source));
    }

    /**
     * 원천 날짜를 UTC 날짜와 혼동하지 않고 미래 예정일·사용자 취소 시각은 유지한다.
     * @created 2026-11-02
     * @usedBy JUnit
     */
    @Test
    void seoulDatesAndFuturePlansRemainValid() throws Exception {
        ObjectNode source = source("generated-v4");
        String asOf = "2026-10-19T00:30:00+09:00";
        source.put(FinanceFields.AS_OF, asOf);
        for (ObjectNode account : FinancialProjection.rows(source, FinanceFields.ACCOUNTS)) {
            account.put(FinanceFields.AS_OF, asOf);
        }
        for (String group : List.of(
            FinanceFields.TRANSACTIONS,
            FinanceFields.RELATED_TRANSACTIONS
        )) {
            for (ObjectNode transaction : FinancialProjection.rows(source, group)) {
                transaction.putNull(FinanceFields.OCCURRED_AT);
                transaction.putNull(FinanceFields.OCCURRED_AT_BASIS);
            }
        }
        for (ObjectNode statement : FinancialProjection.rows(source, FinanceFields.STATEMENTS)) {
            statement.put(FinanceFields.DUE_DATE, "2026-11-30");
        }
        for (ObjectNode reserve : FinancialProjection.rows(source, FinanceFields.RESERVES)) {
            reserve.put(FinanceFields.CANCELLED_AT, "2026-11-30T12:00:00+09:00");
        }
        ObjectNode before = source.deepCopy();
        assertDoesNotThrow(() -> FinancialShape.validate(source));
        assertEquals(before, source);
        assertEquals(18, OffsetDateTime.parse(asOf)
            .withOffsetSameInstant(ZoneOffset.UTC).getDayOfMonth());
    }

    /**
     * 승인된 10월 19일 자료를 읽으며 모든 테스트가 독립 복사본을 사용한다.
     * @created 2026-11-02
     * @usedBy 각 갱신 경계 테스트
     */
    private ObjectNode source(String directory) throws Exception {
        Path path = Path.of("fixtures", directory, "snapshots", "demo-ready.json");
        ObjectNode source = (ObjectNode) JsonMapper.builder().build()
            .readTree(Files.readString(path));
        assertEquals("2026-10-19T12:00:00+09:00", source.path(FinanceFields.AS_OF).asString());
        return source;
    }
}
