package com.payse.api.analysis.service;

import com.payse.api.constants.ApiMessageConstants.Analysis;

/**
 * 승인된 구성의 대기·실행 용량이다. 요청이나 사용자 입력으로 변경하지 않는다.
 * @created 2026-11-04
 * @usedBy AnalysisConfiguration, AnalysisJobs, GammaLocalConfig
 */
public record AnalysisCapacity(int queuedUser, int queuedTotal, int runningUser, int runningTotal) {
    /**
     * 잘못된 상한이나 사용자 한도가 전체보다 큰 구성을 거절한다.
     * @created 2026-11-04
     * @usedBy AnalysisConfiguration.analysisCapacity, GammaLocalConfig.gammaCapacity
     */
    public AnalysisCapacity {
        if (queuedUser < 1 || queuedTotal < queuedUser || queuedTotal > 100
            || runningUser < 1 || runningTotal < runningUser || runningTotal > 16) {
            throw new IllegalArgumentException(Analysis.INVALID_CAPACITY);
        }
    }

    /**
     * 같은 DB 잠금 안에서 읽은 현재 대기 수에 두 상한을 모두 적용한다.
     * @created 2026-11-04
     * @usedBy AnalysisJobs.accept
     */
    public boolean waitingFull(long user, long total) {
        return user >= queuedUser || total >= queuedTotal;
    }

    /**
     * 실행 예약 전에 사용자와 전체 상한 중 하나라도 찼으면 대기시킨다.
     * @created 2026-11-04
     * @usedBy AnalysisJobs.submit
     */
    public boolean runningFull(long user, long total) {
        return user >= runningUser || total >= runningTotal;
    }
}
