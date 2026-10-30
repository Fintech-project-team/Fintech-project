package com.payse.api.analysis.crypto;

/**
 * KMS 키 버전 참조와 감싼 데이터 키를 보관한다. 평문 키를 담지 않는다.
 * @created 2026-10-29
 * @usedBy KeyProtector, EnvelopeCipher
 */
public record WrappedKey(String keyRef, byte[] ciphertext) {
    /**
     * 누락된 키 참조·감싼 키를 거절하고 외부 배열 변경을 차단한다.
     * @created 2026-10-29
     * @usedBy KeyProtector.wrap, EnvelopeCipherTest
     */
    public WrappedKey {
        if (keyRef == null || keyRef.isBlank() || ciphertext == null || ciphertext.length == 0) {
            throw new IllegalArgumentException("Wrapped key is incomplete");
        }
        ciphertext = ciphertext.clone();
    }

    /**
     * 변경 가능한 내부 암호문 배열을 외부에 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy KeyProtector.unwrap, EnvelopeCipherTest
     */
    @Override
    public byte[] ciphertext() { return ciphertext.clone(); }

    /**
     * 자동 로그·예외 표현에 키 위치나 감싼 키를 넣지 않는다.
     * @created 2026-10-29
     * @usedBy Java 문자열 변환
     */
    @Override
    public String toString() { return "WrappedKey[REDACTED]"; }
}
