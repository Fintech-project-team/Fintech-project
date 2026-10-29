package com.payse.api.auth;

import java.time.Duration;
import java.time.Instant;
import java.util.List;
import java.util.UUID;
import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseEntity;

/**
 * 내부 인증 결과를 공개 성공/오류 DTO와 고정 보안 헤더로 변환한다.
 * @created 2026-10-28
 * @usedBy AuthController
 */
public final class AuthHttpResponse {
    /**
     * 상태가 없는 응답 변환기의 인스턴스 생성을 막는다.
     * @created 2026-10-28
     * @usedBy AuthHttpResponse 클래스 초기화
     */
    private AuthHttpResponse() {}

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

    /**
     * 커밋된 결과만 성공으로 반환하며 Retry-After는 남은 초를 올림한다.
     * @created 2026-10-28
     * @usedBy AuthController의 세 인증 경로
     */
    public static ResponseEntity<?> reply(AuthResult result, Instant now) {
        if (result instanceof AuthResult.Login login) {
            return base(201).body(new Login(login.userId(), login.name(), login.sessionId(),
                login.accessToken(), "Bearer", login.issuedAt()));
        }
        if (result instanceof AuthResult.Verified verified) {
            return base(200).body(new Verified(verified.userId(), verified.sessionId(), true));
        }
        if (result == AuthResult.LoggedOut.INSTANCE) return base(204).build();
        AuthResult.Failure failure = (AuthResult.Failure) result;
        return switch (failure.reason()) {
            case INVALID_INPUT -> error(422, "VALIDATION_FAILED", null);
            case INVALID_JSON -> error(400, "INVALID_JSON", null);
            case REQUEST_TOO_LARGE -> error(413, "REQUEST_TOO_LARGE", null);
            case AUTH_REJECTED -> error(401, "AUTH_REJECTED", null);
            case SESSION_INVALID -> error(401, "SESSION_INVALID", null);
            case RATE_LIMITED -> {
                Duration remaining = Duration.between(now, failure.retryAt());
                long seconds = Math.max(1, remaining.getSeconds() + (remaining.getNano() > 0 ? 1 : 0));
                yield error(429, "RATE_LIMITED", Long.toString(seconds));
            }
        };
    }

    /**
     * 서버가 생성한 오류 ID만 반환한다. 호출자가 입력·예외 메시지를 넣을 수 없다.
     * @created 2026-10-28
     * @usedBy AuthHttpResponse.reply, AuthController.unavailable
     */
    public static ResponseEntity<Error> error(int status, String code, String retryAfter) {
        var response = base(status);
        if (status == 401) response.header(HttpHeaders.WWW_AUTHENTICATE, "Bearer");
        if (retryAfter != null) response.header(HttpHeaders.RETRY_AFTER, retryAfter);
        return response.body(new Error(new Problem(code, "요청을 처리하지 못했습니다.", UUID.randomUUID(), List.of())));
    }

    /**
     * 성공·오류·로그아웃 모두 캐시와 토큰의 중간 저장을 막는다.
     * @created 2026-10-28
     * @usedBy AuthHttpResponse.reply, error
     */
    private static ResponseEntity.BodyBuilder base(int status) {
        return ResponseEntity.status(status).header(HttpHeaders.CACHE_CONTROL, "no-store");
    }
}
