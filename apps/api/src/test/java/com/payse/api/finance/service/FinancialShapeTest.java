package com.payse.api.finance.service;

import com.payse.api.ApiTestConstants.FinanceCodes;
import com.payse.api.ApiTestConstants.FinanceFields;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * v4 청구 원천의 nullable·부호·관계·버전 경계를 확인한다. DB 제약과 공개 투영 검사를 대신하지 않는다.
 * @created 2026-10-30
 * @usedBy Gradle JUnit
 */
class FinancialShapeTest {
    private final JsonMapper mapper = JsonMapper.builder().build();

    /**
     * 기존 두 버전의 전체 금융 원천은 수정 없이 검사하며 연결 전 응답은 별도 계약으로 제외한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void preparedSourcesRemainUnchanged() throws Exception {
        for (String directory : List.of("generated", "generated-v4")) {
            List<Path> files;
            try (var paths = Files.list(Path.of("fixtures", directory, "snapshots"))) {
                files = paths.filter(path -> path.toString().endsWith(".json")).toList();
            }
            assertFalse(files.isEmpty());
            int checked = 0;
            for (Path file : files) {
                ObjectNode source = (ObjectNode) mapper.readTree(Files.readString(file));
                if (!source.has(FinanceFields.STATEMENTS)) {
                    continue;
                }
                ObjectNode before = source.deepCopy();
                assertDoesNotThrow(() -> FinancialShape.validate(source), file.toString());
                assertEquals(before, source);
                checked++;
            }
            assertTrue(checked > 0);
        }
    }

    /**
     * v3에 새 배열을 붙이거나 v4에서 배열을 누락한 자료를 버전 이름만으로 허용하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    @Test
    void versionRequiresItsOwnShape() throws Exception {
        ObjectNode source = source();
        source.put(FinanceFields.SCHEMA_VERSION, FinanceCodes.DRAFT_V3);
        rejects(source);
        source = source();
        for (ObjectNode statement : FinancialProjection.rows(source, FinanceFields.STATEMENTS)) {
            statement.remove(FinanceFields.ITEMS);
        }
        rejects(source);
        source.put(FinanceFields.SCHEMA_VERSION, "PAYSE-DRAFT-5");
        rejects(source);
    }

    /**
     * 음수는 조정·항목 청구액에만 허용하고 원금·원이용 금액을 음수로 확장하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 순회 대상 지역변수 분리
     */
    @Test
    void signedMoneyDoesNotExpandPrincipalRules() throws Exception {
        ObjectNode source = source();
        ObjectNode item = purchase(source);
        item.put(FinanceFields.FEE_OR_ADJUSTMENT_AMOUNT_KRW, -9_000_000_000_000L);
        item.put(FinanceFields.BILLED_AMOUNT_KRW, -9_000_000_000_000L);
        assertDoesNotThrow(() -> FinancialShape.validate(source));
        for (String key : List
            .of(FinanceFields.ORIGINAL_USED_AMOUNT_KRW, FinanceFields.BILLED_PRINCIPAL_KRW)) {
            ObjectNode invalid = source();
            purchase(invalid).put(key, -1);
            rejects(invalid);
        }
        var moneyFields = List.of(
            FinanceFields.ORIGINAL_USED_AMOUNT_KRW,
            FinanceFields.BILLED_PRINCIPAL_KRW,
            FinanceFields.FEE_OR_ADJUSTMENT_AMOUNT_KRW,
            FinanceFields.BILLED_AMOUNT_KRW
        );
        for (String key : moneyFields) {
            ObjectNode invalid = source();
            purchase(invalid).put(key, 9_000_000_000_001L);
            rejects(invalid);
            purchase(invalid).put(key, 1.5);
            rejects(invalid);
            purchase(invalid).put(key, "100");
            rejects(invalid);
        }
    }

    /**
     * 미상 필드와 원금·조정·청구 총액의 차이를 임의 산출이나 0으로 덮어쓰지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void nullsAndUnreconciledAmountsRemainFacts() throws Exception {
        ObjectNode source = source();
        ObjectNode item = purchase(source);
        item.putNull(FinanceFields.LABEL);
        item.putNull(FinanceFields.MERCHANT_NAME);
        item.putNull(FinanceFields.PURCHASE_DATE);
        item.putNull(FinanceFields.ORIGINAL_USED_AMOUNT_KRW);
        item.putNull(FinanceFields.INSTALLMENT_ROUND);
        item.put(FinanceFields.BILLED_PRINCIPAL_KRW, 1);
        item.put(FinanceFields.FEE_OR_ADJUSTMENT_AMOUNT_KRW, 2);
        item.put(FinanceFields.BILLED_AMOUNT_KRW, 17);
        ObjectNode before = source.deepCopy();
        assertDoesNotThrow(() -> FinancialShape.validate(source));
        assertEquals(before, source);
    }

    /**
     * 할부는 각각 nullable 양수 int32이며 두 값이 있을 때만 회차 순서를 검사한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void installmentCountsRespectStorageBounds() throws Exception {
        for (String key : List
            .of(FinanceFields.INSTALLMENT_MONTHS, FinanceFields.INSTALLMENT_ROUND)) {
            for (long value : new long[] {
                0,
                -1,
                2_147_483_648L
            }) {
                ObjectNode source = source();
                purchase(source).put(key, value);
                rejects(source);
            }
        }
        ObjectNode source = source();
        purchase(source).put(FinanceFields.INSTALLMENT_ROUND, 7);
        purchase(source).put(FinanceFields.INSTALLMENT_MONTHS, 6);
        rejects(source);
    }

    /**
     * 항목 소유자·원천 버전·연결 거래는 실제 부모와 같은 사용자·카드 관계여야 한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void ownerVersionAndTransactionMustMatch() throws Exception {
        for (String field : List.of(
            FinanceFields.USER_ID,
            FinanceFields.SOURCE_VERSION,
            FinanceFields.TRANSACTION_ID
        )) {
            ObjectNode source = source();
            purchase(source).put(field, UUID.randomUUID().toString());
            rejects(source);
        }
        ObjectNode source = source();
        String transactionId = purchase(source)
            .path(FinanceFields.TRANSACTION_ID)
            .asString();
        List<ObjectNode> matches = FinancialProjection.rows(source, FinanceFields.TRANSACTIONS)
            .stream()
            .filter(
                row -> row.path(FinanceFields.TRANSACTION_ID)
                    .asString()
                    .equals(transactionId)
            )
            .toList();
        assertEquals(1, matches.size());
        matches.getFirst().put(FinanceFields.CARD_ID, UUID.randomUUID().toString());
        rejects(source);
    }

    /**
     * 같은 거래의 여러 항목은 허용하지만 항목 ID·원천 키 중복은 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void repeatedTransactionDoesNotPermitDuplicateItemIdentity() throws Exception {
        ObjectNode source = source();
        ObjectNode original = purchase(source);
        ObjectNode added = original.deepCopy();
        added.put(FinanceFields.ITEM_ID, UUID.randomUUID().toString());
        added.put(
            FinanceFields.SOURCE_REF,
            original.path(FinanceFields.SOURCE_REF).asString() + "/adjustment"
        );
        ArrayNode items = (ArrayNode) parent(source, original).get(FinanceFields.ITEMS);
        items.add(added);
        assertDoesNotThrow(() -> FinancialShape.validate(source));
        added.put(FinanceFields.ITEM_ID, original.path(FinanceFields.ITEM_ID).asString());
        rejects(source);
        added.put(FinanceFields.ITEM_ID, UUID.randomUUID().toString());
        added.put(FinanceFields.SOURCE_REF, original.path(FinanceFields.SOURCE_REF).asString());
        rejects(source);
    }

    /**
     * 참조 배열을 독립 목록으로 취급하지 않고 항목에서 파생한 순서·중복 제거 결과와 비교한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void referencesMustBeDerivedFromItems() throws Exception {
        ObjectNode source = source();
        ObjectNode item = purchase(source);
        ArrayNode refs = (ArrayNode) parent(source, item)
            .get(FinanceFields.INCLUDED_TRANSACTION_REFS);
        refs.add(item.path(FinanceFields.TRANSACTION_ID).asString());
        rejects(source);
        refs.removeAll();
        rejects(source);
    }

    /**
     * 날짜만 있는 이용일은 실재 날짜이며 조회 기준의 한국 날짜 이후가 아니어야 한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void purchaseDateIsValidatedWithoutInventingTime() throws Exception {
        for (String date : List.of(
            "2026-02-30",
            "2026-1-01",
            "0000-01-01",
            "9999-12-31"
        )) {
            ObjectNode source = source();
            purchase(source).put(FinanceFields.PURCHASE_DATE, date);
            rejects(source);
        }
    }

    /**
     * 임의 항목 필드·누락·스칼라 자리에 객체를 넣는 응답 누출 경로를 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsUnknownOrMalformedItemFields() throws Exception {
        ObjectNode source = source();
        purchase(source).put("secret", "not-public");
        rejects(source);
        purchase(source).remove("secret");
        purchase(source).remove(FinanceFields.TRANSACTION_ID);
        rejects(source);
        source = source();
        purchase(source)
            .putObject(FinanceFields.LABEL)
            .put("hidden", true);
        rejects(source);
    }

    /**
     * 계약 검증된 원천 사례를 읽고 테스트가 원본 파일을 바꾸지 않도록 별도 객체로 준비한다.
     * @created 2026-10-30
     * @usedBy 모든 테스트
     */
    private ObjectNode source() throws Exception {
        return (ObjectNode) mapper.readTree(
            Files.readString(Path.of("fixtures/generated-v4/snapshots/alpha-billing-items.json"))
        );
    }

    /**
     * 안정된 원천 참조로 한 구매 항목을 확정하며 표시명·배열 순서로 대상을 고르지 않는다.
     * @created 2026-10-30
     * @usedBy 변조 테스트
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode purchase(ObjectNode source) {
        List<ObjectNode> matches = new ArrayList<>();
        for (ObjectNode statement : FinancialProjection.rows(source, FinanceFields.STATEMENTS)) {
            for (ObjectNode item : FinancialProjection.rows(statement, FinanceFields.ITEMS)) {
                if (item.path(FinanceFields.SOURCE_REF)
                    .asString()
                    .equals("fixture/alpha/billing-example/bill-2/purchase")) {
                    matches.add(item);
                }
            }
        }
        assertEquals(1, matches.size());
        return matches.getFirst();
    }

    /**
     * 대상 항목 ID를 포함한 부모 한 건을 확인하여 관계 변조 테스트에 사용한다.
     * @created 2026-10-30
     * @usedBy repeatedTransactionDoesNotPermitDuplicateItemIdentity,
     * referencesMustBeDerivedFromItems
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode parent(ObjectNode source, ObjectNode item) {
        String target = item.path(FinanceFields.ITEM_ID).asString();
        List<ObjectNode> matches = FinancialProjection.rows(source, FinanceFields.STATEMENTS)
            .stream()
            .filter(
                row -> FinancialProjection.rows(row, FinanceFields.ITEMS)
                    .stream()
                    .anyMatch(
                        child -> child.path(FinanceFields.ITEM_ID)
                            .asString()
                            .equals(target)
                    )
            )
            .toList();
        assertEquals(1, matches.size());
        return matches.getFirst();
    }

    /**
     * 원천 오류를 정상 응답으로 보정하지 않고 검사 실패로 남기는지 확인한다.
     * @created 2026-10-30
     * @usedBy 거절 테스트
     */
    private void rejects(ObjectNode source) {
        assertThrows(RuntimeException.class, () -> FinancialShape.validate(source));
    }
}
