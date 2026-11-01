package com.payse.api.auth.dto;

import java.time.Instant;
import java.util.List;
import java.util.UUID;

/**
 * 인증 공개 JSON 응답만 보관한다. 내부 결과·토큰 검증값은 포함하지 않는다.
 * @created 2026-10-29
 * @usedBy AuthHttpResponse, AuthController, FinancialController, Spring JSON 직렬화
 */
public final class AuthResponse {
    /**
     * 중첩 전달 타입만 사용하므로 묶음 클래스의 생성을 막는다.
     * @created 2026-10-29
     * @usedBy AuthResponse 클래스 초기화
     */
    private AuthResponse() {}

    /**
     * 최초 성공 때만 토큰을 포함하는 공개 로그인 응답이다.
     * @created 2026-10-28
     * @usedBy AuthHttpResponse.reply, Spring JSON 직렬화
     */
    public record Login(UUID userId, String name, UUID sessionId, String accessToken,
            String tokenType, Instant issuedAt) {
        /**
         * DTO 문자열 표현에서 토큰·사용자 정보를 제외한다.
         * @created 2026-10-28
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "Login[REDACTED]"; }
    }

    /**
     * 재확인은 같은 사용자·세션 확인만 제공하고 토큰을 재발급하지 않는다.
     * @created 2026-10-28
     * @usedBy AuthHttpResponse.reply, Spring JSON 직렬화
     */
    public record Verified(UUID userId, UUID sessionId, boolean verified) {}

    /**
     * 입력·내부 SQL 없이 공개 오류 식별자와 빈 상세 목록을 제공한다.
     * @created 2026-10-28
     * @usedBy AuthHttpResponse.error, Spring JSON 직렬화
     */
    public record Problem(String code, String message, UUID requestId, List<Object> details) {}

    /**
     * 공통 error 최상위 키를 유지한다.
     * @created 2026-10-28
     * @usedBy AuthHttpResponse.error, Spring JSON 직렬화
     */
    public record Error(Problem error) {}
}
