package com.payse.ai.analysis.service;

import com.payse.ai.provider.dto.ModelReply;

import com.payse.ai.analysis.mapper.InputMapper;
import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelGateway;

import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelFailure.Stage;
import java.util.Objects;
import tools.jackson.databind.node.ObjectNode;

/**
 * 입력 검증·최소 투영·단일 생성·출력 복원을 수행한다. 금융 저장이나 인증을 대신하지 않는다.
 * @created 2026-11-01
 * @usedBy AnalysisServiceTest, 미연결: 예정 사용처 API 분석 작업 실행 서비스
 */
public final class AnalysisService {
    private final AnalysisContract contract;
    private final ModelFactory models;
    private final int inputLimit;

    /**
     * 승인된 공급자 구성과 입력 한도를 명시적으로 받는다. 생성 시 공급자를 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisServiceTest, 미연결: 예정 사용처 API 실행 구성
     */
    public AnalysisService(ModelFactory models, int inputLimit) {
        this.models = Objects.requireNonNull(models, "models");
        if (inputLimit < 1) throw new IllegalArgumentException("Explicit input limit required");
        this.inputLimit = inputLimit;
        contract = new AnalysisContract();
    }

    /**
     * API 권한·원천·재사용·예산 확인 후에만 호출한다. 이 메서드 성공은 DB 채택 완료가 아니다.
     * @created 2026-11-01
     * @usedBy AnalysisServiceTest, 미연결: 예정 사용처 API 작업 실행
     */
    public ModelReply analyze(ObjectNode payload) {
        InputMapper mapper = new InputMapper(payload, contract);
        ModelGateway model = Objects.requireNonNull(models.create(contract.instructions(), mapper.schema()), "model");
        long tokens = model.countInput(mapper.input());
        if (tokens < 0) throw new ModelFailure("INVALID_TOKEN_COUNT", Stage.GENERATION, false);
        if (tokens > inputLimit) throw new ModelFailure("INPUT_TOKEN_LIMIT", Stage.GENERATION, false);
        ModelReply reply = model.generate(mapper.input());
        if (reply == null) throw new ModelFailure("INVALID_PROVIDER_RESPONSE", Stage.GENERATION, true);
        if (reply.failure() != null) return new ModelReply(null, reply.usage(), reply.failure());
        try {
            return new ModelReply(mapper.restore(reply.output()), reply.usage(), null);
        } catch (ContractFailure failure) {
            return new ModelReply(null, reply.usage(), "INVALID_MODEL_OUTPUT");
        }
    }
}
