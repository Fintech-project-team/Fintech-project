package com.payse.ai.analysis.dto;

import com.payse.ai.constants.AiConfigConstants.Memory;
import com.payse.ai.constants.AiMessageConstants.Analysis;
import java.util.Set;

/**
 * 입력 항목에 대응하는 보존 제안이다. 소유권·현재 근거·실제 저장 여부는 API가 검증한다.
 * @created 2026-11-01
 * @usedBy StorageContract.decisions, AnalysisResult
 */
public record MemoryDecision(
    String itemKey,
    boolean active,
    boolean isReference,
    boolean important,
    String referencePolicy,
    String reason
) {

    /**
     * 의미 없는 중요보존 조합과 누락·초과 사유를 거절한다. 참조 정책은 저장 권한이 아니다.
     * @created 2026-11-01
     * @usedBy StorageContract.decisions
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조
     */
    public MemoryDecision {
        if (itemKey == null
            || itemKey.isBlank()
            || (important && !isReference)
            || referencePolicy == null
            || !Set.of(Memory.OPTIONAL_REFERENCE, Memory.REFERENCE_REQUIRED)
                .contains(referencePolicy)
            || reason == null
            || reason.isBlank()
            || reason.codePointCount(0, reason.length()) > 240) {
            throw new IllegalArgumentException(Analysis.INVALID_MEMORY);
        }
    }

    /**
     * 사유·입력 식별자를 자동 로그에 남기지 않는다.
     * @created 2026-11-01
     * @usedBy Java 문자열 변환
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조
     */
    @Override
    public String toString() {
        return Analysis.REDACTED_MEMORY;
    }
}
