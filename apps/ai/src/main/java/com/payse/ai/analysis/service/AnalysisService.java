package com.payse.ai.analysis.service;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.mapper.InputMapper;
import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
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
    private final PromptGuide guide;

    /**
     * 승인된 공급자 구성과 입력 한도를 명시적으로 받는다. 생성 시 공급자를 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisConfiguration.analysisRuntime, GammaLocalConfig.gammaRuntime, AI 테스트
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-04 - 공급자 중립 교육 자료를 구성에 연결
     */
    public AnalysisService(ModelFactory models, int inputLimit) {
        this.models = Objects.requireNonNull(models, Analysis.MODELS_PARAMETER);
        if (inputLimit < 1) {
            throw new IllegalArgumentException(Analysis.MISSING_INPUT_LIMIT);
        }
        this.inputLimit = inputLimit;
        contract = new AnalysisContract();
        guide = new PromptGuide(contract.instructions());
    }

    /**
     * 실제 사용하는 지침·교육 자료의 내용 지문을 API의 재사용 판정에 제공한다.
     * @created 2026-11-04
     * @usedBy AnalysisConfiguration.analysisRuntime, GammaLocalConfig.gammaRuntime
     */
    public String promptVersion() {
        return guide.version();
    }

    /**
     * API 권한·원천·재사용·예산 확인 후에만 호출한다. 이 메서드 성공은 DB 채택 완료가 아니다.
     * @created 2026-11-01
     * @usedBy AnalysisServiceTest, 미연결: 예정 사용처 API 작업 실행
     * @modified 2026-11-01 - 저장용 호출과 계수·생성 정책을 공유하고 기존 의미 반환 계약 유지
     * @modified 2026-11-04 - 원천 구조에 맞는 공개 교육 예시를 선택하여 전달
     * @modified 2026-11-04 - 본문 없이 제한된 계약 실패 코드 기록
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    public ModelReply analyze(ObjectNode payload) {
        InputMapper mapper = new InputMapper(payload, contract);

        String instructions = guide.instructions(mapper.input(), false);
        ModelReply reply = generate(mapper, instructions, mapper.schema());
        if (reply.failure() != null) {
            return new ModelReply(null, reply.usage(), reply.failure());
        }

        try {
            return new ModelReply(mapper.restore(reply.output()), reply.usage(), null);
        } catch (ContractFailure failure) {
            rejection(failure);
            return new ModelReply(null, reply.usage(), Provider.INVALID_MODEL_OUTPUT);
        }
    }

    /**
     * 한 공급자 응답에서 기존 의미 출력과 보존 제안을 받는다. DB 저장·채택은 수행하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisStorageTest, 미연결: 예정 사용처 API 분석 worker
     * @modified 2026-11-03 - 모델 전용 DB 원천 투영을 받는 실행 경로와 공유
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    public AnalysisResult analyzeForStorage(ObjectNode payload) {
        return analyzeForStorage(payload, null);
    }

    /**
     * API가 인증한 DB 원천 보충만 모델에 전달하고 공개 응답 규격을 유지한다.
     * @created 2026-11-03
     * @usedBy AnalysisRuntime.analyze, analyzeForStorage
     * @modified 2026-11-04 - 저장 지침과 공개 교육 자료를 같은 조립 경로에서 제공
     * @modified 2026-11-04 - 본문 없이 제한된 계약 실패 코드 기록
     */
    public AnalysisResult analyzeForStorage(ObjectNode payload, ObjectNode facts) {
        InputMapper mapper = new InputMapper(payload, contract, facts);

        String instructions = guide.instructions(mapper.input(), true);
        ModelReply reply = generate(mapper, instructions, mapper.storageSchema());
        if (reply.failure() != null) {
            return new AnalysisResult(null, List.of(), reply.usage(), reply.failure());
        }

        try {
            return mapper.restoreStorage(reply.output(), reply.usage());
        } catch (ContractFailure failure) {
            rejection(failure);
            return new AnalysisResult(
                null,
                List.of(),
                reply.usage(),
                Provider.INVALID_MODEL_OUTPUT
            );
        }
    }

    /**
     * 고정 검증 코드만 남겨 자료 노출 없이 구조 실패 원인을 구분한다.
     * @created 2026-11-04
     * @usedBy analyze, analyzeForStorage
     */
    private void rejection(ContractFailure failure) {
        String code = failure.getMessage();
        if (code == null || !code.matches("[A-Z_]{1,80}")) {
            code = Provider.INVALID_MODEL_OUTPUT;
        }
        System.getLogger(AnalysisService.class.getName()).log(
            System.Logger.Level.WARNING,
            Analysis.VALIDATION_FAILURE,
            code
        );
    }

    /**
     * 의미 전용과 저장용이 같은 계수·단일 생성·전송 실패 정책을 사용한다.
     * @created 2026-11-01
     * @usedBy analyze, analyzeForStorage
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-04 - 같은 항목별 근거 묶음을 계수와 생성에 각각 사본 전달
     */
    private ModelReply generate(InputMapper mapper, String instructions, ObjectNode schema) {
        ModelGateway model = Objects
            .requireNonNull(models.create(instructions, schema), Analysis.MODEL_PARAMETER);
        ObjectNode input = mapper.groupedInput();
        long tokens = model.countInput(input.deepCopy());
        if (tokens < 0) {
            throw new ModelFailure(Provider.INVALID_TOKEN_COUNT, Stage.GENERATION, false);
        }
        if (tokens > inputLimit) {
            throw new ModelFailure(Provider.INPUT_TOKEN_LIMIT, Stage.GENERATION, false);
        }

        ModelReply reply = model.generate(input.deepCopy());
        if (reply == null) {
            throw new ModelFailure(Provider.INVALID_PROVIDER_RESPONSE, Stage.GENERATION, true);
        }
        return reply;
    }
}
