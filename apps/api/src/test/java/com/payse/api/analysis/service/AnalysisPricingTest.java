package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.payse.ai.provider.dto.TokenUsage;
import com.payse.api.ApiTestConstants.Execution;
import com.payse.api.analysis.mapper.AnalysisCosts;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 토큰·할인 미확인·올림·승인 정책 누락의 비용 경계를 검사한다.
 * @created 2026-11-03
 * @usedBy Gradle JUnit
 */
class AnalysisPricingTest {
    /**
     * 로컬 무료 키 정책을 운영 Google KMS 구성으로 잘못 적용하면 시작 전에 거절한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void rejectsFreeGoogleKms(@TempDir Path directory) throws Exception {
        Path llm = directory.resolve("llm.properties");
        Path token = directory.resolve("kms.token");
        Path settings = directory.resolve("analysis.properties");
        Files.writeString(llm, "enabled=true\nprovider=openai\nmodel=" + Execution.MODEL
            + "\napiKey=test-key\nreasoningEffort=none\n");
        Files.writeString(token, "test-token");
        Files.writeString(settings, "enabled=true\nllmSettingsFile="
            + llm.toString().replace('\\', '/') + "\nkmsTokenFile="
            + token.toString().replace('\\', '/')
            + "\nkmsKey=projects/test/locations/global/keyRings/test/cryptoKeys/test"
            + "\nprojectId=" + Execution.PROJECT + "\npricingVersion=" + Execution.VERSION);
        AnalysisCosts costs = mock(AnalysisCosts.class);
        ObjectNode policy = prices().put("kmsMicros", 0);
        when(costs.policy(Execution.PROJECT, Execution.VERSION)).thenReturn(policy);
        assertThrows(
            IllegalArgumentException.class,
            () -> new AnalysisConfiguration().analysisRuntime(settings.toString(), costs)
        );
        verify(costs).policy(Execution.PROJECT, Execution.VERSION);
    }

    /**
     * 명시한 무료 키 보호 비용과 누락된 비용은 구분한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void acceptsExplicitFreeKeyProtection() {
        ObjectNode policy = prices().put("kmsMicros", 0);
        assertEquals(0, new AnalysisPricing(policy, Execution.MODEL).kmsMicros());
        policy.remove("kmsMicros");
        assertThrows(
            IllegalArgumentException.class,
            () -> new AnalysisPricing(policy, Execution.MODEL)
        );
    }

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
