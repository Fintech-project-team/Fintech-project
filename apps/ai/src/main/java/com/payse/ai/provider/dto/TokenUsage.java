package com.payse.ai.provider.dto;

/**
 * 금액으로 임의 환산하지 않은 공급자 토큰 사용량이다. 캐시 미확인은 null로 구분한다.
 * @created 2026-10-29
 * @usedBy ModelReply, OpenAiGateway, 미연결: 예정 사용처 API 비용 정산
 * @modified 2026-11-01 - 공유 AI 공급자 DTO로 분리
 */
public record TokenUsage(long inputTokens, Long cachedTokens, long outputTokens) {
    /**
     * 공급자가 달라도 음수·캐시 초과를 거절한다. 전체 사용량 미확인은 ModelReply.usage=null이다.
     * @created 2026-11-01
     * @usedBy 공급자 응답 정규화, 서비스 테스트
     */
    public TokenUsage {
        if (inputTokens < 0 || outputTokens < 0
                || (cachedTokens != null && (cachedTokens < 0 || cachedTokens > inputTokens))) {
            throw new IllegalArgumentException("Valid token usage required");
        }
    }
}
