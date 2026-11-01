package com.payse.api.analysis.crypto;

import java.nio.ByteBuffer;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Objects;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * 매 기억의 독립 데이터 키와 인증된 사용자·기억 문맥으로 분석 본문을 보호한다.
 * @created 2026-10-29
 * @usedBy 미연결: 예정 사용처 분석 기억 저장·조회 서비스, EnvelopeCipherTest
 */
public final class EnvelopeCipher {
    private final KeyProtector protector;
    private final SecureRandom random = new SecureRandom();

    /**
     * 운영에서는 외부 관리형 KMS만 연결하며 실패 시 평문이나 임시 키로 대체하지 않는다.
     * @created 2026-10-29
     * @usedBy 미연결: 예정 사용처 분석 암호화 설정, EnvelopeCipherTest
     */
    public EnvelopeCipher(KeyProtector protector) {
        this.protector = Objects.requireNonNull(protector, "protector");
    }

    /**
     * 본문을 새 키로 암호화한다. 호출자는 전달한 원본 평문 배열을 사용 후 정리한다.
     * @created 2026-10-29
     * @usedBy 미연결: 예정 사용처 분석 결과 저장 서비스, EnvelopeCipherTest
     */
    public EncryptedMemory encrypt(UUID userId, UUID itemId, byte[] plaintext) {
        Objects.requireNonNull(plaintext, "plaintext");
        byte[] context = context(userId, itemId);
        byte[] key = new byte[32];
        byte[] nonce = new byte[12];
        random.nextBytes(key);
        random.nextBytes(nonce);
        try {
            Cipher cipher = cipher(Cipher.ENCRYPT_MODE, key, nonce, context);
            byte[] encrypted = cipher.doFinal(plaintext);
            WrappedKey wrapped = Objects.requireNonNull(protector.wrap(key, context), "wrapped");
            return new EncryptedMemory(encrypted, nonce, wrapped);
        } catch (GeneralSecurityException failure) {
            throw new IllegalStateException("Memory encryption failed");
        } finally {
            Arrays.fill(key, (byte) 0);
        }
    }

    /**
     * 소유권·유효성 검증 후에만 호출한다. 반환 평문은 호출자가 사용 후 정리한다.
     * @created 2026-10-29
     * @usedBy 미연결: 예정 사용처 분석 기억 조회 서비스, EnvelopeCipherTest
     */
    public byte[] decrypt(UUID userId, UUID itemId, EncryptedMemory encrypted) {
        Objects.requireNonNull(encrypted, "encrypted");
        byte[] context = context(userId, itemId);
        byte[] key = protector.unwrap(encrypted.key(), context);
        try {
            if (key == null || key.length != 32) throw new IllegalStateException("Invalid memory key");
            return cipher(Cipher.DECRYPT_MODE, key, encrypted.nonce(), context).doFinal(encrypted.ciphertext());
        } catch (GeneralSecurityException failure) {
            throw new IllegalStateException("Memory authentication failed");
        } finally {
            if (key != null) Arrays.fill(key, (byte) 0);
        }
    }

    /**
     * JCA 인증 암호를 초기화한다. AAD는 암호화되지 않지만 변조·다른 행으로 이동을 탐지한다.
     * @created 2026-10-29
     * @usedBy encrypt, decrypt
     */
    private Cipher cipher(int mode, byte[] key, byte[] nonce, byte[] context) throws GeneralSecurityException {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, nonce));
        cipher.updateAAD(context);
        return cipher;
    }

    /**
     * 고정 버전과 두 UUID의 네트워크 바이트 순서로 AAD를 만든다. 문자열 연결 모호성이 없다.
     * @created 2026-10-29
     * @usedBy encrypt, decrypt
     */
    private byte[] context(UUID userId, UUID itemId) {
        Objects.requireNonNull(userId, "userId");
        Objects.requireNonNull(itemId, "itemId");
        return ByteBuffer.allocate(36).putInt(1)
            .putLong(userId.getMostSignificantBits()).putLong(userId.getLeastSignificantBits())
            .putLong(itemId.getMostSignificantBits()).putLong(itemId.getLeastSignificantBits()).array();
    }
}
