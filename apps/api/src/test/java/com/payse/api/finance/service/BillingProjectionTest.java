package com.payse.api.finance.service;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * v4 청구 항목의 원천 보존·공개 권한·페이지 경계와 v3 병행 제공을 검사한다.
 * @created 2026-10-30
 * @usedBy Gradle JUnit
 */
class BillingProjectionTest {
    private final FinancialProjection projection = new FinancialProjection();
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 유효 v4 사례 전체에서 청구 원천과 거래 페이지가 누락·변형되지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void preparedV4SourcesRemainUnchanged() throws Exception {
        List<Path> files;
        try (var paths = Files.list(Path.of("fixtures/generated-v4/snapshots"))) {
            files = paths.filter(path -> path.toString().endsWith(".json"))
                .filter(path -> !Set.of("alpha-unconnected.json", "refund-unavailable-original.json")
                    .contains(path.getFileName().toString())).toList();
        }
        assertFalse(files.isEmpty());
        for (Path path : files) {
            ObjectNode source = (ObjectNode) json.readTree(Files.readString(path));
            ObjectNode before = source.deepCopy();
            var slice = projection.project(source, codes(source), "1", null, false);
            assertEquals("PAYSE-API-0.6-4", slice.body().path("schemaVersion").asString());
            assertEquals(source.get("statements"), slice.body().get("statements"), path.toString());
            List<String> expected = ids(source.get("transactions"));
            expected.sort(String::compareTo);
            List<String> actual = new ArrayList<>();
            while (true) {
                actual.addAll(ids(slice.body().get("transactions")));
                if (!slice.hasMore()) break;
                slice = projection.project(source, codes(source), "1", slice.lastId(), true);
                assertEquals("PAYSE-API-0.6-4", slice.body().path("schemaVersion").asString());
            }
            assertEquals(expected, actual, path.toString());
            assertEquals(before, source);
        }
    }

    /**
     * 할인·환급 음수와 미확인 null·연회비 무연결을 보존하고 기존 계산 자료를 바꾸지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void signedAndNullableDetailsDoNotChangeOtherFacts() throws Exception {
        ObjectNode source = source("alpha-billing-items");
        ObjectNode before = source.deepCopy();
        ObjectNode v4 = projection.project(source, codes(source), "1", null, false).body();
        List<ObjectNode> items = items(v4);
        assertTrue(items.stream().anyMatch(item -> item.path("feeOrAdjustmentAmountKRW").isNumber()
            && item.path("feeOrAdjustmentAmountKRW").asLong() < 0));
        assertTrue(items.stream().anyMatch(item -> item.path("billedAmountKRW").isNumber()
            && item.path("billedAmountKRW").asLong() < 0));
        assertTrue(items.stream().anyMatch(item -> item.get("transactionId").isNull()
            && item.path("billedAmountKRW").asLong(0) > 0));
        assertTrue(items.stream().anyMatch(item -> item.get("billedAmountKRW").isNull()));
        assertEquals(source.get("statements"), v4.get("statements"));
        ObjectNode legacy = source.deepCopy().put("schemaVersion", "PAYSE-DRAFT-3");
        FinancialProjection.rows(legacy, "statements").forEach(row -> row.remove("items"));
        ObjectNode v3 = projection.project(legacy, codes(legacy), "1", null, false).body();
        ObjectNode comparable = v4.deepCopy().put("schemaVersion", "PAYSE-API-0.6-3");
        FinancialProjection.rows(comparable, "statements").forEach(row -> row.remove("items"));
        assertEquals(v3, comparable);
        assertEquals(before, source);
    }

    /**
     * 공개 청구가 미연결 은행 거래를 참조하면 키만 숨기고 항목·부모 제한을 정확히 남긴다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void hiddenItemLinkHasExplicitRestrictions() throws Exception {
        ObjectNode source = bankLinkedItem();
        ObjectNode statement = installmentStatement(source);
        ObjectNode item = installmentItem(statement);
        String hidden = item.path("transactionId").asString();
        String cardCode = unique(source, "cards", "cardId", statement.path("cardId").asString())
            .path("institutionCode").asString();
        ObjectNode before = source.deepCopy();
        ObjectNode body = projection.project(source, Set.of(cardCode), "1", null, false).body();
        ObjectNode publicStatement = unique(body, "statements", "statementId", statement.path("statementId").asString());
        ObjectNode publicItem = installmentItem(publicStatement);
        assertFalse(publicItem.has("transactionId"));
        assertEquals(0, publicStatement.path("includedTransactionRefs").size());
        assertEquals(3, FinancialProjection.rows(publicStatement, "items").stream()
            .filter(row -> row.has("transactionId") && row.get("transactionId").isNull()).count());
        assertEquals(1, marks(body, "statementItem", item.path("itemId").asString(), "transactionId"));
        assertEquals(1, marks(body, "statement", statement.path("statementId").asString(), "includedTransactionRefs"));
        assertFalse(body.toString().contains(hidden));
        assertEquals(before, source);
    }

    /**
     * 숨김 거래·청구 항목 ID를 공개 원천 참조에 넣으면 문자열을 고치지 않고 거절한다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void hiddenIdsCannotLeakThroughSourceRefs() throws Exception {
        ObjectNode source = bankLinkedItem();
        ObjectNode statement = installmentStatement(source);
        ObjectNode item = installmentItem(statement);
        String cardCode = unique(source, "cards", "cardId", statement.path("cardId").asString())
            .path("institutionCode").asString();
        item.put("sourceRef", "test-reference/" + item.path("transactionId").asString());
        assertUnavailable(() -> projection.project(source, Set.of(cardCode), "1", null, false));

        ObjectNode hiddenStatements = source("alpha-billing-items");
        ObjectNode account = unique(hiddenStatements, "accounts", "accountId",
            hiddenStatements.at("/settings/salary/salaryAccountId").asString());
        String hiddenItemId = installmentItem(installmentStatement(hiddenStatements)).path("itemId").asString();
        account.put("sourceRef", "test-reference/" + hiddenItemId);
        assertUnavailable(() -> projection.project(hiddenStatements,
            Set.of(account.path("institutionCode").asString()), "1", null, false));
    }

    /**
     * 다음 페이지의 거래는 항목 연결을 유지하고 관계 거래나 미확보 참조로 복제하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void nextPageItemReferencesRemainPublic() throws Exception {
        ObjectNode source = source("alpha-billing-items");
        var first = projection.project(source, codes(source), "1", null, false);
        Set<String> page = new HashSet<>(ids(first.body().get("transactions")));
        Set<String> related = new HashSet<>(ids(first.body().get("relatedTransactions")));
        int deferred = 0;
        for (ObjectNode item : items(first.body())) {
            if (item.get("transactionId").isNull()) continue;
            String reference = item.path("transactionId").asString();
            if (!page.contains(reference)) {
                deferred++;
                assertFalse(related.contains(reference));
                assertEquals(0, marks(first.body(), "statementItem", item.path("itemId").asString(), "transactionId"));
            }
        }
        assertTrue(deferred > 0);
        assertEquals(0, first.body().get("referenceResolutions").size());
        var second = projection.project(source, codes(source), "1", first.lastId(), true).body();
        assertFalse(second.has("statements"));
        assertTrue(FinancialProjection.rows(second, "accessRestrictions").stream()
            .allMatch(mark -> Set.of("response", "transaction").contains(mark.path("ownerType").asString())));
    }

    /**
     * 같은 구매의 여러 청구 항목은 모두 보존하되 부모의 파생 참조는 한 번만 제공한다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void repeatedPurchaseKeepsItemsAndDeduplicatesReferences() throws Exception {
        ObjectNode source = source("alpha-billing-items");
        ObjectNode statement = installmentStatement(source);
        ObjectNode extra = installmentItem(statement).deepCopy();
        String itemId = UUID.randomUUID().toString();
        extra.put("itemId", itemId).put("sourceRef", "test-item/" + itemId);
        ((ArrayNode) statement.get("items")).add(extra);
        ObjectNode body = projection.project(source, codes(source), "1", null, false).body();
        ObjectNode actual = unique(body, "statements", "statementId", statement.path("statementId").asString());
        assertEquals(5, actual.path("items").size());
        assertEquals(1, actual.path("includedTransactionRefs").size());
        assertEquals(statement, actual);
    }

    /**
     * 연결 전에는 v4라도 금융 배열이나 청구 항목을 제공하지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void unconnectedV4HasOnlyHeader() throws Exception {
        ObjectNode body = projection.project(source("alpha-billing-items"), Set.of(), "1", null, false).body();
        assertEquals("PAYSE-API-0.6-4", body.path("schemaVersion").asString());
        assertEquals(Set.of("userId", "schemaVersion", "currency", "dataVersion", "sourceVersion", "ruleVersion",
            "asOf", "institutions", "institutionLinks", "coverage"), Set.copyOf(body.propertyNames()));
    }

    /**
     * 미확보 거래에 연결된 항목은 미연결 표식을 만들어 정상 응답으로 숨기지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void unknownItemAuthorityFailsClosed() throws Exception {
        ObjectNode source = source("alpha-billing-items");
        ObjectNode statement = installmentStatement(source);
        String absent = UUID.randomUUID().toString();
        assertFalse(ids(source.get("transactions")).contains(absent));
        installmentItem(statement).put("transactionId", absent);
        statement.putArray("includedTransactionRefs").add(absent);
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 명시 사례 파일만 읽으며 준비 자료의 표시명·고정 ID를 시험 선택 기준으로 쓰지 않는다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private ObjectNode source(String name) throws Exception {
        return (ObjectNode) json.readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots", name + ".json")));
    }

    /**
     * 정산 관계로 확인한 계좌 출금을 같은 카드의 청구 항목에 연결해 부분 권한 사례를 만든다.
     * @created 2026-10-30
     * @usedBy hiddenItemLinkHasExplicitRestrictions, hiddenIdsCannotLeakThroughSourceRefs
     */
    private ObjectNode bankLinkedItem() throws Exception {
        ObjectNode source = source("alpha-billing-items");
        List<ObjectNode> settlements = FinancialProjection.rows(source, "settlements");
        assertEquals(1, settlements.size());
        ObjectNode settlement = settlements.getFirst();
        ObjectNode payment = unique(source, "transactions", "transactionId", settlement.path("transactionId").asString());
        assertEquals("account_entry", payment.path("recordKind").asString());
        ObjectNode statement = installmentStatement(source);
        payment.put("cardId", statement.path("cardId").asString());
        installmentItem(statement).put("transactionId", payment.path("transactionId").asString());
        statement.putArray("includedTransactionRefs").add(payment.path("transactionId").asString());
        return source;
    }

    /**
     * 6개월 중 2회차 근거가 있는 단일 항목을 검증하고 그 청구서를 찾는다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private ObjectNode installmentStatement(ObjectNode source) {
        List<ObjectNode> matches = FinancialProjection.rows(source, "statements").stream()
            .filter(statement -> FinancialProjection.rows(statement, "items").stream()
                .anyMatch(item -> item.path("installmentRound").asInt(0) == 2
                    && item.path("installmentMonths").asInt(0) == 6)).toList();
        assertEquals(1, matches.size());
        return matches.getFirst();
    }

    /**
     * 청구서 내부의 2/6회차 항목이 정확히 하나임을 확인한다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private ObjectNode installmentItem(ObjectNode statement) {
        List<ObjectNode> matches = FinancialProjection.rows(statement, "items").stream()
            .filter(item -> item.path("installmentRound").asInt(0) == 2
                && item.path("installmentMonths").asInt(0) == 6).toList();
        assertEquals(1, matches.size());
        return matches.getFirst();
    }

    /**
     * 소유 자원·관계 ID를 원천에서 읽고 조회 결과의 단일성을 확인한다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private ObjectNode unique(ObjectNode source, String group, String key, String value) {
        List<ObjectNode> matches = FinancialProjection.rows(source, group).stream()
            .filter(row -> row.path(key).asString().equals(value)).toList();
        assertEquals(1, matches.size());
        return matches.getFirst();
    }

    /**
     * 공개 항목만 모아 금액·연결·제한 표식에 대한 독립적인 기대를 검사한다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private List<ObjectNode> items(ObjectNode source) {
        List<ObjectNode> result = new ArrayList<>();
        for (ObjectNode statement : FinancialProjection.rows(source, "statements")) {
            result.addAll(FinancialProjection.rows(statement, "items"));
        }
        return result;
    }

    /**
     * 지정 공개 위치의 제한 표식 개수를 세어 누락·중복을 검사한다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private long marks(ObjectNode body, String ownerType, String ownerId, String field) {
        return FinancialProjection.rows(body, "accessRestrictions").stream()
            .filter(mark -> mark.path("ownerType").asString().equals(ownerType)
                && mark.path("ownerId").asString().equals(ownerId)
                && mark.path("field").asString().equals(field)
                && mark.path("targetKind").asString().equals("transaction")
                && mark.path("reason").asString().equals("not_connected")).count();
    }

    /**
     * 원천이 실제 제공한 기관만 연결하며 임의 기관을 추가하지 않는다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private Set<String> codes(ObjectNode source) {
        Set<String> result = new LinkedHashSet<>();
        for (JsonNode institution : source.get("institutions")) result.add(institution.path("code").asString());
        return result;
    }

    /**
     * 거래 ID를 모아 페이지 순서·중복·누락을 명시 기대 목록과 대조한다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private List<String> ids(JsonNode transactions) {
        List<String> result = new ArrayList<>();
        for (JsonNode transaction : transactions) result.add(transaction.path("transactionId").asString());
        return result;
    }

    /**
     * 권한 원천 부족은 정상 빈 결과가 아닌 계약의 안전한 503으로 처리한다.
     * @created 2026-10-30
     * @usedBy BillingProjectionTest
     */
    private void assertUnavailable(Runnable operation) {
        var failure = assertThrows(FinancialException.class, operation::run);
        assertEquals(503, failure.status());
        assertEquals("TEMPORARILY_UNAVAILABLE", failure.code());
    }
}
