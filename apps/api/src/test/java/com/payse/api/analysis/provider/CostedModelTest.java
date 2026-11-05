package com.payse.api.analysis.provider;

import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import com.payse.api.ApiTestConstants.Execution;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.analysis.service.AnalysisJson;
import com.payse.api.analysis.service.AnalysisPricing;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 비용 어댑터를 호출하고 공급자·저장소의 전송 및 정산 순서를 대조한다.
 * @created 2026-11-03
 * @usedBy Gradle JUnit
 */
class CostedModelTest {
    private final AnalysisCosts costs = mock(AnalysisCosts.class);
    private final ModelGateway provider = mock(ModelGateway.class);
    private final UUID attempt = UUID.randomUUID();
    private final ObjectNode input = AnalysisJson.JSON.createObjectNode();
    private final AnalysisPricing pricing = new AnalysisPricing(
        (ObjectNode) AnalysisJson.JSON.readTree(Execution.PRICES),
        Execution.MODEL
    );
    private final CostedModel model = new CostedModel(
        provider, costs, pricing, Execution.PROJECT, attempt
    );

    /**
     * 전송권이 없으면 계수·생성 모두 외부 호출하지 않는다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void blocksBeforeProvider() {
        assertThrows(ModelFailure.class, () -> model.countInput(input));
        assertThrows(ModelFailure.class, () -> model.generate(input));
        verifyNoInteractions(provider);
    }

    /**
     * 응답의 의미가 거절되어도 관측한 사용량은 정산하며 계수 비용과 구분한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void settlesObservedUsageBeforeReturning() {
        UUID count = CostedModel.countingId(attempt);
        when(costs.start(eq(Execution.PROJECT), any(UUID.class))).thenReturn(true);
        when(provider.countInput(input)).thenReturn(100L);
        when(provider.generate(input)).thenReturn(
            new ModelReply(null, new TokenUsage(100, null, 50), "MODEL_REFUSAL")
        );
        model.countInput(input);
        model.generate(input);
        var order = inOrder(costs, provider);
        order.verify(costs).start(Execution.PROJECT, count);
        order.verify(provider).countInput(input);
        order.verify(costs).settle(Execution.PROJECT, count, 7);
        order.verify(costs).start(Execution.PROJECT, attempt);
        order.verify(provider).generate(input);
        order.verify(costs).settle(Execution.PROJECT, attempt, 400);
    }

    /**
     * 사용량 미확인과 전송 실패는 0으로 정산하지 않는다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void preservesUnknownCharges() {
        when(costs.start(Execution.PROJECT, attempt)).thenReturn(true);
        when(provider.generate(input)).thenReturn(new ModelReply(input, null, null));
        model.generate(input);
        verify(costs, never()).settle(eq(Execution.PROJECT), any(UUID.class), anyLong());
        when(provider.generate(input)).thenThrow(
            new ModelFailure("TRANSMISSION_UNKNOWN", ModelFailure.Stage.GENERATION, true)
        );
        assertThrows(ModelFailure.class, () -> model.generate(input));
        verify(costs, never()).notSent(eq(Execution.PROJECT), any(UUID.class));
    }

    /**
     * 공급자가 전송 전 실패를 확정한 경우에만 예약을 반납한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void releasesOnlyConfirmedNotSent() {
        when(costs.start(Execution.PROJECT, attempt)).thenReturn(true);
        when(provider.generate(input)).thenThrow(
            new ModelFailure("CREDENTIAL_UNAVAILABLE", ModelFailure.Stage.GENERATION, false)
        );
        assertThrows(ModelFailure.class, () -> model.generate(input));
        verify(costs).notSent(Execution.PROJECT, attempt);
        verify(costs, never()).settle(eq(Execution.PROJECT), any(UUID.class), anyLong());
    }
}
