package com.payse.ai.analysis;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 일부 기억 삭제 후에도 전체 근거를 유지하면서 허용된 항목만 반환하는 검증을 확인한다.
 * @created 2026-11-01
 * @usedBy JUnit
 */
class AnalysisSubsetTest {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private final AnalysisContract contract = new AnalysisContract();

    /**
     * 서로 독립된 두 거래 중 하나만 조회해도 원입력을 손상하지 않고 검증한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void acceptsSubsetWithCompleteEvidence() throws Exception {
        ObjectNode input = input();
        ObjectNode original = input.deepCopy();
        ObjectNode output = output(input, 0);
        assertDoesNotThrow(() -> contract.outputSubset(input, output));
        assertThrows(ContractFailure.class, () -> contract.output(input, output));
        assertEquals(original, input);
        assertEquals(2, input.path("transactions").size());
        assertEquals(1, output.path("items").size());
    }

    /**
     * 부분 반환에서도 다른 항목·중복 항목·임의 필드·빈 결과를 정상으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidSubset() throws Exception {
        ObjectNode input = input();
        ObjectNode foreign = output(input, 0);
        ((ObjectNode) foreign.path("items").get(0)).put("itemKey", UUID.randomUUID().toString());
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, foreign));
        ObjectNode repeated = output(input, 0);
        ((ArrayNode) repeated.path("items")).add(repeated.path("items").get(0).deepCopy());
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, repeated));
        ObjectNode extra = output(input, 0).put("balance", 0);
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, extra));
        ObjectNode empty = output(input, 0);
        empty.putArray("items");
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, empty));
    }

    /**
     * 다른 항목의 거래 ID가 전체 입력에 있더라도 현재 항목의 허용 근거가 아니면 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsEvidenceFromOtherItem() throws Exception {
        ObjectNode input = input();
        ObjectNode result = output(input, 0);
        ((ObjectNode) result.path("items").get(0)).putArray("evidenceTransactionIds")
            .add(input.path("items").get(1).path("targetTransactionId"));
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 부분 반환도 원천의 기존 분류와 카드 정산 근거를 우회할 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesClassificationChecks() throws Exception {
        ObjectNode input = input();
        String id = input.path("items").get(0).path("targetTransactionId").asString();
        ((ArrayNode) input.path("currentClassifications")).addObject()
            .put("transactionId", id).put("value", "income");
        ObjectNode result = output(input, 0);
        decision((ObjectNode) result.path("items").get(0), "classification", "expense");
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
        decision((ObjectNode) result.path("items").get(0), "classification", "income");
        assertDoesNotThrow(() -> contract.outputSubset(input, result));
        input.putArray("currentClassifications");
        decision((ObjectNode) result.path("items").get(0), "classification", "card_payment");
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 반환하지 않는 상대 거래도 명시 관계의 검증에 보존하며 관계가 없으면 추정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesRelationEvidence() throws Exception {
        ObjectNode input = input();
        ObjectNode first = (ObjectNode) input.path("transactions").get(0);
        ObjectNode second = (ObjectNode) input.path("transactions").get(1);
        first.put("direction", "out");
        String from = first.path("transactionId").asString();
        String to = second.path("transactionId").asString();
        ((ObjectNode) input.path("items").get(0)).putArray("evidenceTransactionIds").add(from).add(to);
        ((ArrayNode) input.path("relations")).addObject().put("kind", "internal_transfer")
            .put("fromId", from).put("toId", to);
        ObjectNode result = output(input, 0);
        decision((ObjectNode) result.path("items").get(0), "classification", "internal_transfer");
        assertDoesNotThrow(() -> contract.outputSubset(input, result));
        input.putArray("relations");
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 전체 입력 자체의 미사용 근거 오류를 부분 반환이라는 이유로 건너뛰지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void validatesFullInput() throws Exception {
        ObjectNode input = input();
        ObjectNode result = output(input, 0);
        ((ArrayNode) input.path("items")).remove(1);
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 반복 후보 일부 조회에서 다른 후보는 남기되 반환 항목의 후보 ID는 정확히 대조한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void validatesRecurringCandidate() throws Exception {
        ObjectNode input = recurring();
        ObjectNode result = output(input, 0);
        assertDoesNotThrow(() -> contract.outputSubset(input, result));
        ((ObjectNode) result.path("items").get(0)).set("candidateKey", input.path("items").get(1).get("candidateKey"));
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 공개 합성 입력에 독립 거래를 추가하며 거래별 ID는 준비 단계에서 생성해 전달한다.
     * @created 2026-11-01
     * @usedBy 부분 조회 테스트
     */
    private ObjectNode input() throws Exception {
        ObjectNode input = (ObjectNode) JSON.readTree(Files.readString(
            Path.of(System.getProperty("payse.testData"), "service-input.json")));
        ObjectNode transaction = ((ObjectNode) input.path("transactions").get(0)).deepCopy();
        String id = UUID.randomUUID().toString();
        transaction.put("transactionId", id);
        ((ArrayNode) input.path("transactions")).add(transaction);
        ObjectNode item = ((ObjectNode) input.path("items").get(0)).deepCopy();
        item.put("itemKey", UUID.randomUUID().toString()).put("targetTransactionId", id);
        item.putArray("evidenceTransactionIds").add(id);
        ((ArrayNode) input.path("items")).add(item);
        return input;
    }

    /**
     * 후보별 세 달 근거를 독립 구성하며 로컬 계산 결과의 기존 형식만 사용한다.
     * @created 2026-11-01
     * @usedBy validatesRecurringCandidate
     */
    private ObjectNode recurring() throws Exception {
        ObjectNode input = input();
        ObjectNode template = ((ObjectNode) input.path("transactions").get(0)).deepCopy();
        input.put("semanticTaskKind", "recurringMeaning");
        var transactions = input.putArray("transactions");
        var items = input.putArray("items");
        var candidates = input.putArray("candidates");
        for (int index = 0; index < 2; index++) {
            String key = UUID.randomUUID().toString();
            ObjectNode item = items.addObject().put("itemKey", UUID.randomUUID().toString())
                .put("candidateKey", key).putNull("targetTransactionId");
            ArrayNode evidence = item.putArray("evidenceTransactionIds");
            for (int month = 0; month < 3; month++) {
                String id = UUID.randomUUID().toString();
                evidence.add(id);
                transactions.add(template.deepCopy().put("transactionId", id));
            }
            ObjectNode candidate = candidates.addObject().put("candidateKey", key)
                .put("normalizedName", "합성 반복 후보").put("suggestedAmountKRW", 50000).put("suggestedDay", 25);
            candidate.set("ruleVersion", input.path("context").get("ruleVersion"));
            candidate.set("sourceVersion", input.path("context").get("sourceVersion"));
            candidate.set("evidenceTransactionIds", evidence.deepCopy());
            ObjectNode features = candidate.putObject("features").put("occurrenceCount", 3)
                .put("dayWithinRule", true).put("amountWithinRule", true).put("hasUnresolvedReversal", false);
            features.putArray("observedMonths").add("2026-08").add("2026-09").add("2026-10");
        }
        return input;
    }

    /**
     * 전달 검증용 미상 결과 하나만 만들며 정확도 평가 정답으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 부분 조회 테스트
     */
    private ObjectNode output(ObjectNode input, int index) {
        JsonNode source = input.path("items").get(index);
        ObjectNode output = JSON.createObjectNode().put("meaningPolicyVersion", "PAYSE-MEANING-1");
        ObjectNode item = output.putArray("items").addObject().put("itemKey", source.path("itemKey").asString())
            .put("reason", "현재 근거만으로 확정할 수 없습니다.");
        item.set("evidenceTransactionIds", source.path("evidenceTransactionIds").deepCopy());
        item.putObject("meaning").put("status", "unknown").putNull("value").put("reasonCode", "insufficient_evidence");
        if (input.path("semanticTaskKind").asString().equals("transactionMeaning")) {
            item.putObject("classification").put("status", "unknown").putNull("value").put("reasonCode", "insufficient_evidence");
        } else {
            item.set("candidateKey", source.get("candidateKey"));
            item.putNull("name");
        }
        return output;
    }

    /**
     * 검증할 분류 후보를 허용된 상태와 사유로 함께 설정한다.
     * @created 2026-11-01
     * @usedBy preservesClassificationChecks, preservesRelationEvidence
     */
    private void decision(ObjectNode item, String field, String value) {
        item.putObject(field).put("status", "candidate").put("value", value).put("reasonCode", "supported");
    }
}
