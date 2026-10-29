package com.payse.api.finance.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 준비 원천과 실제 v3 투영의 페이지·미연결·근거 보존 계약을 검증한다.
 * @created 2026-10-29
 * @usedBy Gradle JUnit
 */
class FinancialProjectionTest {
    private final FinancialProjection projection = new FinancialProjection();
    private final JsonMapper mapper = JsonMapper.builder().build();

    /**
     * 모든 유효 v3 준비 원천의 거래를 중복·누락 없이 100건씩 전달한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void preparedSourcesPageWithoutChangingFacts() throws Exception {
        List<Path> files;
        try (var paths = Files.list(Path.of("fixtures/generated/snapshots"))) {
            files = paths.filter(path -> path.toString().endsWith(".json"))
                .filter(path -> !Set.of("alpha-unconnected.json", "refund-unavailable-original.json")
                    .contains(path.getFileName().toString())).toList();
        }
        assertFalse(files.isEmpty());
        for (Path path : files) {
            ObjectNode source = (ObjectNode) mapper.readTree(Files.readString(path));
            ObjectNode before = source.deepCopy();
            List<String> expected = ids(source.get("transactions"));
            expected.sort(String::compareTo);
            List<String> actual = readAll(source, codes(source));
            assertEquals(expected, actual, path.getFileName().toString());
            assertEquals(before, source);
        }
    }

    /**
     * 연결 전 열 개 키만 제공하고 원천 계좌 선택·급여·잔액을 응답에 덧붙이지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void unconnectedHasOnlyContractKeys() throws Exception {
        ObjectNode source = source("demo-ready");
        var slice = projection.project(source, Set.of(), "5", null, false);
        assertEquals(Set.of("userId", "schemaVersion", "currency", "dataVersion", "sourceVersion", "ruleVersion",
            "asOf", "institutions", "institutionLinks", "coverage"), Set.copyOf(slice.body().propertyNames()));
        assertEquals("5", slice.body().get("dataVersion").asString());
        assertEquals(0, slice.body().get("institutionLinks").size());
        assertEquals(0, slice.body().get("coverage").size());
        assertFalse(slice.hasMore());
    }

    /**
     * 제공된 아홉 기관의 모든 부분 연결 조합에서 원천별 거래 공개와 숨긴 ID 비노출을 검사한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void everyConnectionCombinationRespectsSourceAuthority() throws Exception {
        ObjectNode source = source("demo-ready");
        List<String> institutions = new ArrayList<>(codes(source));
        assertEquals(9, institutions.size());
        Map<String, String> parentInstitutions = new HashMap<>();
        for (String group : List.of("accounts", "cards")) {
            for (JsonNode row : source.get(group)) {
                parentInstitutions.put(row.get(group.equals("accounts") ? "accountId" : "cardId").asString(),
                    row.get("institutionCode").asString());
            }
        }
        for (int mask = 1; mask < 1 << institutions.size(); mask++) {
            Set<String> selected = new HashSet<>();
            for (int index = 0; index < institutions.size(); index++) if ((mask & (1 << index)) != 0) selected.add(institutions.get(index));
            List<String> expected = new ArrayList<>();
            Set<String> hidden = new HashSet<>();
            for (JsonNode row : source.get("transactions")) {
                String primary = row.get("recordKind").asString().equals("account_entry") ? "accountId" : "cardId";
                if (selected.contains(parentInstitutions.get(row.get(primary).asString()))) expected.add(row.get("transactionId").asString());
                else hidden.add(row.get("transactionId").asString());
            }
            expected.sort(String::compareTo);
            var first = projection.project(source, selected, "1", null, false);
            for (String hiddenId : hidden) assertFalse(first.body().toString().contains(hiddenId));
            assertEquals(expected, readAll(source, selected), "connection mask " + mask);
        }
    }

    /**
     * Java의 signed UUID 비교가 아닌 정규 UUID 문자열 순서를 페이지 경계까지 유지한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void uuidOrderingAndPageBoundaryMatchPostgres() throws Exception {
        ObjectNode source = source("demo-ready");
        List<String> expected = ids(source.get("transactions"));
        assertTrue(expected.stream().anyMatch(value -> value.charAt(0) >= '8'));
        assertTrue(expected.stream().anyMatch(value -> value.charAt(0) < '8'));
        expected.sort(String::compareTo);
        var first = projection.project(source, codes(source), "1", null, false);
        assertEquals(expected.subList(0, 100), ids(first.body().get("transactions")));
        assertEquals(expected.get(99), first.lastId().toString());
        var second = projection.project(source, codes(source), "1", first.lastId(), true);
        assertEquals(expected.subList(100, 200), ids(second.body().get("transactions")));
    }

    /**
     * 다음 페이지의 청구 참조는 ID를 유지하고 relatedTransactions에 전량 복제하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void referencesToNextPageRemainIds() throws Exception {
        ObjectNode source = source("demo-ready");
        var first = projection.project(source, codes(source), "1", null, false);
        Set<String> pageIds = new HashSet<>(ids(first.body().get("transactions")));
        Set<String> related = new HashSet<>(ids(first.body().get("relatedTransactions")));
        int nextReferences = 0;
        for (JsonNode statement : first.body().get("statements")) {
            for (JsonNode reference : statement.get("includedTransactionRefs")) {
                if (!pageIds.contains(reference.asString())) {
                    nextReferences++;
                    assertFalse(related.contains(reference.asString()));
                }
            }
        }
        assertTrue(nextReferences > 0);
        assertEquals(0, first.body().get("referenceResolutions").size());
    }

    /**
     * 기간 밖 환불 원결제는 관계 근거로 보존하고 일반 거래 목록에 섞지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void outsideWindowOriginalRemainsRelated() throws Exception {
        ObjectNode source = source("refund-outside-window");
        Set<String> expectedRelated = new HashSet<>(ids(source.get("relatedTransactions")));
        assertFalse(expectedRelated.isEmpty());
        Set<String> seenRelated = new HashSet<>();
        var slice = projection.project(source, codes(source), "1", null, false);
        while (true) {
            seenRelated.addAll(ids(slice.body().get("relatedTransactions")));
            for (String transactionId : ids(slice.body().get("transactions"))) assertFalse(expectedRelated.contains(transactionId));
            if (!slice.hasMore()) break;
            slice = projection.project(source, codes(source), "1", slice.lastId(), true);
        }
        assertEquals(expectedRelated, seenRelated);
    }

    /**
     * 입금 전 미래 원천은 unknown과 빈 거래 목록 그대로 응답에 남는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void unknownFutureSalaryEvidenceIsPreserved() throws Exception {
        ObjectNode source = source("salary-schedule-provided");
        var body = projection.project(source, codes(source), "1", null, false).body();
        assertEquals(source.at("/settings/salary/receiptEvidence"), body.at("/settings/salary/receiptEvidence"));
        assertTrue(FinancialProjection.rows(body.at("/settings/salary"), "receiptEvidence").stream()
            .anyMatch(row -> row.get("confirmation").asString().equals("unknown") && row.get("transactionIds").isEmpty()));
    }

    /**
     * 숨겨진 은행의 카드 출금 참조는 null이 아닌 생략과 제한 표식으로 표현한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void hiddenWithdrawalAccountUsesOmission() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode card = unique(source, "cards", "institutionCode", "card.hyundai");
        assertFalse(card.get("withdrawalAccountId").isNull());
        String cardId = card.get("cardId").asString();
        String hiddenAccount = card.get("withdrawalAccountId").asString();
        var body = projection.project(source, Set.of(card.get("institutionCode").asString()), "1", null, false).body();
        ObjectNode actualCard = FinancialProjection.rows(body, "cards").stream()
            .filter(row -> row.get("cardId").asString().equals(cardId)).findFirst().orElseThrow();
        assertFalse(actualCard.has("withdrawalAccountId"));
        assertFalse(body.toString().contains(hiddenAccount));
        assertTrue(FinancialProjection.rows(body, "accessRestrictions").stream()
            .anyMatch(mark -> mark.get("ownerType").asString().equals("card")
                && mark.get("ownerId").asString().equals(cardId)
                && mark.get("field").asString().equals("withdrawalAccountId")));
    }

    /**
     * 미확보 원결제의 기관 권한을 모를 때 빈 값이나 가짜 관계 대신 계약의 503을 반환한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void missingOriginalWithoutAuthorityFailsClosed() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 내부 조회 결과에 다른 사용자 행이 섞이면 미연결 상태로 숨겨 통과시키지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void foreignOwnerIsRejectedBeforeProjection() throws Exception {
        ObjectNode source = source("demo-ready");
        String foreignOwner = source("beta-ready").get("userId").asString();
        unique(source, "accounts", "accountId", source.at("/settings/salary/salaryAccountId").asString()).put("userId", foreignOwner);
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 같은 ID의 상충 행을 마지막 값으로 덮어쓰지 않고 조회를 실패시킨다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void conflictingDuplicateTransactionFails() throws Exception {
        ObjectNode source = source("demo-ready");
        String salaryTransaction = source.at("/settings/salary/receiptEvidence/0/transactionIds/0").asString();
        assertEquals(1, source.at("/settings/salary/receiptEvidence").size());
        assertEquals(1, source.at("/settings/salary/receiptEvidence/0/transactionIds").size());
        ObjectNode duplicate = unique(source, "transactions", "transactionId", salaryTransaction).deepCopy();
        duplicate.put("description", "다른 원천 설명");
        ((ArrayNode) source.get("transactions")).add(duplicate);
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 내부 rawFragment 같은 미등록 필드를 공개 모델에 흘려보내지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void unregisteredPayloadFieldIsRejected() throws Exception {
        ObjectNode source = source("demo-ready");
        unique(source, "accounts", "accountId", source.at("/settings/salary/salaryAccountId").asString()).put("rawFragment", "private");
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * v4 원천을 v3라고 조용히 표시하거나 새 청구 항목을 구 응답으로 전달하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void v4RequiresSeparateActivation() throws Exception {
        ObjectNode source = source("demo-ready");
        source.put("schemaVersion", "PAYSE-DRAFT-4");
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 현재 원천 목록에 없는 페이지 경계는 정상 빈 페이지로 바꾸지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void cursorBoundaryMustExistInCurrentRange() throws Exception {
        ObjectNode source = source("demo-ready");
        UUID nonexistent = UUID.randomUUID();
        assertFalse(ids(source.get("transactions")).contains(nonexistent.toString()));
        var failure = assertThrows(FinancialException.class,
            () -> projection.project(source, codes(source), "1", nonexistent, true));
        assertEquals(400, failure.status());
        assertEquals("INVALID_CURSOR", failure.code());
    }

    /**
     * 후속 페이지는 설정·계좌·청구를 반복하거나 해당 부모 제한 표식을 단독 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void nextPageHasOnlyPageContractFields() throws Exception {
        ObjectNode source = source("demo-ready");
        var first = projection.project(source, codes(source), "1", null, false);
        var page = projection.project(source, codes(source), "1", first.lastId(), true).body();
        assertEquals(Set.of("userId", "schemaVersion", "currency", "dataVersion", "sourceVersion", "ruleVersion", "asOf",
            "transactions", "relatedTransactions", "referenceResolutions", "transactionRelations", "occurrenceLinks",
            "coverage", "page", "accessRestrictions"), Set.copyOf(page.propertyNames()));
        for (JsonNode mark : page.get("accessRestrictions")) {
            assertTrue(Set.of("response", "transaction").contains(mark.get("ownerType").asString()));
        }
    }

    /**
     * 동일 회차 연결은 JSON 키 순서가 달라도 계약의 식별 튜플로 한 번만 제공한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void occurrenceTupleIgnoresObjectKeyOrder() throws Exception {
        ObjectNode source = source("demo-ready");
        ArrayNode links = (ArrayNode) source.get("occurrenceLinks");
        assertFalse(links.isEmpty());
        ObjectNode original = (ObjectNode) links.get(0);
        ObjectNode duplicate = mapper.createObjectNode();
        List<String> fields = new ArrayList<>(original.propertyNames()).reversed();
        for (String field : fields) duplicate.set(field, original.get(field).deepCopy());
        int count = links.size();
        links.add(duplicate);
        assertEquals(count, projection.project(source, codes(source), "1", null, false).body().get("occurrenceLinks").size());
    }

    /**
     * 기간 밖 원거래가 순환 참조해도 각 보조 거래는 한 번만 제공하고 탐색을 종료한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void cyclicOutsideReferencesTerminateOncePerId() throws Exception {
        ObjectNode source = source("refund-outside-window");
        ArrayNode related = (ArrayNode) source.get("relatedTransactions");
        assertEquals(1, related.size());
        ObjectNode original = (ObjectNode) related.get(0);
        String originalId = original.get("transactionId").asString();
        ObjectNode additional = original.deepCopy();
        String newId = UUID.randomUUID().toString();
        additional.put("transactionId", newId).put("sourceRef", original.get("sourceRef").asString() + "/cycle")
            .put("originalTransactionId", originalId);
        original.put("originalTransactionId", newId);
        related.add(additional);
        Set<String> seen = new HashSet<>();
        var slice = projection.project(source, codes(source), "1", null, false);
        while (true) {
            List<String> ids = ids(slice.body().get("relatedTransactions"));
            assertEquals(new HashSet<>(ids).size(), ids.size());
            seen.addAll(ids);
            if (!slice.hasMore()) break;
            slice = projection.project(source, codes(source), "1", slice.lastId(), true);
        }
        assertEquals(Set.of(originalId, newId), seen);
    }

    /**
     * 저장 JSON의 문자열 슬롯에 임의 객체를 넣어 비밀 데이터를 우회 전달하지 못한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void nestedObjectInScalarSlotIsRejected() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode card = unique(source, "cards", "institutionCode", "card.hyundai");
        assertFalse(card.get("scheduleEvidence").isEmpty());
        ObjectNode evidence = (ObjectNode) card.get("scheduleEvidence").get(0);
        evidence.putObject("evidenceRef").put("secret", "not-a-reference");
        assertUnavailable(() -> projection.project(source, codes(source), "1", null, false));
    }

    /**
     * 테스트 원천은 파일 이름으로 명시 선택하고 사용자·참조 ID는 본문에서 확인해 전달한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest
     */
    private ObjectNode source(String name) throws Exception {
        return (ObjectNode) mapper.readTree(Files.readString(Path.of("fixtures/generated/snapshots", name + ".json")));
    }

    /**
     * 원천에 실제 제공된 기관 집합만 시험 연결 대상으로 사용한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest
     */
    private Set<String> codes(ObjectNode source) {
        Set<String> result = new LinkedHashSet<>();
        for (JsonNode institution : source.get("institutions")) result.add(institution.get("code").asString());
        return result;
    }

    /**
     * 거래 ID만 수집하여 표시명·고정 UUID에 의존하지 않고 페이지 관계를 검증한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest
     */
    private List<String> ids(JsonNode transactions) {
        List<String> result = new ArrayList<>();
        for (JsonNode transaction : transactions) result.add(transaction.get("transactionId").asString());
        return result;
    }

    /**
     * 명시 관계·기관 코드로 시험 대상을 정하고 단일 행임을 먼저 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest의 원천 변조 검증
     */
    private ObjectNode unique(ObjectNode source, String group, String field, String value) {
        List<ObjectNode> matches = FinancialProjection.rows(source, group).stream()
            .filter(row -> row.get(field).asString().equals(value)).toList();
        assertEquals(1, matches.size());
        return matches.getFirst();
    }

    /**
     * 응답 경계를 이어 읽고 같은 ID가 두 페이지에 나오거나 최대 크기를 넘으면 실패한다.
     * @created 2026-10-29
     * @usedBy preparedSourcesPageWithoutChangingFacts, everyConnectionCombinationRespectsSourceAuthority
     */
    private List<String> readAll(ObjectNode source, Set<String> codes) {
        List<String> actual = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        UUID after = null;
        while (true) {
            var slice = projection.project(source, codes, "1", after, after != null);
            List<String> pageIds = ids(slice.body().get("transactions"));
            assertTrue(pageIds.size() <= 100);
            for (String id : pageIds) assertTrue(seen.add(id));
            actual.addAll(pageIds);
            if (!slice.hasMore()) break;
            assertNotNull(slice.lastId());
            after = slice.lastId();
        }
        return actual;
    }

    /**
     * 처리할 수 없는 원천을 0원·빈 정상 응답 대신 공개 503으로 구분한다.
     * @created 2026-10-29
     * @usedBy FinancialProjectionTest의 실패 시나리오
     */
    private void assertUnavailable(Runnable operation) {
        var failure = assertThrows(FinancialException.class, operation::run);
        assertEquals(503, failure.status());
        assertEquals("TEMPORARILY_UNAVAILABLE", failure.code());
    }
}
