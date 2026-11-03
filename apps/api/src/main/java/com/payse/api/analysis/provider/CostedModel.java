package com.payse.api.analysis.provider;

import com.payse.ai.constants.AiCodeConstants.Provider;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.analysis.service.AnalysisPricing;
import com.payse.api.constants.ApiConfigConstants.Execution;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import tools.jackson.databind.JsonNode;

/**
 * 요청별 계수·생성 전송권과 비용을 분리한다. 공급자 장애를 재시도하지 않는다.
 * @created 2026-11-03
 * @usedBy AnalysisRuntime.analyze
 */
public final class CostedModel implements ModelGateway {
    private final ModelGateway delegate;
    private final AnalysisCosts costs;
    private final AnalysisPricing pricing;
    private final String project;
    private final UUID attempt;

    /**
     * 이미 접수 트랜잭션에서 예약한 시도에만 게이트웨이를 연결한다.
     * @created 2026-11-03
     * @usedBy AnalysisRuntime.analyze
     */
    public CostedModel(
        ModelGateway delegate,
        AnalysisCosts costs,
        AnalysisPricing pricing,
        String project,
        UUID attempt
    ) {
        this.delegate = delegate;
        this.costs = costs;
        this.pricing = pricing;
        this.project = project;
        this.attempt = attempt;
    }

    /**
     * 계수도 독립 전송으로 기록한다. 실패가 생성 미전송 비용까지 소비한 것으로 처리하지 않는다.
     * @created 2026-11-03
     * @usedBy AnalysisService
     */
    @Override
    public long countInput(JsonNode input) {
        UUID call = countingId(attempt);
        authorize(call, ModelFailure.Stage.INPUT_COUNT);
        long count;
        try {
            count = delegate.countInput(input);
        } catch (ModelFailure failure) {
            if (!failure.mayHaveBeenSent()) {
                costs.notSent(project, call);
            }
            throw failure;
        }
        costs.settle(project, call, pricing.countingMicros());
        return count;
    }

    /**
     * 관측 토큰은 의미 검증·암호화·DB 채택 전에 정산한다. 사용량 누락은 예약으로 남긴다.
     * @created 2026-11-03
     * @usedBy AnalysisService
     */
    @Override
    public ModelReply generate(JsonNode input) {
        authorize(attempt, ModelFailure.Stage.GENERATION);
        ModelReply reply;
        try {
            reply = delegate.generate(input);
        } catch (ModelFailure failure) {
            if (!failure.mayHaveBeenSent()) {
                costs.notSent(project, attempt);
            }
            throw failure;
        }
        if (reply != null && reply.usage() != null) {
            costs.settle(project, attempt, pricing.cost(reply.usage()));
        }
        return reply;
    }

    /**
     * 같은 시도의 계수 예약을 안정적으로 식별한다. 공급자 재전송 키는 아니다.
     * @created 2026-11-03
     * @usedBy AnalysisRuntime.reserve, cancel, countInput
     */
    public static UUID countingId(UUID attempt) {
        return UUID.nameUUIDFromBytes(
            (Execution.COUNT_PREFIX + attempt).getBytes(StandardCharsets.UTF_8)
        );
    }

    /**
     * 한 번의 전송권이 확정되지 않으면 공급자를 호출하지 않는다.
     * @created 2026-11-03
     * @usedBy countInput, generate
     */
    private void authorize(UUID call, ModelFailure.Stage stage) {
        if (!costs.start(project, call)) {
            throw new ModelFailure(Provider.EXECUTION_NOT_AUTHORIZED, stage, false);
        }
    }
}
