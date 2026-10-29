package com.payse.api.auth;

import jakarta.servlet.http.HttpServletRequest;
import java.time.Instant;
import org.springframework.context.annotation.Profile;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 명시적으로 활성화된 인증 서비스만 세 HTTP 경로에 연결한다.
 * @created 2026-10-28
 * @usedBy Spring MVC 요청 매핑
 */
@RestController
@Profile("database & auth")
public final class AuthController {
    private final AuthService service;
    private final AuthHttpInput input;

    /**
     * 서비스와 HTTP 입력 경계를 생성자로 주입한다.
     * @created 2026-10-28
     * @usedBy Spring 생성자 주입
     */
    public AuthController(AuthService service, AuthHttpInput input) {
        this.service = service;
        this.input = input;
    }

    /**
     * 본문 해석을 지연하여 IP 제한 기록 뒤 최초 세션 생성 요청을 처리한다.
     * @created 2026-10-28
     * @usedBy POST /demo-sessions
     */
    @PostMapping("/demo-sessions")
    public ResponseEntity<?> login(HttpServletRequest request) {
        return AuthHttpResponse.reply(service.login(input.peer(request), () -> input.read(request)), Instant.now());
    }

    /**
     * IP 기록·현재 토큰 확인 뒤 자격을 읽고 새 토큰 없이 재확인한다.
     * @created 2026-10-28
     * @usedBy POST /demo-sessions/current/reverify
     */
    @PostMapping("/demo-sessions/current/reverify")
    public ResponseEntity<?> reverify(HttpServletRequest request) {
        AuthResult result = service.reverify(input.peer(request), () -> input.bearer(request), () -> input.read(request));
        return AuthHttpResponse.reply(result, Instant.now());
    }

    /**
     * 본문 없는 현재 세션 종료만 허용한다. 무효 토큰도 성공으로 바꾸지 않는다.
     * @created 2026-10-28
     * @usedBy DELETE /demo-sessions/current
     */
    @DeleteMapping("/demo-sessions/current")
    public ResponseEntity<?> logout(HttpServletRequest request) {
        try {
            input.requireEmpty(request);
        } catch (AuthInputException failure) {
            return AuthHttpResponse.reply(new AuthResult.Failure(failure.reason(), null), Instant.now());
        }
        return AuthHttpResponse.reply(service.logout(input.bearer(request)), Instant.now());
    }

    /**
     * 저장 장애를 성공·자격 오류로 바꾸지 않고 민감 원인 없이 503으로 전달한다.
     * @created 2026-10-28
     * @usedBy Spring MVC 인증 저장 예외 처리
     */
    @ExceptionHandler(AuthStoreException.class)
    public ResponseEntity<AuthHttpResponse.Error> unavailable() {
        return AuthHttpResponse.error(503, "TEMPORARILY_UNAVAILABLE", null);
    }
}
