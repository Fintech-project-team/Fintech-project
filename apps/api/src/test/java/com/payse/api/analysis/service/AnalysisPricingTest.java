package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.payse.ai.provider.dto.TokenUsage;
import com.payse.api.ApiTestConstants.Execution;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 토큰·할인 미확인·올림·승인 정책 누락의 비용 경계를 검사한다.
 * @created 2026-11-03
 * @usedBy Gradle JUnit
 */
class AnalysisPricingTest {
    /**
     * 입력·출력 최대 예약과 관측 캐시 할인은 독립 기대값과 일치한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void reservesMaximumAndSettlesUsage() {
        AnalysisPricing pricing = new AnalysisPricing(prices(), Execution.MODEL);
        assertEquals(16000, pricing.maximum());
        assertEquals(375, pricing.cost(new TokenUsage(100, 25L, 50)));
        assertEquals(400, pricing.cost(new TokenUsage(100, null, 50)));
        assertThrows(IllegalArgumentException.class, () -> pricing.cost(null));
    }

    /**
     * 원화 백만분의 일 미만도 올림하고 누락·음수·모델 불일치를 거절한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void roundsUpAndRejectsUnapprovedRates() {
        ObjectNode policy = prices().put("inputMicrosPerMillion", 1)
            .put("cachedMicrosPerMillion", 0);
        assertEquals(
            1,
            new AnalysisPricing(policy, Execution.MODEL).cost(new TokenUsage(1, null, 0))
        );
        assertThrows(IllegalArgumentException.class, () -> new AnalysisPricing(policy, "other"));
        policy.put("inputMicrosPerMillion", -1);
        assertThrows(
            IllegalArgumentException.class,
            () -> new AnalysisPricing(policy, Execution.MODEL)
        );
        ObjectNode missing = prices();
        missing.remove("countingMicros");
        assertThrows(
            IllegalArgumentException.class,
            () -> new AnalysisPricing(missing, Execution.MODEL)
        );
    }

    /**
     * 승인 문서를 대신하지 않는 합성 단가를 새 객체로 만든다.
     * @created 2026-11-03
     * @usedBy 테스트 메서드
     */
    private ObjectNode prices() {
        return (ObjectNode) AnalysisJson.JSON.readTree(Execution.PRICES);
    }
}
