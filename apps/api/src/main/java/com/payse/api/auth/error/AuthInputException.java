package com.payse.api.auth.error;

import com.payse.api.auth.dto.AuthResult;

/**
 * 요청 파싱 실패의 종류만 전달하며 입력·파서 예외를 보존하지 않는다.
 * @created 2026-10-28
 * @usedBy AuthHttpInput, AuthService.read
 */
public final class AuthInputException extends RuntimeException {
    private final AuthResult.Reason reason;

    /**
     * 입력 오류 세 종류만 허용한다. 원문과 원인 예외는 받지 않는다.
     * @created 2026-10-28
     * @usedBy AuthHttpInput
     */
    public AuthInputException(AuthResult.Reason reason) {
        super("Authentication input rejected");
        if (reason != AuthResult.Reason.INVALID_INPUT && reason != AuthResult.Reason.INVALID_JSON
                && reason != AuthResult.Reason.REQUEST_TOO_LARGE) {
            throw new IllegalArgumentException("Unexpected input failure kind");
        }
        this.reason = reason;
    }

    /**
     * 일반 오류 응답으로 변환할 분류를 반환한다.
     * @created 2026-10-28
     * @usedBy AuthService.read, AuthController.logout
     */
    public AuthResult.Reason reason() { return reason; }
}
