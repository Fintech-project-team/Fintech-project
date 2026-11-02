package com.payse.ai.analysis.dto;

import com.payse.ai.constants.AiMessageConstants.Analysis;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import java.util.List;
import tools.jackson.databind.node.ObjectNode;

/**
 * 검증된 의미·보존 제안과 사용량을 전달한다. 암호화나 DB 채택 완료를 뜻하지 않는다.
 * @created 2026-11-01
 * @usedBy AnalysisService.analyzeForStorage, 미연결: 예정 사용처 API 분석 worker
 */
public record AnalysisResult(
    ObjectNode output,
    List<MemoryDecision> memories,
    TokenUsage usage,
    String failure
) {

    /**
     * 실패를 빈 성공으로 바꾸지 않고 가변 출력·목록을 호출자와 분리한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyzeForStorage, InputMapper.restoreStorage
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    public AnalysisResult {
        if (memories == null) {
            throw new IllegalArgumentException(Analysis.MISSING_MEMORIES);
        }
        memories = List.copyOf(memories);
        if (failure == null) {
            if (output == null || memories.isEmpty()) {
                throw new IllegalArgumentException(Analysis.INCOMPLETE_ANALYSIS);
            }
            output = output.deepCopy();
        } else {
            new ModelReply(null, usage, failure);
            if (output != null || !memories.isEmpty()) {
                throw new IllegalArgumentException(Analysis.FAILED_ANALYSIS_RESULT);
            }
        }
    }

    /**
     * 저장 서비스가 수정해도 검증 결과 자체가 바뀌지 않도록 사본을 반환한다.
     * @created 2026-11-01
     * @usedBy 미연결: 예정 사용처 API 분석 결과 저장
     */
    @Override
    public ObjectNode output() {
        return output == null ? null : output.deepCopy();
    }

    /**
     * 의미 출력·보존 사유를 자동 로그에 남기지 않는다.
     * @created 2026-11-01
     * @usedBy Java 문자열 변환
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조
     */
    @Override
    public String toString() {
        return Analysis.REDACTED_RESULT;
    }
}
