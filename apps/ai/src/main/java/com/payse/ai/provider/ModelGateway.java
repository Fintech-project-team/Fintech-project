package com.payse.ai.provider;

import tools.jackson.databind.JsonNode;
import com.payse.ai.provider.dto.ModelReply;

/**
 * 업무 실행이 사용하는 공급자 경계다. 테스트도 이 경계만 대역으로 교체한다.
 * @created 2026-11-01
 * @usedBy AnalysisService, OpenAiGateway
 */
public interface ModelGateway {
    /**
     * 같은 지침·스키마·입력과 모델 템플릿의 토큰을 계수한다. 로컬 계수 또는 공급자 조회를 사용한다.
     * 정확한 계수/검증된 상한 산정이 불가능하면 INPUT_TOKENS_UNAVAILABLE로 실패하며 0을 만들지 않는다.
     * 공급자 전송 실패는 INPUT_COUNT 단계로 전달하고 생성은 하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    long countInput(JsonNode input);

    /**
     * 명시된 모델·출력 한도로 한 번 생성한다. 자동 재시도·다른 공급자로의 전환은 하지 않는다.
     * 공급자별 출력·사용량은 ModelReply로 정규화하고 전송 실패는 GENERATION 단계로 전달한다.
     * 업무 결과 검증은 AnalysisService에서 수행한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    ModelReply generate(JsonNode input);

}
