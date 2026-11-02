package com.payse.ai.analysis;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.AiTestConstants.AnalysisFields;
import com.payse.ai.AiTestConstants.AnalysisValues;
import com.payse.ai.AiTestConstants;
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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void acceptsSubsetWithCompleteEvidence() throws Exception {
        ObjectNode input = input();
        ObjectNode original = input.deepCopy();
        ObjectNode output = output(input, 0);

        assertDoesNotThrow(() -> contract.outputSubset(input, output));
        assertThrows(ContractFailure.class, () -> contract.output(input, output));
        assertEquals(original, input);
        assertEquals(2, input.path(AnalysisFields.TRANSACTIONS).size());
        assertEquals(1, output.path(AnalysisFields.ITEMS).size());
    }

    /**
     * 부분 반환에서도 다른 항목·중복 항목·임의 필드·빈 결과를 정상으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsInvalidSubset() throws Exception {
        ObjectNode input = input();
        ObjectNode foreign = output(input, 0);
        ((ObjectNode) foreign.path(AnalysisFields.ITEMS).get(0)).put(
            AnalysisFields.ITEM_KEY,
            UUID.randomUUID()
                .toString()
        );
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, foreign));

        ObjectNode repeated = output(input, 0);
        ((ArrayNode) repeated.path(AnalysisFields.ITEMS)).add(
            repeated.path(AnalysisFields.ITEMS)
                .get(0)
                .deepCopy()
        );
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, repeated));

        ObjectNode extra = output(input, 0).put("balance", 0);
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, extra));

        ObjectNode empty = output(input, 0);
        empty.putArray(AnalysisFields.ITEMS);
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, empty));
    }

    /**
     * 다른 항목의 거래 ID가 전체 입력에 있더라도 현재 항목의 허용 근거가 아니면 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsEvidenceFromOtherItem() throws Exception {
        ObjectNode input = input();
        ObjectNode result = output(input, 0);
        ((ObjectNode) result.path(AnalysisFields.ITEMS).get(0))
            .putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
            .add(
                input.path(AnalysisFields.ITEMS)
                    .get(1)
                    .path(AnalysisFields.TARGET_TRANSACTION_ID)
            );
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 부분 반환도 원천의 기존 분류와 카드 정산 근거를 우회할 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void preservesClassificationChecks() throws Exception {
        ObjectNode input = input();
        String id = input.path(AnalysisFields.ITEMS)
            .get(0)
            .path(AnalysisFields.TARGET_TRANSACTION_ID)
            .asString();
        ((ArrayNode) input.path(AnalysisFields.CURRENT_CLASSIFICATIONS)).addObject()
            .put(AnalysisFields.TRANSACTION_ID, id)
            .put(AnalysisFields.VALUE, AnalysisValues.INCOME);
        ObjectNode result = output(input, 0);
        decision(
            (ObjectNode) result.path(AnalysisFields.ITEMS).get(0),
            AnalysisFields.CLASSIFICATION,
            AnalysisValues.EXPENSE
        );
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
        decision(
            (ObjectNode) result.path(AnalysisFields.ITEMS).get(0),
            AnalysisFields.CLASSIFICATION,
            AnalysisValues.INCOME
        );
        assertDoesNotThrow(() -> contract.outputSubset(input, result));

        input.putArray(AnalysisFields.CURRENT_CLASSIFICATIONS);
        decision(
            (ObjectNode) result.path(AnalysisFields.ITEMS).get(0),
            AnalysisFields.CLASSIFICATION,
            AnalysisValues.CARD_PAYMENT
        );
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 반환하지 않는 상대 거래도 명시 관계의 검증에 보존하며 관계가 없으면 추정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void preservesRelationEvidence() throws Exception {
        ObjectNode input = input();
        ObjectNode first = (ObjectNode) input.path(AnalysisFields.TRANSACTIONS).get(0);
        ObjectNode second = (ObjectNode) input.path(AnalysisFields.TRANSACTIONS).get(1);
        first.put(AnalysisFields.DIRECTION, AnalysisValues.OUT);
        String from = first.path(AnalysisFields.TRANSACTION_ID).asString();
        String to = second.path(AnalysisFields.TRANSACTION_ID).asString();
        ((ObjectNode) input.path(AnalysisFields.ITEMS).get(0))
            .putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
            .add(from)
            .add(to);
        ((ArrayNode) input.path(AnalysisFields.RELATIONS)).addObject()
            .put(AnalysisFields.KIND, AnalysisValues.INTERNAL_TRANSFER)
            .put(AnalysisFields.FROM_ID, from)
            .put(AnalysisFields.TO_ID, to);
        ObjectNode result = output(input, 0);
        decision(
            (ObjectNode) result.path(AnalysisFields.ITEMS).get(0),
            AnalysisFields.CLASSIFICATION,
            AnalysisValues.INTERNAL_TRANSFER
        );
        assertDoesNotThrow(() -> contract.outputSubset(input, result));

        input.putArray(AnalysisFields.RELATIONS);
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 전체 입력 자체의 미사용 근거 오류를 부분 반환이라는 이유로 건너뛰지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void validatesFullInput() throws Exception {
        ObjectNode input = input();
        ObjectNode result = output(input, 0);
        ((ArrayNode) input.path(AnalysisFields.ITEMS)).remove(1);
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 반복 후보 일부 조회에서 다른 후보는 남기되 반환 항목의 후보 ID는 정확히 대조한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void validatesRecurringCandidate() throws Exception {
        ObjectNode input = recurring();
        ObjectNode result = output(input, 0);
        assertDoesNotThrow(() -> contract.outputSubset(input, result));

        ObjectNode returnedItem = (ObjectNode) result.path(AnalysisFields.ITEMS).get(0);
        JsonNode otherCandidate = input.path(AnalysisFields.ITEMS)
            .get(1)
            .get(AnalysisFields.CANDIDATE_KEY);
        returnedItem.set(AnalysisFields.CANDIDATE_KEY, otherCandidate);
        assertThrows(ContractFailure.class, () -> contract.outputSubset(input, result));
    }

    /**
     * 공개 합성 입력에 독립 거래를 추가하며 거래별 ID는 준비 단계에서 생성해 전달한다.
     * @created 2026-11-01
     * @usedBy 부분 조회 테스트
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    private ObjectNode input() throws Exception {
        Path inputFile = Path.of(
            System.getProperty(AiTestConstants.Files.TEST_DATA_PROPERTY),
            AiTestConstants.Files.INPUT_FILE
        );
        String source = Files.readString(inputFile);
        ObjectNode input = (ObjectNode) JSON.readTree(source);
        ObjectNode transaction = ((ObjectNode) input.path(AnalysisFields.TRANSACTIONS).get(0))
            .deepCopy();
        String id = UUID.randomUUID().toString();
        transaction.put(AnalysisFields.TRANSACTION_ID, id);
        ((ArrayNode) input.path(AnalysisFields.TRANSACTIONS)).add(transaction);
        ObjectNode item = ((ObjectNode) input.path(AnalysisFields.ITEMS).get(0)).deepCopy();
        item.put(AnalysisFields.ITEM_KEY, UUID.randomUUID().toString())
            .put(AnalysisFields.TARGET_TRANSACTION_ID, id);
        item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS).add(id);
        ((ArrayNode) input.path(AnalysisFields.ITEMS)).add(item);
        return input;
    }

    /**
     * 후보별 세 달 근거를 독립 구성하며 로컬 계산 결과의 기존 형식만 사용한다.
     * @created 2026-11-01
     * @usedBy validatesRecurringCandidate
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private ObjectNode recurring() throws Exception {
        ObjectNode input = input();
        ObjectNode template = ((ObjectNode) input.path(AnalysisFields.TRANSACTIONS).get(0))
            .deepCopy();
        input.put(AnalysisFields.SEMANTIC_TASK_KIND, AnalysisValues.RECURRING_MEANING);
        var transactions = input.putArray(AnalysisFields.TRANSACTIONS);
        var items = input.putArray(AnalysisFields.ITEMS);
        var candidates = input.putArray(AnalysisFields.CANDIDATES);
        for (int index = 0; index < 2; index++) {
            String key = UUID.randomUUID().toString();
            ObjectNode item = items.addObject()
                .put(
                    AnalysisFields.ITEM_KEY,
                    UUID.randomUUID()
                        .toString()
                )
                .put(AnalysisFields.CANDIDATE_KEY, key)
                .putNull(AnalysisFields.TARGET_TRANSACTION_ID);
            ArrayNode evidence = item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS);
            for (int month = 0; month < 3; month++) {
                String id = UUID.randomUUID().toString();
                evidence.add(id);
                transactions.add(template.deepCopy().put(AnalysisFields.TRANSACTION_ID, id));
            }
            ObjectNode candidate = candidates.addObject()
                .put(AnalysisFields.CANDIDATE_KEY, key)
                .put(AnalysisFields.NORMALIZED_NAME, "합성 반복 후보")
                .put(AnalysisFields.SUGGESTED_AMOUNT_KRW, 50000)
                .put(AnalysisFields.SUGGESTED_DAY, 25);
            candidate.set(
                AnalysisFields.RULE_VERSION,
                input.path(AnalysisFields.CONTEXT)
                    .get(AnalysisFields.RULE_VERSION)
            );
            candidate.set(
                AnalysisFields.SOURCE_VERSION,
                input.path(AnalysisFields.CONTEXT)
                    .get(AnalysisFields.SOURCE_VERSION)
            );
            candidate.set(AnalysisFields.EVIDENCE_TRANSACTION_IDS, evidence.deepCopy());
            ObjectNode features = candidate.putObject(AnalysisFields.FEATURES)
                .put(AnalysisFields.OCCURRENCE_COUNT, 3)
                .put(AnalysisFields.DAY_WITHIN_RULE, true)
                .put(AnalysisFields.AMOUNT_WITHIN_RULE, true)
                .put(AnalysisFields.HAS_UNRESOLVED_REVERSAL, false);
            features.putArray(AnalysisFields.OBSERVED_MONTHS)
                .add("2026-08")
                .add("2026-09")
                .add("2026-10");
        }
        return input;
    }

    /**
     * 전달 검증용 미상 결과 하나만 만들며 정확도 평가 정답으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 부분 조회 테스트
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private ObjectNode output(ObjectNode input, int index) {
        JsonNode source = input.path(AnalysisFields.ITEMS).get(index);
        ObjectNode output = JSON.createObjectNode()
            .put(AnalysisFields.MEANING_POLICY_VERSION, AnalysisValues.MEANING_VERSION);
        ObjectNode item = output.putArray(AnalysisFields.ITEMS)
            .addObject()
            .put(AnalysisFields.ITEM_KEY, source.path(AnalysisFields.ITEM_KEY).asString())
            .put(AnalysisFields.REASON, "현재 근거만으로 확정할 수 없습니다.");
        item.set(
            AnalysisFields.EVIDENCE_TRANSACTION_IDS,
            source.path(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
                .deepCopy()
        );
        item.putObject(AnalysisFields.MEANING)
            .put(AnalysisFields.STATUS, AnalysisValues.UNKNOWN)
            .putNull(AnalysisFields.VALUE)
            .put(AnalysisFields.REASON_CODE, "insufficient_evidence");
        if (input.path(AnalysisFields.SEMANTIC_TASK_KIND)
            .asString()
            .equals(AnalysisValues.TRANSACTION_MEANING)) {
            item.putObject(AnalysisFields.CLASSIFICATION)
                .put(AnalysisFields.STATUS, AnalysisValues.UNKNOWN)
                .putNull(AnalysisFields.VALUE)
                .put(AnalysisFields.REASON_CODE, "insufficient_evidence");
        } else {
            item.set(AnalysisFields.CANDIDATE_KEY, source.get(AnalysisFields.CANDIDATE_KEY));
            item.putNull(AnalysisFields.NAME);
        }
        return output;
    }

    /**
     * 검증할 분류 후보를 허용된 상태와 사유로 함께 설정한다.
     * @created 2026-11-01
     * @usedBy preservesClassificationChecks, preservesRelationEvidence
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private void decision(ObjectNode item, String field, String value) {
        item.putObject(field)
            .put(AnalysisFields.STATUS, AnalysisValues.CANDIDATE)
            .put(AnalysisFields.VALUE, value)
            .put(AnalysisFields.REASON_CODE, AnalysisValues.SUPPORTED);
    }
}
