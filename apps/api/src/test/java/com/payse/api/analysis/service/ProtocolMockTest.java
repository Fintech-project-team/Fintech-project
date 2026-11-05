package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisFields;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFailure;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.node.ObjectNode;

/**
 * 모의 공급자도 실제 AI 계약 검증을 통과하고 숨은 재시도를 하지 않는지 확인한다.
 * @created 2026-11-04
 * @usedBy JUnit
 */
class ProtocolMockTest {
    /**
     * 성공·정상 유보·형식 실패·완료 불명을 구분하고 명시 두 번째 호출만 복구한다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void keepsScenariosAndAttemptsSeparate() throws Exception {
        var vectors = AnalysisJson.JSON.readTree(Files.readString(
            Path.of("testing/protocol/fixtures/identity-vectors.json")
        ));
        ObjectNode input = (ObjectNode) vectors.path("cases").get(21).path(AnalysisFields.INPUT);
        String[] scenarios = {
            "success",
            "unknown",
            "invalid_once",
            "timeout_once"
        };
        for (String mode : scenarios) {
            var model = new ProtocolMockModel(mode, 0);
            var service = new AnalysisService(model, 6000);
            if (mode.equals("timeout_once")) {
                assertThrows(ModelFailure.class, () -> service.analyzeForStorage(input));
            } else {
                var result = service.analyzeForStorage(input);
                if (mode.equals("invalid_once")) {
                    assertEquals("INVALID_MODEL_OUTPUT", result.failure());
                } else {
                    assertNull(result.failure());
                    String status = result.output()
                        .path(AnalysisFields.ITEMS)
                        .get(0)
                        .path(AnalysisFields.MEANING)
                        .path(AnalysisFields.STATUS)
                        .asString();
                    assertEquals(
                        mode.equals("unknown") ? "unknown" : "candidate",
                        status
                    );
                }
            }
            assertEquals(1, model.calls());
            assertNull(service.analyzeForStorage(input).failure());
            assertEquals(2, model.calls());
        }
    }
}
