package com.payse.api.analysis.service;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.api.analysis.crypto.EncryptedMemory;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.finance.error.FinancialException;
import java.util.Objects;
import java.util.UUID;
import tools.jackson.databind.node.ObjectNode;

/**
 * 공급자와 KMS의 명시적 구성을 받는 실행 경계다. 기본 서버는 외부 전송이 닫혀 있다.
 * @created 2026-11-01
 * @usedBy AnalysisJobs, AnalysisResults, AnalysisConfiguration
 */
public class AnalysisRuntime {
    private final AnalysisService service;
    private final EnvelopeCipher cipher;
    private final ObjectNode versions;

    /**
     * 미준비 서버에서는 테스트 응답·임시 키·다른 계정으로 대체하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisConfiguration
     */
    public AnalysisRuntime() {
        service = null;
        cipher = null;
        versions = AnalysisJson.JSON.createObjectNode().put("runtime", "disabled");
    }

    /**
     * 승인된 실행 구성만 주입한다. 현재 테스트는 공급자/KMS 대역을 테스트 코드에서 주입한다.
     * @created 2026-11-01
     * @usedBy 분석 통합 테스트 구성, 미연결: 예정 사용처 유료 경로 승인 후 운영 구성
     */
    public AnalysisRuntime(AnalysisService service, EnvelopeCipher cipher, ObjectNode versions) {
        this.service = Objects.requireNonNull(service);
        this.cipher = Objects.requireNonNull(cipher);
        for (String name : new String[]{"model", "prompt", "response", "policy"}) {
            if (!versions.path(name).isString() || versions.path(name).asString().isBlank()) {
                throw new IllegalArgumentException("Explicit analysis versions required");
            }
        }
        this.versions = versions.deepCopy();
    }

    /**
     * 호출 여부가 불분명한 상태를 성공이나 무료 실행으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.submit, analyze, encrypt, decrypt
     */
    public void requireReady() {
        if (service == null || cipher == null) throw new FinancialException(503, "TEMPORARILY_UNAVAILABLE");
    }

    /**
     * 비밀값을 포함하지 않는 캐시 버전 사본을 제공한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     */
    public ObjectNode versions() { return versions.deepCopy(); }

    /**
     * 권한·원천·슬롯 확인 이후 DB 트랜잭션 밖에서 한 번 실행한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.execute
     */
    public AnalysisResult analyze(ObjectNode input) {
        requireReady();
        return service.analyzeForStorage(input);
    }

    /**
     * 기억별 독립 키로 보호하며 평문 저장으로 대체하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisResults.prepare
     */
    public EncryptedMemory encrypt(UUID owner, UUID item, byte[] bytes) {
        requireReady();
        return cipher.encrypt(owner, item, bytes);
    }

    /**
     * 현재 소유권·보존·원천 검사를 통과한 기억만 복호화한다.
     * @created 2026-11-01
     * @usedBy AnalysisResults.decrypt
     */
    public byte[] decrypt(UUID owner, UUID item, EncryptedMemory memory) {
        requireReady();
        return cipher.decrypt(owner, item, memory);
    }
}
