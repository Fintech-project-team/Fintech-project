package com.payse.api.analysis.provider;

import com.payse.ai.transport.ProviderHttp.ProviderFailure;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.constants.ApiCodeConstants.Execution;
import com.payse.api.constants.ApiMessageConstants;
import java.util.Arrays;
import java.util.UUID;
import java.util.function.Supplier;

/**
 * 생성·조회 시 발생하는 KMS 비용도 같은 프로젝트 한도에 기록한다.
 * @created 2026-11-03
 * @usedBy AnalysisConfiguration, EnvelopeCipher
 */
public final class CostedKeys implements KeyProtector {
    private final KeyProtector delegate;
    private final AnalysisCosts costs;
    private final String project;
    private final String version;
    private final long maximum;

    /**
     * 자격과 단가를 임의 기본값 없이 구성한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public CostedKeys(
        KeyProtector delegate,
        AnalysisCosts costs,
        String project,
        String version,
        long maximum
    ) {
        this.delegate = delegate;
        this.costs = costs;
        this.project = project;
        this.version = version;
        this.maximum = maximum;
    }

    /**
     * 데이터 키 보호 호출 전에 비용을 예약하고 관측된 1회 호출을 정산한다.
     * @created 2026-11-03
     * @usedBy EnvelopeCipher.encrypt
     */
    @Override
    public WrappedKey wrap(byte[] key, byte[] context) {
        return invoke(() -> delegate.wrap(key, context));
    }

    /**
     * 결과 조회도 외부 비용을 우회하지 않는다.
     * @created 2026-11-03
     * @usedBy EnvelopeCipher.decrypt
     */
    @Override
    public byte[] unwrap(WrappedKey wrapped, byte[] context) {
        return invoke(() -> delegate.unwrap(wrapped, context));
    }

    /**
     * DB를 먼저 커밋하고 외부 호출한다. 정산 실패로 전달하지 못한 평문 키는 지운다.
     * @created 2026-11-03
     * @usedBy wrap, unwrap
     */
    private <T> T invoke(Supplier<T> operation) {
        UUID call = UUID.randomUUID();
        costs.reserveCall(project, call, version, Execution.KMS, maximum);
        if (!costs.start(project, call)) {
            costs.releaseUnstarted(project, call);
            throw new IllegalStateException(ApiMessageConstants.Execution.COST_UNAVAILABLE);
        }
        T result;
        try {
            result = operation.get();
        } catch (ProviderFailure failure) {
            if (!failure.mayHaveBeenSent()) {
                costs.notSent(project, call);
            }
            throw failure;
        }
        try {
            costs.settle(project, call, maximum);
            return result;
        } catch (RuntimeException failure) {
            if (result instanceof byte[] plaintext) {
                Arrays.fill(plaintext, (byte) 0);
            }
            throw failure;
        }
    }
}
