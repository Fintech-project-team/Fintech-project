package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisFields;

import com.payse.ai.analysis.service.AnalysisService;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;

/**
 * 실제 인증·소유권·DB·암호화를 유지하고 모델/KMS 네트워크만 제거하는 명시 시험 구성이다.
 * @created 2026-11-04
 * @usedBy ProtocolMockServer
 */
@TestConfiguration(proxyBeanMethods = false)
public class ProtocolMockConfig {
    /**
     * 선택된 모의 결과는 서버 시작 때 고정하며 클라이언트가 제품 입력으로 조작하지 않는다.
     * @created 2026-11-04
     * @usedBy Spring 시험 구성
     */
    @Bean
    ProtocolMockModel protocolModel(
        @Value("${payse.protocol.scenario}") String scenario,
        @Value("${payse.protocol.delay-ms}") int delay
    ) {
        return new ProtocolMockModel(scenario, delay);
    }

    /**
     * 원래 AI 검증기와 AES-GCM 봉투를 호출하고 모의 실행의 버전을 분리한다.
     * @created 2026-11-04
     * @usedBy Spring 시험 구성
     */
    @Bean
    @Primary
    AnalysisRuntime protocolRuntime(ProtocolMockModel model) {
        var versions = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.MODEL, "protocol-mock-1/" + model.scenario())
            .put(AnalysisFields.PROMPT, "protocol-mock-1")
            .put(AnalysisFields.RESPONSE, "PAYSE-ANALYSIS-1")
            .put(AnalysisFields.POLICY, "PAYSE-MEANING-1");
        return new AnalysisRuntime(
            new AnalysisService(model, 6000),
            new EnvelopeCipher(new MemoryKeys()),
            versions
        );
    }

    /**
     * 폐기 서버 수명 동안만 사용자·기억 문맥에 바인딩한 데이터 키를 보관한다.
     * @created 2026-11-04
     * @usedBy protocolRuntime
     */
    static final class MemoryKeys implements KeyProtector {
        private final Map<String, byte[]> keys = new ConcurrentHashMap<>();
        private final Map<String, byte[]> contexts = new ConcurrentHashMap<>();

        /**
         * 원래 입력 배열을 복사하고 DB에는 평문 키 대신 불투명 핸들을 반환한다.
         * @created 2026-11-04
         * @usedBy EnvelopeCipher
         */
        @Override
        public WrappedKey wrap(byte[] key, byte[] context) {
            String id = UUID.randomUUID().toString();
            keys.put(id, key.clone());
            contexts.put(id, context.clone());
            return new WrappedKey("protocol-test-only", id.getBytes(StandardCharsets.US_ASCII));
        }

        /**
         * 현재 문맥과 같은 핸들만 복호화하고 다른 사용자·기억은 거절한다.
         * @created 2026-11-04
         * @usedBy EnvelopeCipher
         */
        @Override
        public byte[] unwrap(WrappedKey wrapped, byte[] context) {
            String id = new String(wrapped.ciphertext(), StandardCharsets.US_ASCII);
            if (!"protocol-test-only".equals(wrapped.keyRef())
                || !Arrays.equals(contexts.get(id), context) || !keys.containsKey(id)) {
                throw new IllegalStateException("Unknown mock key context");
            }
            return keys.get(id).clone();
        }
    }
}
