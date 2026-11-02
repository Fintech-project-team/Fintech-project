package com.payse.ai.provider.dto;

import com.payse.ai.constants.AiMessageConstants.Provider;

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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조
     */
    public TokenUsage {
        if (inputTokens < 0
            || outputTokens < 0
            || (cachedTokens != null && (cachedTokens < 0 || cachedTokens > inputTokens))) {
            throw new IllegalArgumentException(Provider.INVALID_USAGE);
        }
    }
}
