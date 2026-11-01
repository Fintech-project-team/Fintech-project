package com.payse.ai.analysis.validation;

/**
 * 민감한 입력 없이 내부 계약 오류 코드만 전달한다.
 * @created 2026-11-01
 * @usedBy SchemaRules, AnalysisContract, InputMapper
 */
public final class ContractFailure extends IllegalArgumentException {
    /**
     * 호출부가 정한 상수 사유만 보존한다. 입력값을 사유에 넣지 않는다.
     * @created 2026-11-01
     * @usedBy 계약 검증 메서드
     */
    public ContractFailure(String reason) { super(reason); }
}
