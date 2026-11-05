package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import com.payse.api.ApiTestConstants.Execution;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.analysis.provider.CostedModel;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 운영 실행 구성에서 실제 AI 서비스를 비용 장부와 연결해 호출 순서·입력 실패를 검사한다.
 * @created 2026-11-03
 * @usedBy Gradle JUnit
 */
class AnalysisRuntimeTest {
    private final AnalysisCosts costs = mock(AnalysisCosts.class);
    private final ModelFactory models = mock(ModelFactory.class);
    private final ModelGateway provider = mock(ModelGateway.class);
    private final UUID attempt = UUID.randomUUID();

    /**
     * 접수 예약·계수·생성·관측 사용량 보존이 같은 시도 식별을 쓴다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void runsWithDurableReservationBoundary() throws Exception {
        AnalysisRuntime runtime = runtime();
        when(models.create(any(String.class), any(ObjectNode.class))).thenReturn(provider);
        when(costs.start(eq(Execution.PROJECT), any(UUID.class))).thenReturn(true);
        when(provider.countInput(any(JsonNode.class))).thenReturn(100L);
        when(provider.generate(any(JsonNode.class))).thenReturn(
            new ModelReply(null, new TokenUsage(100, null, 50), "MODEL_REFUSAL")
        );
        runtime.reserve(attempt);
        ObjectNode input = (ObjectNode) AnalysisJson.JSON.readTree(
            Files.readString(Path.of("../ai/build/test-data/service-input.json"))
        );
        assertEquals("MODEL_REFUSAL", runtime.analyze(attempt, input, null).failure());
        verify(costs).reserve(Execution.PROJECT, attempt, Execution.VERSION, "model", 16000);
        verify(costs).reserve(
            Execution.PROJECT, CostedModel.countingId(attempt), Execution.VERSION, "counting", 7
        );
        verify(costs).settle(Execution.PROJECT, attempt, 400);
        verify(costs).releaseUnstarted(Execution.PROJECT, attempt);
        assertThrows(IllegalStateException.class, () -> runtime.analyze(input));
    }

    /**
     * 원천·계약 오류 시 공급자를 부르지 않고 미전송 예약만 반납한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void releasesUnstartedOnInputFailure() {
        AnalysisRuntime runtime = runtime();
        ObjectNode input = AnalysisJson.JSON.createObjectNode();
        assertThrows(ContractFailure.class, () -> runtime.analyze(attempt, input, null));
        verifyNoInteractions(models, provider);
        verify(costs).releaseUnstarted(Execution.PROJECT, attempt);
        verify(costs).releaseUnstarted(Execution.PROJECT, CostedModel.countingId(attempt));
    }

    /**
     * 실제 설정 연결과 같은 비용 실행 문맥에 네트워크 대역만 주입한다.
     * @created 2026-11-03
     * @usedBy 테스트 메서드
     */
    private AnalysisRuntime runtime() {
        AnalysisPricing pricing = new AnalysisPricing(
            (ObjectNode) AnalysisJson.JSON.readTree(Execution.PRICES),
            Execution.MODEL
        );
        ObjectNode versions = AnalysisJson.JSON.createObjectNode()
            .put("model", Execution.MODEL)
            .put("prompt", "test-prompt")
            .put("response", "test-response")
            .put("policy", Execution.VERSION);
        return new AnalysisRuntime(
            new AnalysisService(models, 6000),
            new EnvelopeCipher(mock(KeyProtector.class)),
            versions,
            new AnalysisRuntime.Execution(
                models, costs, pricing, Execution.PROJECT, Execution.VERSION
            )
        );
    }
}
