package com.payse.api.finance.service;

import static org.junit.jupiter.api.Assertions.assertDoesNotThrow;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.List;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 금융 조회 투영 전에 계좌 상태를 제한하고 카드 상태·원천 값을 보존한다.
 * @created 2026-10-30
 * @usedBy Gradle JUnit
 */
class AccountStatusTest {
    private final JsonMapper mapper = JsonMapper.builder().build();

    /**
     * 계좌 확정·미확인은 기존 반영 상태와 원천 값을 수정하지 않고 허용한다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void supportedAccountStates() throws Exception {
        for (String status : List.of("posted", "unknown")) {
            ObjectNode source = source();
            List<ObjectNode> rows = accounts(source);
            assertFalse(rows.isEmpty());
            for (ObjectNode row : rows) row.put("status", status);
            ObjectNode before = source.deepCopy();
            assertDoesNotThrow(() -> FinancialShape.validate(source));
            assertEquals(before, source);
        }
    }

    /**
     * 계좌 승인·취소는 원천 오류로 거절하며 숫자·null 상태도 묵시 변환하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void unsupportedAccountStates() throws Exception {
        for (String status : List.of("approved", "cancelled", "POSTED", "")) {
            ObjectNode source = source();
            for (ObjectNode row : accounts(source)) row.put("status", status);
            reject(source);
        }
        ObjectNode numeric = source();
        for (ObjectNode row : accounts(numeric)) row.put("status", 1);
        reject(numeric);
        ObjectNode missing = source();
        for (ObjectNode row : accounts(missing)) row.putNull("status");
        reject(missing);
    }

    /**
     * 관계 자료의 계좌 상태도 본 거래 배열과 같은 기준으로 검사한다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void relatedEntriesCannotBypassValidation() throws Exception {
        ObjectNode source = source();
        for (ObjectNode row : accounts(source)) {
            ObjectNode related = row.deepCopy();
            related.put("status", "cancelled");
            source.withArray("relatedTransactions").add(related);
        }
        reject(source);
    }

    /**
     * 카드 종류별 기존 상태 허용 범위를 계좌 제한 때문에 바꾸지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void cardStatesRemainSupported() throws Exception {
        for (String status : List.of("approved", "posted", "cancelled", "unknown")) {
            ObjectNode source = source();
            List<ObjectNode> cards = FinancialProjection.rows(source, "transactions").stream()
                .filter(row -> !row.get("recordKind").asString().equals("account_entry")).toList();
            assertFalse(cards.isEmpty());
            for (ObjectNode row : cards) row.put("status", status);
            ObjectNode before = source.deepCopy();
            assertDoesNotThrow(() -> FinancialShape.validate(source));
            assertEquals(before, source);
        }
    }

    /**
     * 실제 준비 원천을 읽되 테스트에서만 복사해 제품 fixture를 변경하지 않는다.
     * @created 2026-10-30
     * @usedBy AccountStatusTest의 상태 검사
     */
    private ObjectNode source() throws Exception {
        return (ObjectNode) mapper.readTree(Files.readString(Path.of("fixtures/generated/snapshots/alpha-ready.json")));
    }

    /**
     * 표시명·고정 ID·배열 순서 대신 사건 종류로 은행 거래 집합을 고른다.
     * @created 2026-10-30
     * @usedBy AccountStatusTest의 계좌 검사
     */
    private List<ObjectNode> accounts(ObjectNode source) {
        return FinancialProjection.rows(source, "transactions").stream()
            .filter(row -> row.get("recordKind").asString().equals("account_entry")).toList();
    }

    /**
     * 거절을 기존 금융 원천 오류로 반환하고 입력 객체는 보존하는지 검사한다.
     * @created 2026-10-30
     * @usedBy AccountStatusTest의 오류 검사
     */
    private void reject(ObjectNode source) {
        ObjectNode before = source.deepCopy();
        FinancialException error = assertThrows(FinancialException.class, () -> FinancialShape.validate(source));
        assertEquals(503, error.status());
        assertEquals("TEMPORARILY_UNAVAILABLE", error.code());
        assertEquals(before, source);
    }
}
