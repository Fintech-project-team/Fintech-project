package com.payse.api.analysis.crypto;

/**
 * AES-256-GCM 암호문·96비트 nonce·기억별 감싼 키다. 128비트 인증 태그는 암호문 뒤에 포함한다.
 * @created 2026-10-29
 * @usedBy EnvelopeCipher
 */
public record EncryptedMemory(byte[] ciphertext, byte[] nonce, WrappedKey key) {
    /**
     * 지원 알고리즘의 고정 길이와 필수 키 메타데이터를 확인한다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.encrypt, EnvelopeCipherTest
     */
    public EncryptedMemory {
        if (ciphertext == null || ciphertext.length < 16 || nonce == null || nonce.length != 12 || key == null) {
            throw new IllegalArgumentException("Encrypted memory is incomplete");
        }
        ciphertext = ciphertext.clone();
        nonce = nonce.clone();
    }

    /**
     * 내부 암호문을 변경할 수 없도록 복사한다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.decrypt
     */
    @Override
    public byte[] ciphertext() { return ciphertext.clone(); }

    /**
     * 내부 nonce를 변경할 수 없도록 복사한다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.decrypt
     */
    @Override
    public byte[] nonce() { return nonce.clone(); }

    /**
     * 본문·암호문·키 참조를 문자열 표현으로 기록하지 않는다.
     * @created 2026-10-29
     * @usedBy Java 문자열 변환
     */
    @Override
    public String toString() { return "EncryptedMemory[REDACTED]"; }
}
