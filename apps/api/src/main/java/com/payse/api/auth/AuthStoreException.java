package com.payse.api.auth;

/**
 * 인증 저장 장애를 입력값·SQL·DB 원인 예외 없이 전달한다. 자격 불일치와는 다르다.
 * @created 2026-10-25
 * @usedBy AuthRepository, AuthTransactions, 미연결: 예정 HTTP 503 매핑
 */
public final class AuthStoreException extends RuntimeException {
    /**
     * 원문과 원인 체인을 보관하지 않는 고정 메시지로 장애를 전달한다.
     * @created 2026-10-25
     * @usedBy AuthRepository, AuthTransactions
     */
    public AuthStoreException() {
        super("Authentication storage failed");
    }
}
