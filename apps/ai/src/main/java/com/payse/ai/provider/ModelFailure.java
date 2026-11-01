package com.payse.ai.provider;

import java.util.Objects;
import java.util.Set;

/**
 * 모델 실행의 단계와 전송 가능성만 전달한다. HTTP 구현·원문 예외에 의존하지 않는다.
 * @created 2026-11-01
 * @usedBy ModelGateway, AnalysisService, OpenAiGateway
 */
public final class ModelFailure extends RuntimeException {
    private static final Set<String> REASONS = Set.of(
        "CREDENTIAL_UNAVAILABLE", "INPUT_TOKEN_LIMIT", "INPUT_TOKENS_UNAVAILABLE",
        "INVALID_TOKEN_COUNT", "INVALID_PROVIDER_RESPONSE", "INVALID_PROVIDER_JSON",
        "TRANSMISSION_UNKNOWN", "RESPONSE_TOO_LARGE"
    );
    private final Stage stage;
    private final boolean mayHaveBeenSent;

    /**
     * 실패가 발생한 작업을 구분한다. 계수 실패는 생성 실패나 비용0을 뜻하지 않는다.
     * @created 2026-11-01
     * @usedBy ModelFailure, OpenAiGateway, AnalysisService
     */
    public enum Stage { INPUT_COUNT, GENERATION }

    /**
     * 알려진 내부 코드만 허용한다. 전송 가능성은 지정 단계에만 적용된다.
     * @created 2026-11-01
     * @usedBy OpenAiGateway, AnalysisService, 공급자 구현
     */
    public ModelFailure(String reason, Stage stage, boolean mayHaveBeenSent) {
        super(checkedReason(reason));
        this.stage = Objects.requireNonNull(stage, "stage");
        this.mayHaveBeenSent = mayHaveBeenSent;
    }

    /**
     * 공급자 본문·키를 오류 코드로 전달하지 못하게 한다.
     * @created 2026-11-01
     * @usedBy ModelFailure 생성자
     */
    private static String checkedReason(String reason) {
        if (reason == null || (!REASONS.contains(reason) && !reason.matches("PROVIDER_HTTP_[1-5][0-9]{2}"))) {
            throw new IllegalArgumentException("Known model failure code required");
        }
        return reason;
    }

    /**
     * 계수와 생성 중 실패 단계를 반환한다.
     * @created 2026-11-01
     * @usedBy 미연결: 예정 사용처 API 분석 시도 기록
     */
    public Stage stage() { return stage; }

    /**
     * 이 단계의 전송 가능성이다. false라도 앞선 단계의 전송 이력은 지우지 않는다.
     * @created 2026-11-01
     * @usedBy 미연결: 예정 사용처 API 분석 시도 기록
     */
    public boolean mayHaveBeenSent() { return mayHaveBeenSent; }
}
