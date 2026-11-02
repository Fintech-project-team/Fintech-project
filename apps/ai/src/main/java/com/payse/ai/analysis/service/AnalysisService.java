package com.payse.ai.analysis.service;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.mapper.InputMapper;
import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.analysis.validation.StorageContract;
import com.payse.ai.constants.AiCodeConstants.Provider;
import com.payse.ai.constants.AiMessageConstants.Analysis;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelFailure.Stage;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import java.util.List;
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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    public AnalysisService(ModelFactory models, int inputLimit) {
        this.models = Objects.requireNonNull(models, Analysis.MODELS_PARAMETER);
        if (inputLimit < 1) {
            throw new IllegalArgumentException(Analysis.MISSING_INPUT_LIMIT);
        }
        this.inputLimit = inputLimit;
        contract = new AnalysisContract();
    }

    /**
     * API 권한·원천·재사용·예산 확인 후에만 호출한다. 이 메서드 성공은 DB 채택 완료가 아니다.
     * @created 2026-11-01
     * @usedBy AnalysisServiceTest, 미연결: 예정 사용처 API 작업 실행
     * @modified 2026-11-01 - 저장용 호출과 계수·생성 정책을 공유하고 기존 의미 반환 계약 유지
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    public ModelReply analyze(ObjectNode payload) {
        InputMapper mapper = new InputMapper(payload, contract);

        ModelReply reply = generate(mapper, contract.instructions(), mapper.schema());
        if (reply.failure() != null) {
            return new ModelReply(null, reply.usage(), reply.failure());
        }

        try {
            return new ModelReply(mapper.restore(reply.output()), reply.usage(), null);
        } catch (ContractFailure failure) {
            return new ModelReply(null, reply.usage(), Provider.INVALID_MODEL_OUTPUT);
        }
    }

    /**
     * 한 공급자 응답에서 기존 의미 출력과 보존 제안을 받는다. DB 저장·채택은 수행하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisStorageTest, 미연결: 예정 사용처 API 분석 worker
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    public AnalysisResult analyzeForStorage(ObjectNode payload) {
        InputMapper mapper = new InputMapper(payload, contract);

        ModelReply reply = generate(
            mapper,
            contract.instructions() + "\n" + StorageContract.instructions(),
            mapper.storageSchema()
        );
        if (reply.failure() != null) {
            return new AnalysisResult(null, List.of(), reply.usage(), reply.failure());
        }

        try {
            return mapper.restoreStorage(reply.output(), reply.usage());
        } catch (ContractFailure failure) {
            return new AnalysisResult(
                null,
                List.of(),
                reply.usage(),
                Provider.INVALID_MODEL_OUTPUT
            );
        }
    }

    /**
     * 의미 전용과 저장용이 같은 계수·단일 생성·전송 실패 정책을 사용한다.
     * @created 2026-11-01
     * @usedBy analyze, analyzeForStorage
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    private ModelReply generate(InputMapper mapper, String instructions, ObjectNode schema) {
        ModelGateway model = Objects
            .requireNonNull(models.create(instructions, schema), Analysis.MODEL_PARAMETER);
        long tokens = model.countInput(mapper.input());
        if (tokens < 0) {
            throw new ModelFailure(Provider.INVALID_TOKEN_COUNT, Stage.GENERATION, false);
        }
        if (tokens > inputLimit) {
            throw new ModelFailure(Provider.INPUT_TOKEN_LIMIT, Stage.GENERATION, false);
        }

        ModelReply reply = model.generate(mapper.input());
        if (reply == null) {
            throw new ModelFailure(Provider.INVALID_PROVIDER_RESPONSE, Stage.GENERATION, true);
        }
        return reply;
    }
}
