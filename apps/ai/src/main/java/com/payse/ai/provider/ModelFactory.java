package com.payse.ai.provider;

import tools.jackson.databind.node.ObjectNode;

/**
 * 승인된 공급자 설정과 요청별 지침·스키마를 조합한다. 자격·모델·토크나이저의 임의 기본값은 없다.
 * 공급자 주소/옵션은 구현 내부에만 두고 금융 입력에서 선택하지 않는다.
 * @created 2026-11-01
 * @usedBy AnalysisService.analyze, 미연결: 예정 사용처 API 분석 실행 구성
 */
@FunctionalInterface
public interface ModelFactory {
    /**
     * 해당 요청에 고정된 게이트웨이를 만든다. 이 단계에서 전송하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    ModelGateway create(String instructions, ObjectNode schema);
}
