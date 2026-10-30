package com.payse.api.analysis.crypto;

import static org.junit.jupiter.api.Assertions.*;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.junit.jupiter.api.Test;

/**
 * 본문·사용자·기억 바인딩과 변조 거절, 독립 키 및 키 배열 정리를 검사한다.
 * @created 2026-10-29
 * @usedBy Gradle JUnit test
 */
class EnvelopeCipherTest {
    /**
     * 같은 본문도 기억별 키·암호문을 분리하고 API 반환 평문이 원문과 같은지 확인한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void separatesMemoryKeys() {
        var keys = new TestKeys();
        var cipher = new EnvelopeCipher(keys);
        UUID user = UUID.randomUUID();
        UUID first = UUID.randomUUID();
        UUID second = UUID.randomUUID();
        byte[] plaintext = "통신비 후보: 합성 가맹점".getBytes(StandardCharsets.UTF_8);
        EncryptedMemory left = cipher.encrypt(user, first, plaintext);
        EncryptedMemory right = cipher.encrypt(user, second, plaintext);
        assertFalse(Arrays.equals(left.ciphertext(), right.ciphertext()));
        assertFalse(Arrays.equals(left.key().ciphertext(), right.key().ciphertext()));
        assertArrayEquals(plaintext, cipher.decrypt(user, first, left));
        assertArrayEquals(plaintext, cipher.decrypt(user, second, right));
        for (byte[] exposed : keys.exposedKeys) assertArrayEquals(new byte[32], exposed);
        assertEquals("EncryptedMemory[REDACTED]", left.toString());
        assertEquals("WrappedKey[REDACTED]", left.key().toString());
    }

    /**
     * KMS 문맥 검사를 통과시킨 테스트 대역에서도 GCM이 다른 사용자·기억으로 이동을 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void rejectsMovingCiphertext() {
        var keys = new TestKeys();
        var cipher = new EnvelopeCipher(keys);
        UUID user = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        EncryptedMemory encrypted = cipher.encrypt(user, item, new byte[]{1, 2, 3});
        assertThrows(IllegalStateException.class, () -> cipher.decrypt(UUID.randomUUID(), item, encrypted));
        assertThrows(IllegalStateException.class, () -> cipher.decrypt(user, UUID.randomUUID(), encrypted));
        assertArrayEquals(new byte[32], keys.exposedKeys.getLast());
    }

    /**
     * 암호문·nonce·감싼 키의 바꿔치기를 빈 정상 본문으로 처리하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void rejectsTampering() {
        var cipher = new EnvelopeCipher(new TestKeys());
        UUID user = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        EncryptedMemory encrypted = cipher.encrypt(user, item, new byte[]{1, 2, 3});
        byte[] changed = encrypted.ciphertext();
        changed[0] ^= 1;
        assertThrows(IllegalStateException.class,
            () -> cipher.decrypt(user, item, new EncryptedMemory(changed, encrypted.nonce(), encrypted.key())));
        byte[] nonce = encrypted.nonce();
        nonce[0] ^= 1;
        assertThrows(IllegalStateException.class,
            () -> cipher.decrypt(user, item, new EncryptedMemory(encrypted.ciphertext(), nonce, encrypted.key())));
        EncryptedMemory other = cipher.encrypt(user, UUID.randomUUID(), new byte[]{1, 2, 3});
        assertThrows(IllegalStateException.class,
            () -> cipher.decrypt(user, item, new EncryptedMemory(encrypted.ciphertext(), encrypted.nonce(), other.key())));
    }

    /**
     * 생성자·접근자로 얻은 배열 변경이 저장 메타데이터에 반영되지 않는지 확인한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void protectsStoredArrays() {
        byte[] wrappedBytes = new byte[]{4};
        WrappedKey wrapped = new WrappedKey("test-key", wrappedBytes);
        wrappedBytes[0] = 7;
        wrapped.ciphertext()[0] = 8;
        assertEquals(4, wrapped.ciphertext()[0]);
        byte[] ciphertext = new byte[16];
        byte[] nonce = new byte[12];
        EncryptedMemory memory = new EncryptedMemory(ciphertext, nonce, wrapped);
        ciphertext[0] = 1;
        nonce[0] = 2;
        memory.ciphertext()[1] = 3;
        memory.nonce()[1] = 4;
        assertArrayEquals(new byte[16], memory.ciphertext());
        assertArrayEquals(new byte[12], memory.nonce());
        assertThrows(IllegalArgumentException.class, () -> new EncryptedMemory(new byte[15], nonce, wrapped));
        assertThrows(IllegalArgumentException.class, () -> new EncryptedMemory(ciphertext, new byte[11], wrapped));
    }

    /**
     * KMS 장애 시 암호화 성공을 반환하거나 로컬 대체 키를 사용하지 않고 임시 키를 지운다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void failsClosedWhenKeyServiceFails() {
        var keys = new TestKeys();
        keys.failWrap = true;
        var cipher = new EnvelopeCipher(keys);
        assertThrows(IllegalStateException.class,
            () -> cipher.encrypt(UUID.randomUUID(), UUID.randomUUID(), new byte[]{1}));
        assertArrayEquals(new byte[32], keys.exposedKeys.getFirst());
    }

    /**
     * 공급자가 잘못된 길이의 키를 반환해도 암호 호출 전에 거절하고 그 배열을 지운다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void rejectsInvalidUnwrappedKey() {
        var keys = new TestKeys();
        var cipher = new EnvelopeCipher(keys);
        UUID user = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        EncryptedMemory encrypted = cipher.encrypt(user, item, new byte[]{1});
        keys.returnShortKey = true;
        assertThrows(IllegalStateException.class, () -> cipher.decrypt(user, item, encrypted));
        assertArrayEquals(new byte[31], keys.exposedKeys.getLast());
    }

    /**
     * 테스트에서만 독립 키 수명·배열 정리를 관찰하는 메모리 대역이다. 운영 KMS 구현이 아니다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipherTest
     */
    private static final class TestKeys implements KeyProtector {
        private final Map<String, byte[]> keys = new HashMap<>();
        private final List<byte[]> exposedKeys = new ArrayList<>();
        private boolean failWrap;
        private boolean returnShortKey;

        /**
         * 키 복사본에 불투명 식별자를 붙여 실제 KMS 호출 없이 봉투 바인딩을 검사한다.
         * @created 2026-10-29
         * @usedBy EnvelopeCipher.encrypt
         */
        @Override
        public WrappedKey wrap(byte[] key, byte[] context) {
            exposedKeys.add(key);
            if (failWrap) throw new IllegalStateException("Test key service unavailable");
            byte[] identifier = UUID.randomUUID().toString().getBytes(StandardCharsets.US_ASCII);
            keys.put(Base64.getEncoder().encodeToString(identifier), key.clone());
            return new WrappedKey("test-only", identifier);
        }

        /**
         * 독립 배열을 반환한다. GCM의 AAD 검사를 단독 확인하려고 대역은 문맥을 검증하지 않는다.
         * @created 2026-10-29
         * @usedBy EnvelopeCipher.decrypt
         */
        @Override
        public byte[] unwrap(WrappedKey wrapped, byte[] context) {
            byte[] stored = keys.get(Base64.getEncoder().encodeToString(wrapped.ciphertext()));
            if (stored == null) throw new IllegalStateException("Unknown test key");
            byte[] result = returnShortKey ? Arrays.copyOf(stored, 31) : stored.clone();
            exposedKeys.add(result);
            return result;
        }
    }
}
