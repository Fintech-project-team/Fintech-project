package com.payse.ai.provider.dto;

import tools.jackson.databind.node.ObjectNode;
import java.util.Set;

/**
 * 메모리 전용 결과다. failure와 정상 unknown을 구분하고 사용량 미확정을 보존한다.
 * @created 2026-10-29
 * @usedBy ModelGateway.generate, AnalysisService.analyze
 * @modified 2026-11-01 - 공유 AI 공급자 DTO로 분리
 */
public record ModelReply(ObjectNode output, TokenUsage usage, String failure) {
    /**
     * 실패 코드는 알려진 내부 값만 허용하고 공급자 원문을 결과로 전달하지 않는다.
     * @created 2026-11-01
     * @usedBy 공급자 응답 정규화, AnalysisService.analyze
     */
    public ModelReply {
        if (failure != null && !Set.of("MODEL_REFUSAL", "INCOMPLETE_RESPONSE",
                "INVALID_PROVIDER_RESPONSE", "INVALID_MODEL_OUTPUT").contains(failure)) {
            throw new IllegalArgumentException("Known model reply failure required");
        }
    }

    /**
     * 해석 원문을 자동 문자열 변환에서 제외한다.
     * @created 2026-10-29
     * @usedBy Java 문자열 변환
     */
    @Override
    public String toString() { return "AnalysisReply[REDACTED]"; }
}
