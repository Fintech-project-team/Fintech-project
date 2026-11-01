package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 준비 원천의 ID·관계로 분석 입력의 소유권·현재성·근거 누락을 검증한다.
 * @created 2026-11-01
 * @usedBy Gradle JUnit
 */
class AnalysisEvidenceTest {
    private final JsonMapper json = JsonMapper.builder().build();
    private final AnalysisEvidence evidence = new AnalysisEvidence();
    private static final List<String> FIELDS = List.of("transactionId", "recordKind", "direction", "status",
        "reflectionReason", "merchantName", "description", "originalTransactionId");

    /**
     * 원천·입력을 보존하고 반환값 수정도 호출자의 자료를 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesSources() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode input = input(source, List.of(salary(source)));
        ObjectNode beforeSource = source.deepCopy(), beforeInput = input.deepCopy();
        ObjectNode result = evidence.verify(owner(source), source, input);
        assertEquals(input, result);
        assertNotSame(input, result);
        ((ObjectNode) result.get("context")).put("inputRevision", 99);
        assertEquals(beforeSource, source);
        assertEquals(beforeInput, input);
    }

    /**
     * UUID 정렬 첫 100건 밖의 실제 거래도 전체 DB 원천으로 검증한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsLaterPage() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode target = salary(source);
        List<String> ids = new ArrayList<>();
        source.get("transactions").forEach(row -> ids.add(row.get("transactionId").asString()));
        ids.sort(String::compareTo);
        assertTrue(ids.indexOf(target.get("transactionId").asString()) >= 100);
        ObjectNode input = input(source, List.of(target));
        assertEquals(input, evidence.verify(owner(source), source, input));
    }

    /**
     * 같은 입력이어도 인증 사용자가 원천 소유자와 다르면 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsOtherOwner() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode other = source("beta-ready");
        assertFalse(owner(source).equals(owner(other)));
        failure(403, "RESOURCE_FORBIDDEN", owner(other), source, input(source, List.of(salary(source))));
    }

    /**
     * 입력 문맥을 현재 사용자 것으로 꾸며도 다른 사용자의 거래는 허용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsOtherUsersTransaction() throws Exception {
        ObjectNode source = source("demo-ready"), other = source("beta-ready");
        ObjectNode input = input(other, List.of(salary(other)));
        input.set("context", context(source));
        failure(403, "RESOURCE_FORBIDDEN", owner(source), source, input);
    }

    /**
     * 연결 해제 이후에는 이전에 받은 정확한 거래 내용도 분석에 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsDisconnectedBank() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode target = salary(source), input = input(source, List.of(target));
        disconnect(source, target);
        failure(403, "RESOURCE_FORBIDDEN", owner(source), source, input);
    }

    /**
     * 선택 목록에 다른 계좌를 넣어도 금융 공개 권한을 넓히지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsForeignSelection() throws Exception {
        ObjectNode source = source("demo-ready"), other = source("beta-ready");
        ObjectNode input = input(source, List.of(salary(source)));
        ((ArrayNode) input.get("context").get("selectedAccountIds")).add(salary(other).get("accountId"));
        failure(403, "RESOURCE_FORBIDDEN", owner(source), source, input);
    }

    /**
     * 금융 데이터·원천 버전과 기준 시각이 바뀌면 현재 문맥을 다시 받게 한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsStaleContext() throws Exception {
        ObjectNode source = source("demo-ready");
        Map<String, String> changed = Map.of("dataVersion", "9223372036854775807",
            "sourceVersion", "different-source", "asOf", "2026-10-20T12:00:00+09:00");
        for (var entry : changed.entrySet()) {
            ObjectNode input = input(source, List.of(salary(source)));
            ((ObjectNode) input.get("context")).put(entry.getKey(), entry.getValue());
            failure(409, "STALE_DATA", owner(source), source, input);
        }
    }

    /**
     * 다른 계산 규칙 문맥은 일반 입력 오류와 구분한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsWrongRule() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source)));
        ((ObjectNode) input.get("context")).put("ruleVersion", "different-rule");
        failure(409, "RULE_VERSION_MISMATCH", owner(source), source, input);
    }

    /**
     * 사용자 편집 불가인 거래 적요를 임의로 바꾼 분석 입력을 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsChangedSource() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source);
        ObjectNode input = input(source, List.of(target));
        row(input, "transactions", "transactionId", target.get("transactionId").asString()).put("description", "위조 적요");
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 저장 분류를 빼서 출력 충돌 검사를 우회할 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsOmittedClassification() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source)));
        assertEquals(1, input.get("currentClassifications").size());
        input.putArray("currentClassifications");
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 분류 정정 후 구버전 값을 보내면 같은 원천 거래라도 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsOldClassification() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source);
        ObjectNode input = input(source, List.of(target));
        assertEquals("income", target.get("payseTransactionType").asString());
        target.put("payseTransactionType", "expense");
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 원천 null은 분류 누락 오류로 바꾸지 않으며 임의 확정값을 만들지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsUnknownClassification() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source);
        target.putNull("payseTransactionType");
        ObjectNode input = input(source, List.of(target));
        assertEquals(0, input.get("currentClassifications").size());
        assertEquals(input, evidence.verify(owner(source), source, input));
    }

    /**
     * 확인된 본인 이체 양 끝과 관계는 함께 검증한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsExplicitRelation() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode relation = transfer(source);
        ObjectNode input = input(source, related(source, relation));
        assertEquals(1, input.get("relations").size());
        assertEquals(input, evidence.verify(owner(source), source, input));
    }

    /**
     * 두 거래를 제출해도 실제 명시 관계를 빼면 검증에 실패한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsOmittedRelation() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, related(source, transfer(source)));
        input.putArray("relations");
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 형식상 가능한 반대 방향 관계라도 DB에 없으면 위조로 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsForgedRelation() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        ObjectNode input = input(source, related(source, relation));
        ObjectNode sent = unique(input.get("relations"), ignored -> true);
        sent.set("fromId", relation.get("toId"));
        sent.set("toId", relation.get("fromId"));
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 명시 관계 반대쪽의 공개 근거를 빼고 한 거래만 판단하게 만들 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsMissingRelationEndpoint() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        ObjectNode target = row(source, "transactions", "transactionId", relation.get("fromId").asString());
        failure(422, "VALIDATION_FAILED", owner(source), source, input(source, List.of(target)));
    }

    /**
     * 취소의 실제 원거래를 null로 지워 판단 근거를 없앨 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsRemovedOriginal() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode cancel = unique(source.get("transactions"), value -> "card_cancellation".equals(value.path("recordKind").asString()));
        ObjectNode input = input(source, List.of(cancel));
        row(input, "transactions", "transactionId", cancel.get("transactionId").asString()).putNull("originalTransactionId");
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 미확보 표식의 ID·사유만으로 원거래의 소유·기관 공개 권한을 인정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsUnverifiedOriginalAccess() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        ObjectNode resolution = unique(source.get("referenceResolutions"), ignored -> true);
        ObjectNode refund = unique(source.get("transactions"), value -> resolution.get("transactionId").equals(value.get("originalTransactionId")));
        ObjectNode input = input(source, List.of(refund));
        assertEquals(1, input.get("unavailableReferences").size());
        failure(503, "TEMPORARILY_UNAVAILABLE", owner(source), source, input);
    }

    /**
     * 원천에 없는 미확보 사유나 미확보 기록 삭제를 정상 근거로 인정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsFabricatedUnavailableReason() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        ObjectNode resolution = unique(source.get("referenceResolutions"), ignored -> true);
        ObjectNode refund = unique(source.get("transactions"), value -> resolution.get("transactionId").equals(value.get("originalTransactionId")));
        ObjectNode input = input(source, List.of(refund));
        unique(input.get("unavailableReferences"), ignored -> true).put("reason", "outside_retention");
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
        input = input(source, List.of(refund));
        source.putArray("referenceResolutions");
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 현재 원거래를 읽을 권한이 없으면 그 ID를 모델 입력으로 복원하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsHiddenOriginal() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        ObjectNode resolution = unique(source.get("referenceResolutions"), ignored -> true);
        ObjectNode refund = unique(source.get("transactions"), value -> resolution.get("transactionId").equals(value.get("originalTransactionId")));
        resolution.put("reason", "not_connected");
        failure(403, "RESOURCE_FORBIDDEN", owner(source), source, input(source, List.of(refund)));
    }

    /**
     * 평가용 verified 표시를 넣어도 API에서 신뢰 근거로 인정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsClientVerificationFlag() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source)));
        input.put("verified", true);
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 로컬 반복 후보는 영구 DB 후보를 요구하지 않고 실제 근거·버전·준비 상태만 검사한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsLocalCandidate() throws Exception {
        ObjectNode source = source("demo-ready");
        List<ObjectNode> selected = new ArrayList<>();
        for (String month : List.of("2026-07", "2026-08", "2026-09")) {
            selected.add(unique(source.get("transactions"), row -> row.path("sourceRef").asString().endsWith("/salary/" + month)));
        }
        ObjectNode input = input(source, selected).put("semanticTaskKind", "recurringMeaning");
        ObjectNode candidate = ((ArrayNode) input.get("candidates")).addObject().put("candidateKey", "monthly-income");
        candidate.set("ruleVersion", source.get("ruleVersion"));
        candidate.set("sourceVersion", source.get("sourceVersion"));
        candidate.put("normalizedName", "반복 입금 후보").put("suggestedAmountKRW", 3000000).put("suggestedDay", 25);
        ArrayNode refs = candidate.putArray("evidenceTransactionIds");
        selected.forEach(row -> refs.add(row.get("transactionId")));
        ObjectNode features = candidate.putObject("features").put("occurrenceCount", 3)
            .put("dayWithinRule", true).put("amountWithinRule", true).put("hasUnresolvedReversal", false);
        features.putArray("observedMonths").add("2026-07").add("2026-08").add("2026-09");
        ObjectNode item = input.putArray("items").addObject().put("itemKey", "monthly-income-item")
            .putNull("targetTransactionId").put("candidateKey", "monthly-income");
        item.set("evidenceTransactionIds", refs.deepCopy());
        assertEquals(input, evidence.verify(owner(source), source, input));
        features.put("hasUnresolvedReversal", true);
        failure(422, "VALIDATION_FAILED", owner(source), source, input);
    }

    /**
     * 제품 fixture는 읽기만 하며 각 검사에서 별도의 메모리 객체를 사용한다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     */
    private ObjectNode source(String name) throws Exception {
        return (ObjectNode) json.readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots", name + ".json")));
    }

    /**
     * 입력 화면 문맥을 원천에서 구성하되 Flutter 소유 epoch·revision은 명시 시험값으로 둔다.
     * @created 2026-11-01
     * @usedBy input, rejectsOtherUsersTransaction
     */
    private ObjectNode context(ObjectNode source) {
        ObjectNode result = json.createObjectNode().put("schemaVersion", "PAYSE-API-0.6-4");
        for (String field : List.of("dataVersion", "sourceVersion", "ruleVersion", "asOf")) result.set(field, source.get(field));
        result.put("inputRevision", 4).put("localSessionEpoch", 17).putArray("selectedAccountIds");
        return result;
    }

    /**
     * 선택한 준비 거래의 ID·실제 관계·분류만 복사한다. 검사 대상 구현은 정답 생성에 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     */
    private ObjectNode input(ObjectNode source, List<ObjectNode> selected) {
        ObjectNode result = json.createObjectNode().put("contractVersion", "PAYSE-ANALYSIS-1")
            .put("semanticTaskKind", "transactionMeaning");
        result.set("context", context(source));
        ArrayNode items = result.putArray("items"), transactions = result.putArray("transactions");
        ArrayNode relations = result.putArray("relations"), missing = result.putArray("unavailableReferences");
        ArrayNode classifications = result.putArray("currentClassifications");
        result.putArray("candidates");
        Set<String> ids = selected.stream().map(row -> row.get("transactionId").asString()).collect(java.util.stream.Collectors.toSet());
        for (ObjectNode target : selected) {
            String id = target.get("transactionId").asString();
            ObjectNode transaction = transactions.addObject();
            for (String field : FIELDS) transaction.set(field, target.get(field).deepCopy());
            ObjectNode item = items.addObject().put("itemKey", "transaction:" + id)
                .put("targetTransactionId", id).putNull("candidateKey");
            ArrayNode evidenceIds = item.putArray("evidenceTransactionIds");
            ids.stream().sorted().forEach(evidenceIds::add);
            if (!target.get("payseTransactionType").isNull()) classifications.addObject().put("transactionId", id)
                .set("value", target.get("payseTransactionType").deepCopy());
        }
        for (JsonNode relation : source.get("transactionRelations")) {
            if (ids.contains(relation.get("fromId").asString()) && ids.contains(relation.get("toId").asString())) {
                ObjectNode value = relations.addObject();
                for (String field : List.of("kind", "fromId", "toId")) value.set(field, relation.get(field).deepCopy());
            }
        }
        Set<String> originalIds = selected.stream().filter(row -> !row.get("originalTransactionId").isNull())
            .map(row -> row.get("originalTransactionId").asString()).collect(java.util.stream.Collectors.toSet());
        for (JsonNode resolution : source.get("referenceResolutions")) {
            if (originalIds.contains(resolution.get("transactionId").asString())) missing.addObject()
                .set("transactionId", resolution.get("transactionId").deepCopy()).set("reason", resolution.get("reason").deepCopy());
        }
        return result;
    }

    /**
     * 표시명이나 고정 UUID 대신 생성기의 안정된 원천 참조로 시험 거래를 유일하게 찾는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     */
    private ObjectNode salary(ObjectNode source) {
        ObjectNode target = unique(source.get("transactions"), row -> row.path("sourceRef").asString().endsWith("/salary/2026-06"));
        assertEquals(source.get("userId"), target.get("userId"));
        assertEquals("account_entry", target.get("recordKind").asString());
        assertEquals("in", target.get("direction").asString());
        return target;
    }

    /**
     * 명시된 본인 이체 관계가 정확히 하나인 준비 조건을 먼저 확인한다.
     * @created 2026-11-01
     * @usedBy 관계 검사
     */
    private ObjectNode transfer(ObjectNode source) {
        return unique(source.get("transactionRelations"), row -> "internal_transfer".equals(row.path("kind").asString()));
    }

    /**
     * 관계 양 끝을 실제 준비 자료에서 해석하고 없거나 중복이면 시험 준비를 실패시킨다.
     * @created 2026-11-01
     * @usedBy 관계 검사
     */
    private List<ObjectNode> related(ObjectNode source, ObjectNode relation) {
        return List.of(row(source, "transactions", "transactionId", relation.get("fromId").asString()),
            row(source, "transactions", "transactionId", relation.get("toId").asString()));
    }

    /**
     * 거래의 원천 금융사 연결만 메모리에서 해제하고 다른 연결은 그대로 둔다.
     * @created 2026-11-01
     * @usedBy rejectsDisconnectedBank
     */
    private void disconnect(ObjectNode source, ObjectNode transaction) {
        boolean account = "account_entry".equals(transaction.get("recordKind").asString());
        String key = account ? "accountId" : "cardId";
        ObjectNode parent = row(source, account ? "accounts" : "cards", key, transaction.get(key).asString());
        ObjectNode link = row(source, "institutionLinks", "institutionCode", parent.get("institutionCode").asString());
        assertTrue(link.get("disconnectedAt").isNull());
        link.put("disconnectedAt", "2026-10-20T12:00:00+09:00");
    }

    /**
     * 명시 참조로 찾은 대상의 유일성을 검사한다.
     * @created 2026-11-01
     * @usedBy 시험 준비 도우미
     */
    private ObjectNode row(ObjectNode source, String array, String key, String value) {
        return unique(source.get(array), row -> value.equals(row.path(key).asString()));
    }

    /**
     * 첫 행·표시명·LIMIT 1 대신 단일 대상이라는 준비 조건을 확인한다.
     * @created 2026-11-01
     * @usedBy row, salary, transfer, 미확보 참조 검사
     */
    private ObjectNode unique(JsonNode rows, Predicate<JsonNode> predicate) {
        List<ObjectNode> matches = new ArrayList<>();
        for (JsonNode row : rows) if (predicate.test(row)) matches.add((ObjectNode) row);
        assertEquals(1, matches.size(), "Fixture selection must identify exactly one row");
        return matches.getFirst();
    }

    /**
     * 준비 원천에 저장된 사용자를 읽고 임의 UUID를 검사에 심지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     */
    private UUID owner(ObjectNode source) { return UUID.fromString(source.get("userId").asString()); }

    /**
     * 공개 상태·코드를 명시 기대값으로 검증한다.
     * @created 2026-11-01
     * @usedBy 오류 검사
     */
    private void failure(int status, String code, UUID owner, ObjectNode source, ObjectNode input) {
        FinancialException failure = assertThrows(FinancialException.class, () -> evidence.verify(owner, source, input));
        assertEquals(status, failure.status());
        assertEquals(code, failure.code());
    }
}
