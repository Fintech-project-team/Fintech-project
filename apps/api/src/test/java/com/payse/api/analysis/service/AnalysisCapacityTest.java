package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import org.junit.jupiter.api.Test;

/**
 * 일반 구성의 기존 한도와 명시 시험 구성의 사용자/전체 경계를 검사한다.
 * @created 2026-11-04
 * @usedBy JUnit
 */
class AnalysisCapacityTest {
    /**
     * 시험 병렬 실행 설정을 추가해도 일반 빈의 값은 바뀌지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void keepsDefaultLimits() {
        var limits = new AnalysisConfiguration().analysisCapacity();
        assertEquals(new AnalysisCapacity(2, 20, 1, 2), limits);
        assertFalse(limits.waitingFull(1, 19));
        assertTrue(limits.waitingFull(2, 2));
        assertTrue(limits.waitingFull(0, 20));
        assertFalse(limits.runningFull(0, 1));
        assertTrue(limits.runningFull(1, 1));
        assertTrue(limits.runningFull(0, 2));
    }

    /**
     * 승인된 시험 용량도 초과를 허용하지 않고 잘못된 구성을 시작 전에 거절한다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void boundsExplicitCapacity() {
        var limits = new AnalysisCapacity(6, 20, 6, 6);
        assertFalse(limits.runningFull(5, 5));
        assertTrue(limits.runningFull(6, 6));
        assertTrue(limits.runningFull(2, 6));
        assertThrows(IllegalArgumentException.class, () -> new AnalysisCapacity(3, 2, 1, 2));
        assertThrows(IllegalArgumentException.class, () -> new AnalysisCapacity(2, 20, 3, 2));
        assertThrows(IllegalArgumentException.class, () -> new AnalysisCapacity(0, 20, 1, 2));
        assertThrows(IllegalArgumentException.class, () -> new AnalysisCapacity(2, 20, 1, 17));
    }
}
