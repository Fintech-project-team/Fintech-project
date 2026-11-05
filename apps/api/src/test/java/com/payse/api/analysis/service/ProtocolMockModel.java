package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisFields;

import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 공개 규격 검사 전용 공급자다. 거래를 해석하거나 실제 모델·외부 API를 호출하지 않는다.
 * @created 2026-11-04
 * @usedBy ProtocolMockConfig, ProtocolMockTest
 */
final class ProtocolMockModel implements ModelFactory {
    private final String scenario;
    private final int delay;
    private final AtomicInteger calls = new AtomicInteger();

    /**
     * 독립 서버에서 재현할 성공·유보·최초 실패와 유한 지연만 허용한다.
     * @created 2026-11-04
     * @usedBy ProtocolMockConfig
     */
    ProtocolMockModel(String scenario, int delay) {
        var scenarios = Set.of(
            "success",
            "unknown",
            "invalid_once",
            "timeout_once"
        );
        if (!scenarios.contains(scenario)
            || delay < 0 || delay > 10000) {
            throw new IllegalArgumentException("Invalid protocol mock configuration");
        }
        this.scenario = scenario;
        this.delay = delay;
    }

    /**
     * 결과 재사용을 다른 모의 실행과 구분할 고정 모드다.
     * @created 2026-11-04
     * @usedBy ProtocolMockConfig
     */
    String scenario() {
        return scenario;
    }

    /**
     * 숨은 재호출 부재를 검사하기 위한 공급자 생성 횟수다.
     * @created 2026-11-04
     * @usedBy ProtocolMockTest
     */
    int calls() {
        return calls.get();
    }

    /**
     * 실제 서비스와 같은 스키마를 받되 네트워크 전송 구현은 갖지 않는다.
     * @created 2026-11-04
     * @usedBy AnalysisService
     */
    @Override
    public ModelGateway create(String instructions, ObjectNode schema) {
        return new ModelGateway() {
            /**
             * 프로토콜 검사만을 위한 모의 토큰 수로 실제 사용량이 아니다.
             * @created 2026-11-04
             * @usedBy AnalysisService
             */
            @Override
            public long countInput(JsonNode input) {
                return 100;
            }

            /**
             * 명시된 첫 실패 외에는 모든 항목을 형식 검증 가능한 결과로 반환한다.
             * @created 2026-11-04
             * @usedBy AnalysisService
             */
            @Override
            public ModelReply generate(JsonNode input) {
                int call = calls.incrementAndGet();
                try {
                    Thread.sleep(delay);
                } catch (InterruptedException failure) {
                    Thread.currentThread().interrupt();
                    throw new IllegalStateException("Mock interrupted");
                }
                if (call == 1 && scenario.equals("timeout_once")) {
                    throw new ModelFailure(
                        "TRANSMISSION_UNKNOWN",
                        ModelFailure.Stage.GENERATION,
                        true
                    );
                }
                if (call == 1 && scenario.equals("invalid_once")) {
                    return new ModelReply(
                        AnalysisJson.JSON.createObjectNode(),
                        new TokenUsage(100, null, 10),
                        null
                    );
                }
                ObjectNode response = AnalysisJson.JSON.createObjectNode();
                var output = response.putObject(AnalysisFields.OUTPUT)
                    .put(AnalysisFields.MEANING_POLICY_VERSION, "PAYSE-MEANING-1");
                var rows = output.putArray(AnalysisFields.ITEMS);
                var memories = response.putArray(AnalysisFields.MEMORIES);
                boolean recurring = input.path(AnalysisFields.SEMANTIC_TASK_KIND)
                    .asString()
                    .equals("recurringMeaning");
                for (JsonNode requested : input.path(AnalysisFields.ITEMS)) {
                    String key = requested.path(AnalysisFields.ITEM_KEY).asString();
                    var row = rows.addObject().put(AnalysisFields.ITEM_KEY, key);
                    row.set(
                        AnalysisFields.EVIDENCE_TRANSACTION_IDS,
                        requested.path(AnalysisFields.EVIDENCE_TRANSACTION_IDS).deepCopy()
                    );
                    row.put(AnalysisFields.REASON, "모의 공급자의 연동 확인용 결과입니다.");
                    boolean known = recurring && !scenario.equals("unknown");
                    decision(row, AnalysisFields.MEANING, known ? "telecom" : null);
                    if (recurring) {
                        row.set(
                            AnalysisFields.CANDIDATE_KEY,
                            requested.path(AnalysisFields.CANDIDATE_KEY)
                        );
                        row.put(AnalysisFields.NAME, "모의 반복 후보");
                    } else {
                        String classification = null;
                        for (JsonNode value : requested.path("existingClassifications")) {
                            if (value.path(AnalysisFields.TRANSACTION_ID).equals(
                                requested.path(AnalysisFields.TARGET_TRANSACTION_ID)
                            )) {
                                classification = value.path(AnalysisFields.VALUE).asString(null);
                            }
                        }
                        decision(row, AnalysisFields.CLASSIFICATION, classification);
                    }
                    memories.addObject()
                        .put(AnalysisFields.ITEM_KEY, key)
                        .put(AnalysisFields.ACTIVE, true)
                        .put(AnalysisFields.IS_REFERENCE, true)
                        .put(AnalysisFields.IMPORTANT, false)
                        .put(AnalysisFields.REFERENCE_POLICY, "optional")
                        .put(AnalysisFields.REASON, "모의 연동 확인");
                }
                return new ModelReply(response, new TokenUsage(100, null, 80), null);
            }
        };
    }

    /**
     * 모의 응답도 값·상태·사유의 기존 일관성을 유지한다.
     * @created 2026-11-04
     * @usedBy generate
     */
    private static void decision(ObjectNode item, String field, String value) {
        var result = item.putObject(field)
            .put(AnalysisFields.STATUS, value == null ? "unknown" : "candidate")
            .put(AnalysisFields.REASON_CODE, value == null ? "insufficient_evidence" : "supported");
        if (value == null) {
            result.putNull(AnalysisFields.VALUE);
        } else {
            result.put(AnalysisFields.VALUE, value);
        }
    }
}
