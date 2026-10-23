package com.payse.api.auth;

/**
 * 최초 인증 성공 응답용 원문과 DB 저장용 digest를 구분하는 내부 전달 값이다.
 * @created 2026-10-22
 * @usedBy AuthCrypto.issueToken, 미연결: 예정 AuthService
 */
public record IssuedToken(String value, String digest) {
    /**
     * 원문과 digest가 자동 record 표현을 통해 노출되지 않게 한다.
     * @created 2026-10-22
     * @usedBy Java 문자열 변환, AuthCryptoTest
     * @return 원문이 없는 고정 표현
     */
    @Override
    public String toString() { return "IssuedToken[REDACTED]"; }
}
