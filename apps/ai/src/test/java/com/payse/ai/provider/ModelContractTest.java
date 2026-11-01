package com.payse.ai.provider;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import org.junit.jupiter.api.Test;

/**
 * 공급자 구현과 무관하게 사용량·실패 원문의 공통 경계를 검사한다.
 * @created 2026-11-01
 * @usedBy JUnit
 */
class ModelContractTest {
    /**
     * 미확인 사용량과 확인된 0을 구별하고 정수 상한까지 임의 합산하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesUnknownUsage() {
        assertNull(new ModelReply(null, null, "MODEL_REFUSAL").usage());
        assertNull(new TokenUsage(10, null, 5).cachedTokens());
        assertEquals(0L, new TokenUsage(10, 0L, 5).cachedTokens());
        assertEquals(Long.MAX_VALUE, new TokenUsage(Long.MAX_VALUE, Long.MAX_VALUE, Long.MAX_VALUE).inputTokens());
    }

    /**
     * 다른 공급자가 정규화한 사용량도 음수·캐시 초과이면 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidUsage() {
        assertThrows(IllegalArgumentException.class, () -> new TokenUsage(-1, null, 0));
        assertThrows(IllegalArgumentException.class, () -> new TokenUsage(1, null, -1));
        assertThrows(IllegalArgumentException.class, () -> new TokenUsage(1, -1L, 0));
        assertThrows(IllegalArgumentException.class, () -> new TokenUsage(1, 2L, 0));
    }

    /**
     * 공급자 원문을 실패 코드로 쓰면 민감 내용 없는 구성 오류로 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsRawFailureDetails() {
        String secret = "provider-private-response";
        var callFailure = assertThrows(IllegalArgumentException.class,
            () -> new ModelFailure(secret, ModelFailure.Stage.GENERATION, true));
        var replyFailure = assertThrows(IllegalArgumentException.class,
            () -> new ModelReply(null, null, secret));
        for (var failure : java.util.List.of(callFailure, replyFailure)) {
            assertFalse(failure.toString().contains(secret));
            assertNull(failure.getCause());
        }
    }
}
