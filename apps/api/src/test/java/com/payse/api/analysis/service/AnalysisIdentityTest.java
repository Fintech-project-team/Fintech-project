package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;
import java.util.function.Predicate;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 fixture의 ID·명시 관계를 읽어 기억 식별과 재사용 지문의 경계를 검증한다.
 * @created 2026-11-01
 * @usedBy Gradle JUnit
 */
class AnalysisIdentityTest {
    private final AnalysisIdentity identity = new AnalysisIdentity();
    private static final List<String> FIELDS = List.of("transactionId", "recordKind", "direction", "status",
        "reflectionReason", "merchantName", "description", "originalTransactionId");

    /**
     * 임시 항목 이름을 바꿔도 기억·근거·입력 지문은 같고 원래 자료를 수정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void ignoresItemKeyAndPreservesInput() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode beforeSource = source.deepCopy();
        ObjectNode input = input(source, List.of(salary(source, "2026-06")));
        ObjectNode beforeInput = input.deepCopy();
        var original = identity.items(input).getFirst();
        ObjectNode renamed = input.deepCopy();
        ((ObjectNode) renamed.get("items").get(0)).put("itemKey", "another-request-item");
        var changed = identity.items(renamed).getFirst();
        assertNotEquals(original.itemKey(), changed.itemKey());
        assertEquals(original.key(), changed.key());
        assertEquals(original.evidenceHash(), changed.evidenceHash());
        assertEquals(identity.hint(input), identity.hint(renamed));
        assertEquals(identity.inputHash(input, versions()), identity.inputHash(renamed, versions()));
        assertEquals(beforeInput, input);
        assertEquals(beforeSource, source);
    }

    /**
     * 항목·거래·관계·분류와 근거 집합의 순서를 바꿔도 동일 지문을 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void normalizesSetOrdering() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        ObjectNode input = input(source, related(source, relation));
        for (JsonNode item : input.get("items")) {
            ArrayNode refs = ((ObjectNode) item).putArray("evidenceTransactionIds");
            input.get("transactions").forEach(row -> refs.add(row.get("transactionId")));
        }
        ObjectNode changed = input.deepCopy();
        for (String field : List.of("items", "transactions", "relations", "currentClassifications")) reverse(changed, field);
        for (JsonNode item : changed.get("items")) reverse((ObjectNode) item, "evidenceTransactionIds");
        assertEquals(identity.hint(input), identity.hint(changed));
        assertEquals(identity.inputHash(input, versions()), identity.inputHash(changed, versions()));
    }

    /**
     * 같은 거래를 두 임시 항목으로 나누어도 중복 기억으로 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsRepeatedTargets() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source, "2026-06")));
        ObjectNode duplicate = ((ObjectNode) input.get("items").get(0)).deepCopy().put("itemKey", "duplicate-target");
        input.withArray("items").add(duplicate);
        FinancialException failure = assertThrows(FinancialException.class, () -> identity.items(input));
        assertEquals(422, failure.status());
        assertEquals("VALIDATION_FAILED", failure.code());
    }

    /**
     * 직접 근거 밖의 원거래 내용·기존 분류 변경도 취소 항목의 근거 변경으로 식별한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void includesOriginalFactsAndClassification() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode cancelled = unique(source.get("transactions"), row -> "card_cancellation".equals(row.path("recordKind").asString()));
        String originalId = cancelled.get("originalTransactionId").asString();
        ObjectNode original = row(source, "transactions", "transactionId", originalId);
        ObjectNode input = input(source, List.of(cancelled, original));
        String key = itemKey(cancelled);
        var before = selected(input, key);
        ObjectNode changed = input.deepCopy();
        row(changed, "transactions", "transactionId", originalId).put("description", "변경된 원거래 적요");
        assertEquals(before.key(), selected(changed, key).key());
        assertNotEquals(before.evidenceHash(), selected(changed, key).evidenceHash());
        changed = input.deepCopy();
        ObjectNode classification = optional(changed.get("currentClassifications"), value -> originalId.equals(value.path("transactionId").asString()));
        if (classification == null) changed.withArray("currentClassifications").addObject().put("transactionId", originalId).put("value", "expense");
        else classification.putNull("value");
        assertNotEquals(before.evidenceHash(), selected(changed, key).evidenceHash());
    }

    /**
     * 실제 명시 이체 관계 반대쪽이 별도 항목이어도 그 내용 변경을 놓치지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void includesRelatedEndpointFacts() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        ObjectNode input = input(source, related(source, relation));
        String key = "transaction:" + relation.get("fromId").asString();
        var before = selected(input, key);
        ObjectNode changed = input.deepCopy();
        row(changed, "transactions", "transactionId", relation.get("toId").asString()).put("description", "변경된 이체 반대편 적요");
        assertEquals(before.key(), selected(changed, key).key());
        assertNotEquals(before.evidenceHash(), selected(changed, key).evidenceHash());
    }

    /**
     * 실제 미확보 원거래의 사유 변경은 같은 환불 기억의 근거 변경으로 기록한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void includesUnavailableReason() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        ObjectNode resolution = unique(source.get("referenceResolutions"), ignored -> true);
        ObjectNode refund = unique(source.get("transactions"), row -> resolution.get("transactionId").equals(row.get("originalTransactionId")));
        ObjectNode input = input(source, List.of(refund));
        assertEquals(1, input.get("unavailableReferences").size());
        var before = identity.items(input).getFirst();
        ObjectNode changed = input.deepCopy();
        ((ObjectNode) changed.get("unavailableReferences").get(0)).put("reason", "outside_retention");
        assertNotEquals(input.get("unavailableReferences"), changed.get("unavailableReferences"));
        assertEquals(before.key(), identity.items(changed).getFirst().key());
        assertNotEquals(before.evidenceHash(), identity.items(changed).getFirst().evidenceHash());
    }

    /**
     * 다른 독립 항목의 원천 변경은 해당 항목만 바꾸고 관련 없는 기억은 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void excludesUnrelatedFacts() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode first = salary(source, "2026-06"), other = salary(source, "2026-07");
        ObjectNode input = input(source, List.of(first, other));
        assertEquals(0, input.get("relations").size());
        ObjectNode changed = input.deepCopy();
        row(changed, "transactions", "transactionId", other.get("transactionId").asString()).put("description", "관련 없는 거래 변경");
        assertEquals(selected(input, itemKey(first)), selected(changed, itemKey(first)));
        assertNotEquals(selected(input, itemKey(other)).evidenceHash(), selected(changed, itemKey(other)).evidenceHash());
        assertNotEquals(identity.hint(input), identity.hint(changed));
    }

    /**
     * 화면 세대·입력 revision·전체 금융 버전만 달라지면 관련 의미 캐시를 무효화하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void ignoresUnrelatedContextChanges() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source, "2026-06")));
        ObjectNode changed = input.deepCopy();
        ((ObjectNode) changed.get("context")).put("dataVersion", "999").put("localSessionEpoch", 45).put("inputRevision", 80);
        assertEquals(identity.items(input), identity.items(changed));
        assertEquals(identity.hint(input), identity.hint(changed));
        assertEquals(identity.inputHash(input, versions()), identity.inputHash(changed, versions()));
    }

    /**
     * 규칙·입력 스키마와 공급자 버전 변경은 최종 캐시만 바꾸고 삭제용 기억·근거는 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void separatesVersionedCacheFromMemory() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source, "2026-06")));
        for (String field : List.of("ruleVersion", "schemaVersion", "contractVersion")) {
            ObjectNode changed = input.deepCopy();
            ObjectNode target = field.equals("contractVersion") ? changed : (ObjectNode) changed.get("context");
            target.put(field, target.get(field).asString() + "-changed");
            assertEquals(identity.items(input), identity.items(changed));
            assertEquals(identity.hint(input), identity.hint(changed));
            assertNotEquals(identity.inputHash(input, versions()), identity.inputHash(changed, versions()));
        }
        for (String field : List.of("model", "prompt", "response", "policy")) {
            ObjectNode changedVersions = versions();
            changedVersions.put(field, changedVersions.get(field).asString() + "-changed");
            assertNotEquals(identity.inputHash(input, versions()), identity.inputHash(input, changedVersions));
        }
    }

    /**
     * 반복 후보 임시 이름·월/근거 순서 변경은 기억을 바꾸지 않고 동일 근거의 중복 후보는 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void normalizesRecurringIdentity() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode input = recurring(source, List.of(salary(source, "2026-07"), salary(source, "2026-08"), salary(source, "2026-09")), "candidate-a");
        ObjectNode changed = input.deepCopy();
        ((ObjectNode) changed.get("items").get(0)).put("candidateKey", "candidate-renamed").put("itemKey", "renamed-item");
        ObjectNode candidate = (ObjectNode) changed.get("candidates").get(0);
        candidate.put("candidateKey", "candidate-renamed");
        reverse(candidate, "evidenceTransactionIds");
        reverse((ObjectNode) candidate.get("features"), "observedMonths");
        reverse((ObjectNode) changed.get("items").get(0), "evidenceTransactionIds");
        assertEquals(identity.items(input).getFirst().key(), identity.items(changed).getFirst().key());
        assertEquals(identity.items(input).getFirst().evidenceHash(), identity.items(changed).getFirst().evidenceHash());
        assertEquals(identity.hint(input), identity.hint(changed));
        ObjectNode duplicate = ((ObjectNode) input.get("items").get(0)).deepCopy().put("candidateKey", "candidate-copy").put("itemKey", "copy-item");
        input.withArray("items").add(duplicate);
        input.withArray("candidates").add(((ObjectNode) input.get("candidates").get(0)).deepCopy().put("candidateKey", "candidate-copy"));
        assertThrows(FinancialException.class, () -> identity.items(input));
    }

    /**
     * 반복 기억은 직접 근거 집합으로 유지하고 관계 확장 부분의 내용 변경은 근거 지문에만 반영한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void separatesDirectRecurringIdentityFromClosure() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        List<ObjectNode> ends = related(source, relation);
        List<ObjectNode> firstRows = List.of(ends.get(0), salary(source, "2026-07"), salary(source, "2026-08"));
        List<ObjectNode> secondRows = List.of(ends.get(1), salary(source, "2026-07"), salary(source, "2026-08"));
        ObjectNode first = recurring(source, firstRows, "candidate-a"), second = recurring(source, secondRows, "candidate-b");
        ObjectNode input = first.deepCopy();
        input.withArray("transactions").add(second.get("transactions").get(0).deepCopy());
        input.withArray("currentClassifications").add(second.get("currentClassifications").get(0).deepCopy());
        input.withArray("items").add(second.get("items").get(0).deepCopy());
        input.withArray("candidates").add(second.get("candidates").get(0).deepCopy());
        ObjectNode link = input.withArray("relations").addObject();
        for (String field : List.of("kind", "fromId", "toId")) link.set(field, relation.get(field).deepCopy());
        String key = "candidate-a:item";
        var before = selected(input, key);
        assertEquals(identity.items(first).getFirst().key(), before.key());
        ObjectNode changed = input.deepCopy();
        row(changed, "transactions", "transactionId", ends.get(1).get("transactionId").asString()).put("description", "확장 근거의 적요 변경");
        assertEquals(before.key(), selected(changed, key).key());
        assertNotEquals(before.evidenceHash(), selected(changed, key).evidenceHash());
        assertNotEquals(selected(input, "candidate-a:item").key(), selected(input, "candidate-b:item").key());
    }

    /**
     * 공개 의미 입력에 없는 원천 금액·날짜도 저장 지문에 반영하되 Flutter 힌트는 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void bindsRawAmountAndDate() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source, "2026-06");
        ObjectNode input = input(source, List.of(target));
        ObjectNode sourceBefore = source.deepCopy(), inputBefore = input.deepCopy();
        var before = identity.boundItems(source, input).getFirst();
        String hint = identity.hint(input), hash = identity.boundInputHash(source, input, versions());
        ObjectNode changed = source.deepCopy();
        ObjectNode row = row(changed, "transactions", "transactionId", target.path("transactionId").asString());
        row.put("amountKRW", row.path("amountKRW").asLong() + 1);
        assertEquals(before.key(), identity.boundItems(changed, input).getFirst().key());
        assertNotEquals(before.evidenceHash(), identity.boundItems(changed, input).getFirst().evidenceHash());
        assertNotEquals(hash, identity.boundInputHash(changed, input, versions()));
        assertNotEquals(identity.sourceHash(source, input), identity.sourceHash(changed, input));
        changed = source.deepCopy();
        row(changed, "transactions", "transactionId", target.path("transactionId").asString()).put("postedDate", "2026-06-26");
        assertNotEquals(before.evidenceHash(), identity.boundItems(changed, input).getFirst().evidenceHash());
        assertNotEquals(hash, identity.boundInputHash(changed, input, versions()));
        assertEquals(hint, identity.hint(input));
        assertEquals(sourceBefore, source);
        assertEquals(inputBefore, input);
    }

    /**
     * 원거래와 명시 관계의 반대쪽 금액 변경도 관련 항목 지문에 반영한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void bindsRawClosureFacts() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        ObjectNode input = input(source, related(source, relation));
        String fromKey = "transaction:" + relation.path("fromId").asString();
        ObjectNode changed = source.deepCopy();
        ObjectNode other = row(changed, "transactions", "transactionId", relation.path("toId").asString());
        other.put("amountKRW", other.path("amountKRW").asLong() + 1);
        assertEquals(bound(source, input, fromKey).key(), bound(changed, input, fromKey).key());
        assertNotEquals(bound(source, input, fromKey).evidenceHash(), bound(changed, input, fromKey).evidenceHash());

        ObjectNode cancelled = unique(source.path("transactions"), row -> "card_cancellation".equals(row.path("recordKind").asString()));
        ObjectNode original = row(source, "transactions", "transactionId", cancelled.path("originalTransactionId").asString());
        input = input(source, List.of(cancelled, original));
        changed = source.deepCopy();
        row(changed, "transactions", "transactionId", original.path("transactionId").asString()).put("purchaseDate", "2026-10-01");
        assertNotEquals(bound(source, input, itemKey(cancelled)).evidenceHash(), bound(changed, input, itemKey(cancelled)).evidenceHash());
    }

    /**
     * 별도 항목의 원천 변경은 해당 기억만 무효화하며 입력 밖 거래는 전체 실행 지문도 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void limitsBoundFactsToEachItem() throws Exception {
        ObjectNode source = source("demo-ready"), first = salary(source, "2026-06"), second = salary(source, "2026-07");
        ObjectNode input = input(source, List.of(first, second));
        ObjectNode changed = source.deepCopy();
        ObjectNode other = salary(changed, "2026-07");
        other.put("amountKRW", other.path("amountKRW").asLong() + 1);
        assertEquals(bound(source, input, itemKey(first)), bound(changed, input, itemKey(first)));
        assertNotEquals(bound(source, input, itemKey(second)).evidenceHash(), bound(changed, input, itemKey(second)).evidenceHash());
        changed = source.deepCopy();
        ObjectNode outside = salary(changed, "2026-08");
        outside.put("amountKRW", outside.path("amountKRW").asLong() + 1);
        assertEquals(identity.boundItems(source, input), identity.boundItems(changed, input));
        assertEquals(identity.boundInputHash(source, input, versions()), identity.boundInputHash(changed, input, versions()));
        assertEquals(identity.sourceHash(source, input), identity.sourceHash(changed, input));
    }

    /**
     * 전체 버전·추적값·임시 키·배열 순서만 달라지면 저장 지문과 삭제 식별을 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void normalizesBoundMetadata() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source, "2026-06");
        ObjectNode input = input(source, List.of(target));
        ObjectNode changed = source.deepCopy().put("dataVersion", "999").put("sourceVersion", "new-source");
        ObjectNode row = salary(changed, "2026-06");
        row.put("sourceVersion", "new-source").put("sourceRef", "new-provider-trace");
        row.put("userId", "different-owner-must-be-rejected-before-hashing");
        reverse(changed, "transactions");
        assertEquals(identity.boundItems(source, input), identity.boundItems(changed, input));
        assertEquals(identity.boundInputHash(source, input, versions()), identity.boundInputHash(changed, input, versions()));
        assertEquals(identity.sourceHash(source, input), identity.sourceHash(changed, input));
        ObjectNode renamed = input.deepCopy();
        ((ObjectNode) renamed.path("items").get(0)).put("itemKey", "new-request-key");
        assertEquals(identity.boundItems(source, input).getFirst().evidenceHash(), identity.boundItems(source, renamed).getFirst().evidenceHash());
        assertEquals(identity.boundInputHash(source, input, versions()), identity.boundInputHash(source, renamed, versions()));
    }

    /**
     * 원천 규칙·모델·프롬프트 버전은 저장된 근거 식별과 분리하고 최종 캐시 지문에서 검증한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void separatesBoundFactsFromVersions() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source, "2026-06")));
        ObjectNode changedSource = source.deepCopy().put("ruleVersion", "changed-rule");
        ObjectNode changedInput = input.deepCopy();
        ((ObjectNode) changedInput.path("context")).put("ruleVersion", "changed-rule");
        assertEquals(identity.boundItems(source, input), identity.boundItems(changedSource, changedInput));
        assertNotEquals(identity.boundInputHash(source, input, versions()), identity.boundInputHash(changedSource, changedInput, versions()));
        assertNotEquals(identity.sourceHash(source, input), identity.sourceHash(changedSource, input));
        for (String field : List.of("model", "prompt", "response", "policy")) {
            ObjectNode changedVersions = versions().put(field, "changed-version");
            assertNotEquals(identity.boundInputHash(source, input, versions()), identity.boundInputHash(source, input, changedVersions));
        }
    }

    /**
     * 반복 후보의 원천 날짜 변경은 특징을 서버에서 다시 계산하지 않고 관련 지문만 무효화한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void bindsRecurringSourceWithoutCalculating() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode input = recurring(source, List.of(salary(source, "2026-07"), salary(source, "2026-08"), salary(source, "2026-09")), "candidate-a");
        ObjectNode original = input.deepCopy(), changed = source.deepCopy();
        salary(changed, "2026-08").put("postedDate", "2026-08-28");
        assertEquals(identity.boundItems(source, input).getFirst().key(), identity.boundItems(changed, input).getFirst().key());
        assertNotEquals(identity.boundItems(source, input).getFirst().evidenceHash(), identity.boundItems(changed, input).getFirst().evidenceHash());
        assertNotEquals(identity.boundInputHash(source, input, versions()), identity.boundInputHash(changed, input, versions()));
        assertEquals(original, input);
    }

    /**
     * 항목별 원천 결합 결과도 배열 순서 대신 현재 요청 키로 유일하게 찾는다.
     * @created 2026-11-01
     * @usedBy 원천 결합 지문 검사
     */
    private AnalysisIdentity.Item bound(ObjectNode source, ObjectNode input, String itemKey) {
        List<AnalysisIdentity.Item> found = identity.boundItems(source, input).stream()
            .filter(item -> itemKey.equals(item.itemKey())).toList();
        assertEquals(1, found.size());
        return found.getFirst();
    }

    /**
     * 제품 fixture는 읽기만 하며 각 검사에 독립된 메모리 사본을 제공한다.
     * @created 2026-11-01
     * @usedBy AnalysisIdentityTest
     */
    private ObjectNode source(String name) throws Exception {
        return (ObjectNode) AnalysisJson.JSON.readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots", name + ".json")));
    }

    /**
     * 명시 선택한 거래만으로 입력을 구성하고 ID·관계·원천값을 시험 준비 자료에서 읽는다.
     * @created 2026-11-01
     * @usedBy AnalysisIdentityTest
     */
    private ObjectNode input(ObjectNode source, List<ObjectNode> selected) {
        ObjectNode input = AnalysisJson.JSON.createObjectNode().put("contractVersion", "PAYSE-ANALYSIS-1").put("semanticTaskKind", "transactionMeaning");
        ObjectNode context = input.putObject("context").put("schemaVersion", "PAYSE-API-0.6-4").put("inputRevision", 1).put("localSessionEpoch", 1);
        for (String field : List.of("dataVersion", "sourceVersion", "ruleVersion", "asOf")) context.set(field, source.get(field).deepCopy());
        context.putArray("selectedAccountIds");
        ArrayNode transactions = input.putArray("transactions"), items = input.putArray("items"), classifications = input.putArray("currentClassifications");
        input.putArray("candidates");
        Set<String> ids = selected.stream().map(row -> row.get("transactionId").asString()).collect(java.util.stream.Collectors.toSet());
        for (ObjectNode selectedRow : selected) {
            ObjectNode transaction = transactions.addObject();
            for (String field : FIELDS) transaction.set(field, selectedRow.get(field).deepCopy());
            String id = selectedRow.get("transactionId").asString();
            items.addObject().put("itemKey", itemKey(selectedRow)).put("targetTransactionId", id).putNull("candidateKey").putArray("evidenceTransactionIds").add(id);
            if (!selectedRow.get("payseTransactionType").isNull()) classifications.addObject().put("transactionId", id).set("value", selectedRow.get("payseTransactionType").deepCopy());
        }
        ArrayNode relations = input.putArray("relations");
        for (JsonNode relation : source.get("transactionRelations")) {
            if (!ids.contains(relation.get("fromId").asString()) || !ids.contains(relation.get("toId").asString())) continue;
            ObjectNode row = relations.addObject();
            for (String field : List.of("kind", "fromId", "toId")) row.set(field, relation.get(field).deepCopy());
        }
        Set<String> originals = selected.stream().filter(row -> !row.get("originalTransactionId").isNull())
            .map(row -> row.get("originalTransactionId").asString()).collect(java.util.stream.Collectors.toSet());
        ArrayNode unavailable = input.putArray("unavailableReferences");
        for (JsonNode resolution : source.get("referenceResolutions")) if (originals.contains(resolution.get("transactionId").asString())) {
            unavailable.addObject().set("transactionId", resolution.get("transactionId").deepCopy()).set("reason", resolution.get("reason").deepCopy());
        }
        return input;
    }

    /**
     * 로컬 반복 특징은 명시 시험값으로 두고 서버가 산출하지 않음을 유지한다.
     * @created 2026-11-01
     * @usedBy 반복 기억 식별 검사
     */
    private ObjectNode recurring(ObjectNode source, List<ObjectNode> selected, String candidateKey) {
        ObjectNode input = input(source, selected).put("semanticTaskKind", "recurringMeaning");
        ObjectNode candidate = input.withArray("candidates").addObject().put("candidateKey", candidateKey).put("normalizedName", "반복 입금 후보")
            .put("suggestedAmountKRW", 3000000).put("suggestedDay", 25);
        for (String version : List.of("ruleVersion", "sourceVersion")) candidate.set(version, source.get(version).deepCopy());
        ArrayNode refs = candidate.putArray("evidenceTransactionIds");
        selected.forEach(row -> refs.add(row.get("transactionId")));
        ObjectNode features = candidate.putObject("features").put("occurrenceCount", 3).put("dayWithinRule", true)
            .put("amountWithinRule", true).put("hasUnresolvedReversal", false);
        features.putArray("observedMonths").add("2026-07").add("2026-08").add("2026-09");
        input.putArray("items").addObject().put("itemKey", candidateKey + ":item").putNull("targetTransactionId")
            .put("candidateKey", candidateKey).set("evidenceTransactionIds", refs.deepCopy());
        return input;
    }

    /**
     * 표시명·고정 UUID 대신 생성기 원천 참조로 급여 거래 하나를 확인한다.
     * @created 2026-11-01
     * @usedBy 시험 입력 준비
     */
    private ObjectNode salary(ObjectNode source, String month) {
        ObjectNode target = unique(source.get("transactions"), row -> row.path("sourceRef").asString().endsWith("/salary/" + month));
        assertEquals(source.get("userId"), target.get("userId"));
        return target;
    }

    /**
     * 실제 명시 이체 관계가 하나인지 확인한다.
     * @created 2026-11-01
     * @usedBy 관계 검사 준비
     */
    private ObjectNode transfer(ObjectNode source) {
        return unique(source.get("transactionRelations"), row -> "internal_transfer".equals(row.path("kind").asString()));
    }

    /**
     * 관계 양 끝을 원천 ID로 해석하고 누락·중복이면 준비 단계에서 실패한다.
     * @created 2026-11-01
     * @usedBy 관계 검사 준비
     */
    private List<ObjectNode> related(ObjectNode source, ObjectNode relation) {
        return List.of(row(source, "transactions", "transactionId", relation.get("fromId").asString()),
            row(source, "transactions", "transactionId", relation.get("toId").asString()));
    }

    /**
     * 시험 입력의 항목 키를 원천 ID에서만 만든다.
     * @created 2026-11-01
     * @usedBy input, 항목 식별 검사
     */
    private String itemKey(JsonNode row) { return "transaction:" + row.get("transactionId").asString(); }

    /**
     * 실제 현재 helper의 결과를 키로 선택하며 정렬 순서에 기대지 않는다.
     * @created 2026-11-01
     * @usedBy 개별 기억 검사
     */
    private AnalysisIdentity.Item selected(ObjectNode input, String itemKey) {
        List<AnalysisIdentity.Item> values = identity.items(input).stream().filter(item -> itemKey.equals(item.itemKey())).toList();
        assertEquals(1, values.size());
        return values.getFirst();
    }

    /**
     * 배열 순서만 뒤집고 각 행의 원천 값은 유지한다.
     * @created 2026-11-01
     * @usedBy 순서 무관성 검사
     */
    private void reverse(ObjectNode input, String field) {
        JsonNode original = input.get(field).deepCopy();
        ArrayNode reversed = input.putArray(field);
        for (int index = original.size() - 1; index >= 0; index--) reversed.add(original.get(index));
    }

    /**
     * 승인 버전 변경의 지문 효과만 확인하는 명시 시험값이다.
     * @created 2026-11-01
     * @usedBy 캐시 버전 검사
     */
    private ObjectNode versions() {
        return AnalysisJson.JSON.createObjectNode().put("model", "test-model").put("prompt", "PAYSE-PROMPT-1")
            .put("response", "PAYSE-ANALYSIS-1").put("policy", "PAYSE-MEANING-1");
    }

    /**
     * 명시 ID로 원천 행을 유일하게 찾는다.
     * @created 2026-11-01
     * @usedBy 시험 준비와 메모리 반례 변경
     */
    private ObjectNode row(ObjectNode source, String field, String idField, String id) {
        return unique(source.get(field), row -> id.equals(row.path(idField).asString()));
    }

    /**
     * 원천에서 정확히 하나를 찾았는지 확인하여 임의 첫 행 사용을 막는다.
     * @created 2026-11-01
     * @usedBy row, salary, transfer
     */
    private ObjectNode unique(JsonNode rows, Predicate<JsonNode> predicate) {
        ObjectNode found = optional(rows, predicate);
        assertNotNull(found, "Fixture must identify one row");
        return found;
    }

    /**
     * nullable 기존 분류만 선택적으로 찾으며 여러 행이면 준비 오류로 처리한다.
     * @created 2026-11-01
     * @usedBy unique, 원거래 분류 변경 검사
     */
    private ObjectNode optional(JsonNode rows, Predicate<JsonNode> predicate) {
        List<ObjectNode> values = new ArrayList<>();
        for (JsonNode row : rows) if (predicate.test(row)) values.add((ObjectNode) row);
        assertTrue(values.size() <= 1, "Fixture row must be unique");
        return values.isEmpty() ? null : values.getFirst();
    }
}
