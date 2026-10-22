package com.payse.api.auth;

import java.security.MessageDigest;

/**
 * 분리된 코드·제한 키와 형식 식별자를 보관하며 키 배열의 외부 변경을 막는다.
 * @created 2026-10-22
 * @usedBy AuthCryptoConfiguration.authSecrets, AuthCrypto
 */
public final class AuthSecrets {
    private final String codeKeyId;
    private final byte[] codeKey;
    private final byte[] limitKey;

    /**
     * 각 32바이트의 서로 다른 키를 검증하고 복사한다. 무작위 생성은 배포 준비 책임이다.
     * @created 2026-10-22
     * @usedBy AuthCryptoConfiguration.authSecrets, AuthCryptoTest
     * @param codeKeyId ASCII 영숫자·밑줄·하이픈으로 된 코드 키 식별자
     * @param codeKey 코드 검증용 비밀 키
     * @param limitKey 인증 시도 제한 식별용 비밀 키
     */
    public AuthSecrets(String codeKeyId, byte[] codeKey, byte[] limitKey) {
        requireKey(codeKeyId, codeKey);
        if (limitKey == null || limitKey.length != 32) {
            throw new IllegalArgumentException("Invalid authentication key configuration");
        }
        if (MessageDigest.isEqual(codeKey, limitKey)) {
            throw new IllegalArgumentException("Authentication keys must be distinct");
        }
        this.codeKeyId = codeKeyId;
        this.codeKey = codeKey.clone();
        this.limitKey = limitKey.clone();
    }

    /**
     * 저장 형식 구분자를 포함하지 않는 키 ID와 정확한 키 길이를 검사한다.
     * @created 2026-10-22
     * @usedBy AuthSecrets 생성자
     * @param id 키 식별자
     * @param key 비밀 키
     */
    private static void requireKey(String id, byte[] key) {
        if (id == null || !id.matches("[A-Za-z0-9_-]+") || key == null || key.length != 32) {
            throw new IllegalArgumentException("Invalid authentication key configuration");
        }
    }

    /**
     * 코드 verifier의 활성 키 식별자를 반환한다.
     * @created 2026-10-22
     * @usedBy AuthCrypto.codeVerifier, AuthCrypto.verifyCode
     * @return 비밀 원문이 아닌 키 ID
     */
    public String codeKeyId() { return codeKeyId; }

    /**
     * 한 연산에서만 사용할 코드 키 사본을 반환한다.
     * @created 2026-10-22
     * @usedBy AuthCrypto.codeVerifier
     * @return 독립 배열
     */
    byte[] codeKey() { return codeKey.clone(); }

    /**
     * 한 연산에서만 사용할 제한 키 사본을 반환한다.
     * @created 2026-10-22
     * @usedBy AuthCrypto.combinationLimitKey, AuthCrypto.ipLimitKey
     * @return 독립 배열
     */
    byte[] limitKey() { return limitKey.clone(); }

    /**
     * 문자열 변환에 비밀값과 키 식별자를 포함하지 않는다.
     * @created 2026-10-22
     * @usedBy Java 문자열 변환, AuthCryptoTest
     * @return 고정 마스킹 표현
     */
    @Override
    public String toString() { return "AuthSecrets[REDACTED]"; }
}
