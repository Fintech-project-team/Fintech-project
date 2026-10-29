package com.payse.api.auth;

import java.time.Instant;
import java.util.UUID;

/**
 * 커밋이 끝난 인증 결과다. HTTP 응답 매핑과 금융 DTO는 별도 책임이다.
 * @created 2026-10-26
 * @usedBy AuthService, SessionJdbcTest
 */
public sealed interface AuthResult {
    /**
     * 최초 로그인 응답에 필요한 저장 결과와 토큰이다. 로그에 원문을 출력하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthService.signIn, 미연결: 예정 인증 HTTP 응답 매핑
     */
    record Login(UUID userId, String name, UUID sessionId, String accessToken, Instant issuedAt) implements AuthResult {
        /**
         * 자동 문자열 표현에서 자격·토큰·사용자 식별자를 숨긴다.
         * @created 2026-10-26
         * @usedBy Java 문자열 변환, AuthServiceTest
         */
        @Override
        public String toString() { return "Login[REDACTED]"; }
    }

    /**
     * 기존 사용자·세션의 재확인 성공이며 새 토큰이나 세션을 포함하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthService.confirm, 미연결: 예정 재확인 HTTP 응답 매핑
     */
    record Verified(UUID userId, UUID sessionId) implements AuthResult {}

    /**
     * 현재 세션 종료가 커밋된 결과다. 무효 토큰은 이 성공으로 변환하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthService.logout
     */
    enum LoggedOut implements AuthResult { INSTANCE }

    /**
     * 기존 인증 오류 의미만 표현한다. 비활성·기존 세션·자격 불일치는 구분하지 않는다.
     * @created 2026-10-26
     * @usedBy AuthResult.Failure, AuthService
     * @modified 2026-10-28 - JSON 구문·본문 상한 오류를 자격 실패와 구분
     */
    enum Reason { INVALID_INPUT, INVALID_JSON, REQUEST_TOO_LARGE, AUTH_REJECTED, SESSION_INVALID, RATE_LIMITED }

    /**
     * 실패 제한 기록까지 커밋된 업무 결과다. 저장 장애는 AuthStoreException으로 구분한다.
     * @created 2026-10-26
     * @usedBy AuthService, 미연결: 예정 HTTP 오류·Retry-After 매핑
     */
    record Failure(Reason reason, Instant retryAt) implements AuthResult {
        /**
         * 제한 오류에만 재시도 시각이 있도록 내부 결과의 모순을 거절한다.
         * @created 2026-10-26
         * @usedBy AuthService, AuthServiceTest
         */
        public Failure {
            if (reason == null || (reason == Reason.RATE_LIMITED) != (retryAt != null)) {
                throw new IllegalArgumentException("Invalid authentication failure result");
            }
        }
    }
}
