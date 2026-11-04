package com.payse.api.analysis.provider;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import com.payse.ai.transport.ProviderHttp.ProviderFailure;
import com.payse.api.ApiTestConstants.Execution;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.mapper.AnalysisCosts;
import java.util.Arrays;
import java.util.UUID;
import org.junit.jupiter.api.Test;

/**
 * KMS 비용 차단·전송 불명·정산 실패 후 키 파기를 검사한다.
 * @created 2026-11-03
 * @usedBy Gradle JUnit
 */
class CostedKeysTest {
    private final KeyProtector provider = mock(KeyProtector.class);
    private final AnalysisCosts costs = mock(AnalysisCosts.class);
    private final CostedKeys keys = new CostedKeys(
        provider, costs, Execution.PROJECT, Execution.VERSION, 11
    );

    /**
     * 비용 전송권 거절은 외부 키 서비스에 도달하지 않는다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void blocksKmsWithoutDispatch() {
        assertThrows(IllegalStateException.class, () -> keys.wrap(new byte[32], new byte[1]));
        verifyNoInteractions(provider);
    }

    /**
     * 복호화 성공 후 정산 실패로 반환하지 못한 평문 키는 지운다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void erasesUndeliveredKey() {
        byte[] plaintext = new byte[32];
        Arrays.fill(plaintext, (byte) 9);
        WrappedKey wrapped = new WrappedKey("test", new byte[32]);
        byte[] context = new byte[1];
        when(costs.start(eq(Execution.PROJECT), any(UUID.class))).thenReturn(true);
        when(provider.unwrap(wrapped, context)).thenReturn(plaintext);
        doThrow(new IllegalStateException("test-storage-failure"))
            .when(costs).settle(eq(Execution.PROJECT), any(UUID.class), eq(11L));
        assertThrows(IllegalStateException.class, () -> keys.unwrap(wrapped, context));
        assertArrayEquals(new byte[32], plaintext);
    }

    /**
     * 이미 전송했을 수 있는 KMS 실패는 비용 예약을 유지한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void keepsUnconfirmedKmsCost() {
        when(costs.start(eq(Execution.PROJECT), any(UUID.class))).thenReturn(true);
        when(provider.wrap(any(byte[].class), any(byte[].class))).thenThrow(
            new ProviderFailure("TRANSMISSION_UNKNOWN", true)
        );
        assertThrows(ProviderFailure.class, () -> keys.wrap(new byte[32], new byte[1]));
        verify(costs, never()).notSent(eq(Execution.PROJECT), any(UUID.class));
        verify(costs, never()).settle(eq(Execution.PROJECT), any(UUID.class), anyLong());
    }
}
