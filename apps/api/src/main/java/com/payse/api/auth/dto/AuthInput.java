package com.payse.api.auth.dto;

/**
 * 요청 한 번의 인증 문자열이다. 정규화·자격 검증은 서비스에서 수행한다.
 * @created 2026-10-28
 * @usedBy AuthHttpInput.read, AuthService
 */
public record AuthInput(String name, String phone, String code) {
    /**
     * 문자열 변환에 인증 원문을 남기지 않는다.
     * @created 2026-10-28
     * @usedBy Java 문자열 변환
     */
    @Override public String toString() { return "AuthInput[REDACTED]"; }
}
