package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.nullable;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.payse.api.ApiTestConstants.AnalysisFields;
import com.payse.api.ApiTestConstants.GammaLocal;
import com.payse.api.analysis.controller.AnalysisController;
import com.payse.api.analysis.crypto.EncryptedMemory;
import com.payse.api.analysis.crypto.EnvelopeCipher;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialRepository;
import jakarta.servlet.http.HttpServletRequest;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.mock.web.MockHttpServletRequest;
import org.springframework.mock.web.MockHttpServletResponse;
import org.springframework.web.method.HandlerMethod;
import tools.jackson.databind.node.ObjectNode;

/**
 * 외부 호출 없이 로컬 봉투 암호화와 인증된 감마 전용 경계를 검사한다.
 * @created 2026-11-03
 * @usedBy Gradle test
 */
class GammaLocalTest {
    @TempDir
    Path directory;

    /**
     * 상위 키 파일을 다시 읽어 저장 암호문을 복구하고 기억별 nonce·키가 독립적임을 확인한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void decryptsAfterRestart() throws Exception {
        Path file = keyFile("master.key");
        UUID owner = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        byte[] text = "합성 감마 분석".getBytes(StandardCharsets.UTF_8);
        EncryptedMemory encrypted;
        try (var keys = new GammaLocalKeys(file, owner)) {
            EnvelopeCipher cipher = new EnvelopeCipher(keys);
            encrypted = cipher.encrypt(owner, item, text);
            EncryptedMemory second = cipher.encrypt(owner, item, text);
            assertFalse(Arrays.equals(encrypted.ciphertext(), second.ciphertext()));
            assertFalse(Arrays.equals(encrypted.key().ciphertext(), second.key().ciphertext()));
            assertFalse(Arrays.equals(text, encrypted.ciphertext()));
            assertEquals(GammaLocal.REDACTED, keys.toString());
        }
        try (var keys = new GammaLocalKeys(file, owner)) {
            assertArrayEquals(text, new EnvelopeCipher(keys).decrypt(owner, item, encrypted));
        }
    }

    /**
     * 다른 상위 키·소유자·기억·변조된 감싼 키를 모두 거절한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void rejectsTamperingAndOtherOwners() throws Exception {
        UUID owner = UUID.randomUUID();
        UUID item = UUID.randomUUID();
        Path original = keyFile("original.key");
        Path other = keyFile("other.key");
        try (var keys = new GammaLocalKeys(original, owner);
            var wrong = new GammaLocalKeys(other, owner)) {
            EnvelopeCipher cipher = new EnvelopeCipher(keys);
            EncryptedMemory value = cipher.encrypt(owner, item, new byte[] { 1, 2, 3 });
            assertThrows(
                IllegalStateException.class,
                () -> new EnvelopeCipher(wrong).decrypt(owner, item, value)
            );
            assertThrows(
                IllegalStateException.class,
                () -> cipher.decrypt(UUID.randomUUID(), item, value)
            );
            assertThrows(
                IllegalStateException.class,
                () -> cipher.decrypt(owner, UUID.randomUUID(), value)
            );
            assertThrows(
                IllegalStateException.class,
                () -> cipher.encrypt(UUID.randomUUID(), item, new byte[] { 1 })
            );
            byte[] changed = value.key().ciphertext();
            changed[changed.length - 1] ^= 1;
            EncryptedMemory tampered = new EncryptedMemory(
                value.ciphertext(),
                value.nonce(),
                new WrappedKey(value.key().keyRef(), changed)
            );
            assertThrows(IllegalStateException.class, () -> cipher.decrypt(owner, item, tampered));
            keys.close();
            assertThrows(IllegalStateException.class, () -> cipher.decrypt(owner, item, value));
        }
    }

    /**
     * 경로·길이가 잘못된 키를 만들거나 교체하지 않고 실패한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidFiles() throws Exception {
        UUID owner = UUID.randomUUID();
        for (int length : new int[] { 0, 31, 33, 1024 }) {
            Path file = directory.resolve("invalid.key");
            Files.write(file, new byte[length]);
            var failure = assertThrows(
                IllegalStateException.class,
                () -> new GammaLocalKeys(file, owner)
            );
            assertEquals(GammaLocal.KEY_UNAVAILABLE, failure.getMessage());
        }
        assertThrows(
            IllegalStateException.class,
            () -> new GammaLocalKeys(Path.of("relative.key"), owner)
        );
        assertThrows(
            IllegalStateException.class,
            () -> new GammaLocalKeys(directory.resolve("missing"), owner)
        );
    }

    /**
     * 미인증·타 계정·원천 변경은 controller 실행 전에 차단하고 일반 경로는 유지한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void restrictsAnalysisToVerifiedGamma() throws Exception {
        AuthTransactions transactions = mock(AuthTransactions.class);
        AuthRepository auth = mock(AuthRepository.class);
        AuthCrypto crypto = mock(AuthCrypto.class);
        FinancialRepository finances = mock(FinancialRepository.class);
        when(transactions.run(any())).thenAnswer(call -> ((Supplier<?>) call.getArgument(0)).get());
        when(crypto.tokenDigest(nullable(String.class))).thenReturn("test-digest");
        UUID owner = GammaLocalConfig.owner();
        String version = "fixture:gamma-year:1:2026-10-31:20261103";
        var guard = new GammaDeployment.Guard(
            transactions,
            auth,
            crypto,
            finances,
            owner,
            version
        );
        var request = new MockHttpServletRequest();
        var response = new MockHttpServletResponse();
        var handler = new HandlerMethod(
            mock(AnalysisController.class),
            AnalysisController.class.getMethod(GammaLocal.ACCEPT_METHOD, HttpServletRequest.class)
        );
        when(auth.authorize(nullable(String.class))).thenReturn(Optional.empty());
        assertThrows(FinancialException.class, () -> guard.preHandle(request, response, handler));
        when(auth.authorize(nullable(String.class))).thenReturn(
            Optional.of(new AuthRows.Session(UUID.randomUUID(), UUID.randomUUID()))
        );
        assertThrows(FinancialException.class, () -> guard.preHandle(request, response, handler));
        verify(finances, never()).load(any());
        when(auth.authorize(nullable(String.class))).thenReturn(
            Optional.of(new AuthRows.Session(owner, UUID.randomUUID()))
        );
        ObjectNode different = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisFields.SOURCE_VERSION, "different-source");
        when(finances.load(owner)).thenReturn(different);
        assertThrows(FinancialException.class, () -> guard.preHandle(request, response, handler));
        when(finances.load(owner)).thenReturn(
            AnalysisJson.JSON.createObjectNode().put(AnalysisFields.SOURCE_VERSION, version)
        );
        assertTrue(guard.preHandle(request, response, handler));
        assertTrue(guard.preHandle(request, response, new Object()));
    }

    /**
     * 임시 폴더에만 무작위 시험 상위 키를 만든다.
     * @created 2026-11-03
     * @usedBy decryptsAfterRestart, rejectsTamperingAndOtherOwners
     */
    private Path keyFile(String name) throws Exception {
        byte[] key = new byte[32];
        new SecureRandom().nextBytes(key);
        Path file = directory.resolve(name);
        Files.write(file, key);
        Arrays.fill(key, (byte) 0);
        return file;
    }
}
