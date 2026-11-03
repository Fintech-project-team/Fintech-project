package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.GammaLocal;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * 감마 시험에서만 상위 키 파일로 개별 데이터 키를 인증 암호화한다. 운영 JAR에는 포함하지 않는다.
 * @created 2026-11-03
 * @usedBy GammaLocalConfig.gammaKeys, GammaLocalTest
 */
final class GammaLocalKeys implements KeyProtector, AutoCloseable {
    private final byte[] master;
    private final UUID owner;
    private final String reference;
    private final SecureRandom random = new SecureRandom();
    private boolean closed;

    /**
     * 명시한 일반 파일의 32바이트만 읽고 잘못된 키를 자동 생성·교체하지 않는다.
     * @created 2026-11-03
     * @usedBy GammaLocalConfig.gammaKeys, GammaLocalTest
     */
    GammaLocalKeys(Path path, UUID owner) {
        byte[] candidate = null;
        try {
            if (owner == null || !path.isAbsolute()
                || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) {
                throw invalid();
            }
            try (var input = Files.newInputStream(path, LinkOption.NOFOLLOW_LINKS)) {
                candidate = input.readNBytes(33);
            }
            if (candidate.length != 32) {
                throw invalid();
            }
            byte[] digest = MessageDigest.getInstance(GammaLocal.HASH_ALGORITHM).digest(candidate);
            reference = GammaLocal.KEY_REFERENCE + HexFormat.of().formatHex(digest);
            master = candidate.clone();
            this.owner = owner;
        } catch (IOException | GeneralSecurityException | SecurityException failure) {
            throw invalid();
        } finally {
            if (candidate != null) {
                Arrays.fill(candidate, (byte) 0);
            }
        }
    }

    /**
     * 감마 소유 문맥에 독립 nonce를 묶어 데이터 키를 보호한다.
     * @created 2026-11-03
     * @usedBy EnvelopeCipher.encrypt
     */
    @Override
    public synchronized WrappedKey wrap(byte[] key, byte[] context) {
        verify(context);
        if (key == null || key.length != 32) {
            throw invalid();
        }
        byte[] nonce = new byte[12];
        random.nextBytes(nonce);
        try {
            byte[] encrypted = cipher(Cipher.ENCRYPT_MODE, nonce, context).doFinal(key);
            byte[] packed = ByteBuffer.allocate(nonce.length + encrypted.length)
                .put(nonce)
                .put(encrypted)
                .array();
            return new WrappedKey(reference, packed);
        } catch (GeneralSecurityException failure) {
            throw invalid();
        }
    }

    /**
     * 키 버전·사용자·기억 문맥·인증 태그가 모두 맞아야 독립 키 배열을 반환한다.
     * @created 2026-11-03
     * @usedBy EnvelopeCipher.decrypt
     */
    @Override
    public synchronized byte[] unwrap(WrappedKey wrapped, byte[] context) {
        verify(context);
        if (wrapped == null || !reference.equals(wrapped.keyRef())) {
            throw invalid();
        }
        byte[] packed = wrapped.ciphertext();
        if (packed.length != 60) {
            throw invalid();
        }
        try {
            byte[] nonce = Arrays.copyOfRange(packed, 0, 12);
            return cipher(Cipher.DECRYPT_MODE, nonce, context).doFinal(packed, 12, 48);
        } catch (GeneralSecurityException failure) {
            throw invalid();
        }
    }

    /**
     * 기존 봉투 암호화의 버전·사용자·기억 UUID 문맥만 허용한다.
     * @created 2026-11-03
     * @usedBy wrap, unwrap
     */
    private void verify(byte[] context) {
        if (closed || context == null || context.length != 36) {
            throw invalid();
        }
        ByteBuffer data = ByteBuffer.wrap(context);
        if (data.getInt() != 1
            || data.getLong() != owner.getMostSignificantBits()
            || data.getLong() != owner.getLeastSignificantBits()) {
            throw invalid();
        }
    }

    /**
     * JCA AES-GCM의 128비트 태그로 상위 키와 문맥을 적용한다.
     * @created 2026-11-03
     * @usedBy wrap, unwrap
     */
    private Cipher cipher(int mode, byte[] nonce, byte[] context)
        throws GeneralSecurityException {
        Cipher cipher = Cipher.getInstance(GammaLocal.CIPHER_ALGORITHM);
        cipher.init(
            mode,
            new SecretKeySpec(master, GammaLocal.KEY_ALGORITHM),
            new GCMParameterSpec(128, nonce)
        );
        cipher.updateAAD(context);
        return cipher;
    }

    /**
     * 종료 후 재사용을 막고 보유한 상위 키 배열을 지운다.
     * @created 2026-11-03
     * @usedBy Spring 종료, GammaLocalTest
     */
    @Override
    public synchronized void close() {
        closed = true;
        Arrays.fill(master, (byte) 0);
    }

    /**
     * 키와 경로를 진단에 포함하지 않는다.
     * @created 2026-11-03
     * @usedBy Java 진단
     */
    @Override
    public String toString() {
        return GammaLocal.REDACTED;
    }

    /**
     * 키 원문·경로·암호 제공자의 원인 예외를 공개하지 않는다.
     * @created 2026-11-03
     * @usedBy GammaLocalKeys
     */
    private static IllegalStateException invalid() {
        return new IllegalStateException(GammaLocal.KEY_UNAVAILABLE);
    }
}
