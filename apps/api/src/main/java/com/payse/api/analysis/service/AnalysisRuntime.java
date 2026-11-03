package com.payse.api.analysis.service;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFactory;
import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.analysis.provider.CostedModel;
import com.payse.api.analysis.crypto.EncryptedMemory;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
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
    private final Execution execution;

    /**
     * 미준비 서버에서는 테스트 응답·임시 키·다른 계정으로 대체하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisConfiguration
     * @modified 2026-11-03 - 비용 구성 없는 기본 실행 차단 유지
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    public AnalysisRuntime() {
        service = null;
        cipher = null;
        execution = null;
        versions = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.RUNTIME, ApiCodeConstants.Analysis.DISABLED);
    }

    /**
     * 승인된 실행 구성만 주입한다. 현재 테스트는 공급자/KMS 대역을 테스트 코드에서 주입한다.
     * @created 2026-11-01
     * @usedBy 분석 통합 테스트 구성
     * @modified 2026-11-03 - 테스트 구성과 비용 장부를 사용하는 운영 구성 구분
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     */
    public AnalysisRuntime(AnalysisService service, EnvelopeCipher cipher, ObjectNode versions) {
        this(service, cipher, versions, null);
    }

    /**
     * 운영 구성은 비용 장부와 고정된 공급자 팩토리를 함께 받는다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration, AnalysisRuntime의 테스트 생성자
     */
    AnalysisRuntime(
        AnalysisService service,
        EnvelopeCipher cipher,
        ObjectNode versions,
        Execution execution
    ) {
        this.service = Objects.requireNonNull(service);
        this.cipher = Objects.requireNonNull(cipher);
        this.execution = execution;
        String[] versionFields = {
            ApiFieldConstants.Analysis.MODEL,
            ApiFieldConstants.Analysis.PROMPT,
            ApiFieldConstants.Analysis.RESPONSE,
            ApiFieldConstants.Analysis.POLICY
        };
        for (String name : versionFields) {
            if (!versions.path(name).isString() || versions.path(name)
                .asString()
                .isBlank()) {
                throw new IllegalArgumentException(ApiMessageConstants.Analysis.VERSIONS_REQUIRED);
            }
        }

        this.versions = versions.deepCopy();
    }

    /**
     * 호출 여부가 불분명한 상태를 성공이나 무료 실행으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.submit, analyze, encrypt, decrypt
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    public void requireReady() {
        if (service == null || cipher == null) {
            throw new FinancialException(503, ApiCodeConstants.Analysis.TEMPORARILY_UNAVAILABLE);
        }
    }

    /**
     * 비밀값을 포함하지 않는 캐시 버전 사본을 제공한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     */
    public ObjectNode versions() {
        return versions.deepCopy();
    }

    /**
     * 권한·원천·슬롯 확인 이후 DB 트랜잭션 밖에서 한 번 실행한다.
     * @created 2026-11-01
     * @usedBy 테스트 구성의 analyze
     * @modified 2026-11-03 - 운영에서 예약 식별 없는 실행 차단
     */
    public AnalysisResult analyze(ObjectNode input) {
        requireReady();
        if (execution != null) {
            throw new IllegalStateException(ApiMessageConstants.Execution.COST_UNAVAILABLE);
        }
        return service.analyzeForStorage(input);
    }

    /**
     * 시도와 같은 접수 트랜잭션에 모델 최대 비용·계수 비용을 함께 예약한다.
     * @created 2026-11-03
     * @usedBy AnalysisJobs.submit
     */
    public void reserve(UUID attempt) {
        requireReady();
        if (execution == null) {
            return;
        }
        execution.costs().reserve(
            execution.project(),
            attempt,
            execution.version(),
            ApiCodeConstants.Execution.MODEL,
            execution.pricing().maximum()
        );
        execution.costs().reserve(
            execution.project(),
            CostedModel.countingId(attempt),
            execution.version(),
            ApiCodeConstants.Execution.COUNTING,
            execution.pricing().countingMicros()
        );
    }

    /**
     * 공급자 호출 전에 예약의 전송권을 확정하고 관측 비용을 저장보다 먼저 정산한다.
     * @created 2026-11-03
     * @usedBy AnalysisJobs.execute
     */
    public AnalysisResult analyze(UUID attempt, ObjectNode input, ObjectNode facts) {
        requireReady();
        if (execution == null) {
            return service.analyzeForStorage(input, facts);
        }
        ModelFactory models = (instructions, schema) -> new CostedModel(
            execution.models().create(instructions, schema),
            execution.costs(),
            execution.pricing(),
            execution.project(),
            attempt
        );
        try {
            return new AnalysisService(models, execution.pricing().inputLimit())
                .analyzeForStorage(input, facts);
        } finally {
            cancel(attempt);
        }
    }

    /**
     * 전송 전 취소·입력 실패만 반납한다. 이미 전송권을 얻은 예약은 자동 해제하지 않는다.
     * @created 2026-11-03
     * @usedBy AnalysisJobs.execute, AnalysisJobs.submit, analyze
     */
    public void cancel(UUID attempt) {
        if (execution != null) {
            try {
                execution.costs().releaseUnstarted(execution.project(), attempt);
                execution.costs().releaseUnstarted(
                    execution.project(),
                    CostedModel.countingId(attempt)
                );
            } catch (RuntimeException failure) {
                // 정산/전송 사실은 지우지 않는다. 미반납 예약은 운영 대조 대상으로 남긴다.
                org.slf4j.LoggerFactory.getLogger(AnalysisRuntime.class)
                    .warn(ApiMessageConstants.Execution.RELEASE_UNRECORDED);
            }
        }
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

    /**
     * 사용자 상태 없이 운영 공급자와 승인 비용 정책을 묶는다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration, AnalysisRuntime
     */
    record Execution(
        ModelFactory models,
        AnalysisCosts costs,
        AnalysisPricing pricing,
        String project,
        String version
    ) {
    }
}
