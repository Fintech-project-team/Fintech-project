package com.payse.api.analysis.service;

import com.payse.ai.provider.dto.TokenUsage;
import com.payse.api.constants.ApiFieldConstants.Execution;
import com.payse.api.constants.ApiMessageConstants;
import java.math.BigInteger;
import java.util.HashSet;
import java.util.Set;
import tools.jackson.databind.node.ObjectNode;

/**
 * 승인된 원화 환산 단가로 API 비용만 산정한다. 금융 금액 계산에는 관여하지 않는다.
 * @created 2026-11-03
 * @usedBy AnalysisConfiguration, AnalysisRuntime, CostedModel, CostedKeys
 */
public final class AnalysisPricing {
    private final long inputRate;
    private final long cachedRate;
    private final long outputRate;
    private final long countingMicros;
    private final long kmsMicros;
    private final int inputLimit;
    private final int outputLimit;

    /**
     * 모든 단가·한도가 명시되고 선택 모델과 일치할 때만 사용한다. 1원은 100만 micros다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration, AnalysisPricingTest
     */
    public AnalysisPricing(ObjectNode policy, String model) {
        Set<String> expected = Set.of(
            Execution.MODEL,
            Execution.INPUT_RATE,
            Execution.CACHED_RATE,
            Execution.OUTPUT_RATE,
            Execution.COUNT_COST,
            Execution.KMS_COST,
            Execution.INPUT_LIMIT,
            Execution.OUTPUT_LIMIT
        );
        if (policy == null || !new HashSet<>(policy.propertyNames()).equals(expected)
            || !policy.path(Execution.MODEL).isString()
            || !policy.path(Execution.MODEL).asString().equals(model)) {
            throw invalid();
        }
        inputRate = number(policy, Execution.INPUT_RATE);
        cachedRate = number(policy, Execution.CACHED_RATE);
        outputRate = number(policy, Execution.OUTPUT_RATE);
        countingMicros = number(policy, Execution.COUNT_COST);
        kmsMicros = number(policy, Execution.KMS_COST);
        long inputs = number(policy, Execution.INPUT_LIMIT);
        long outputs = number(policy, Execution.OUTPUT_LIMIT);
        if (inputRate == 0 || outputRate == 0 || cachedRate > inputRate
            || kmsMicros == 0 || inputs < 1 || inputs > 200000 || outputs < 1 || outputs > 32000) {
            throw invalid();
        }
        inputLimit = Math.toIntExact(inputs);
        outputLimit = Math.toIntExact(outputs);
        maximum();
    }

    /**
     * 예약에는 할인되지 않은 최대 입력·출력을 사용한다.
     * @created 2026-11-03
     * @usedBy AnalysisRuntime.reserve
     */
    public long maximum() {
        return cost(new TokenUsage(inputLimit, null, outputLimit));
    }

    /**
     * 캐시 수치가 없으면 일반 단가로 보수 산정하며 올림 전 정밀도를 유지한다.
     * @created 2026-11-03
     * @usedBy CostedModel.generate, maximum
     */
    public long cost(TokenUsage usage) {
        if (usage == null) {
            throw invalid();
        }
        long cached = usage.cachedTokens() == null ? 0 : usage.cachedTokens();
        BigInteger total = BigInteger.valueOf(usage.inputTokens() - cached)
            .multiply(BigInteger.valueOf(inputRate))
            .add(BigInteger.valueOf(cached).multiply(BigInteger.valueOf(cachedRate)))
            .add(BigInteger.valueOf(usage.outputTokens()).multiply(BigInteger.valueOf(outputRate)));
        return total.add(BigInteger.valueOf(999999))
            .divide(BigInteger.valueOf(1000000))
            .longValueExact();
    }

    /**
     * 사전 승인한 계수 호출의 최대 비용을 반환한다.
     * @created 2026-11-03
     * @usedBy AnalysisRuntime.reserve, CostedModel.countInput
     */
    public long countingMicros() {
        return countingMicros;
    }

    /**
     * 세금·수수료를 포함해 승인한 KMS 1회 비용 상한을 반환한다.
     * @created 2026-11-03
     * @usedBy CostedKeys
     */
    public long kmsMicros() {
        return kmsMicros;
    }

    /**
     * 입력 한도를 공급자 계수·실행에 공통 적용한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration, AnalysisRuntime
     */
    public int inputLimit() {
        return inputLimit;
    }

    /**
     * 비공개 추론 토큰을 포함한 최대 출력 한도를 반환한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public int outputLimit() {
        return outputLimit;
    }

    /**
     * 누락·소수·음수·범위 초과를 0이나 기본 단가로 대체하지 않는다.
     * @created 2026-11-03
     * @usedBy AnalysisPricing
     */
    private static long number(ObjectNode policy, String key) {
        var value = policy.path(key);
        if (!value.isIntegralNumber() || !value.canConvertToLong() || value.asLong() < 0) {
            throw invalid();
        }
        return value.asLong();
    }

    /**
     * 가격 원문을 오류에 포함하지 않는다.
     * @created 2026-11-03
     * @usedBy AnalysisPricing, number, cost
     */
    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException(ApiMessageConstants.Execution.INVALID_PRICING);
    }
}
