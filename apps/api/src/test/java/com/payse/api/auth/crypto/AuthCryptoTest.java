package com.payse.api.auth.crypto;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.auth.vo.IssuedToken;
import java.net.Inet6Address;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.Executors;
import org.junit.jupiter.api.Test;

/**
 * 독립 known-answer 값·입력 분리·동시 연산·비밀값 표현을 검사한다.
 * @created 2026-10-22
 * @usedBy Gradle test의 JUnit 실행
 */
class AuthCryptoTest {
    /**
     * Python hmac/hashlib에서 별도로 계산한 UTF-8·HMAC·SHA-256 정답과 비교한다.
     * UUID 0은 알고리즘 벡터 입력이며 DB 행 선택자가 아니다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void matchesKnownAnswers() throws Exception {
        var crypto = crypto();
        assertEquals("hmac-sha256:test_code:19142b1585f8379bea40045fc9c830487101d69837f080bb45da4ca38d3b0e73",
            crypto.codeVerifier(new UUID(0, 0), "012345"));
        assertEquals("befc7b9b7e7deeae09723e9a7026082cf1bc5f41fa9639b3826f727a81a98c32",
            crypto.combinationLimitKey("데모알파", "01000000001"));
        assertEquals("e966308badcd23140683975d98deb8b6e9fe5193189c06081b58f4f869349096",
            crypto.ipLimitKey(InetAddress.getByAddress(new byte[]{(byte) 192, 0, 2, 1})));
        byte[] ipv6 = HexFormat.of().parseHex("20010db8000000000000000000000001");
        assertEquals("dfed65ddc6d371288bb537db9aca5e6980e40b6b9e9be37192eb2e32c0b9ae93",
            crypto.ipLimitKey(InetAddress.getByAddress(ipv6)));
        assertEquals("sha256:ea866a757e4c38babfa8127cbe9a409d3e1f93a00ff1488ff735fcf917afffd0",
            crypto.tokenDigest("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"));
    }

    /**
     * 토큰 길이·정규 인코딩·검증·중복 여부를 검사하며 보안 난수의 통계 증명으로 해석하지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void validatesIssuedTokens() {
        var crypto = crypto();
        var values = new HashSet<String>();
        for (int index = 0; index < 128; index++) {
            IssuedToken issued = crypto.issueToken();
            assertTrue(values.add(issued.value()));
            assertTrue(issued.value().matches("[A-Za-z0-9_-]{43}"));
            assertEquals(32, Base64.getUrlDecoder().decode(issued.value()).length);
            assertTrue(crypto.verifyToken(issued.value(), issued.digest()));
            assertEquals("IssuedToken[REDACTED]", issued.toString());
        }
        IssuedToken valid = crypto.issueToken();
        for (String invalid : Arrays.asList(null, "", " ", "A".repeat(42), "A".repeat(44),
                "B".repeat(43), valid.value() + "=", valid.value() + "\n", "+".repeat(43), "가".repeat(43))) {
            assertFalse(crypto.verifyToken(invalid, valid.digest()));
            assertThrows(IllegalArgumentException.class, () -> crypto.tokenDigest(invalid));
        }
        for (String invalid : Arrays.asList(null, "", "sha256:" + "A".repeat(64),
                "sha256:" + "0".repeat(63), valid.digest() + "\n", "SHA256:" + "0".repeat(64))) {
            assertFalse(crypto.verifyToken(valid.value(), invalid));
        }
        assertFalse(crypto.verifyToken(crypto.issueToken().value(), valid.digest()));
    }

    /**
     * 동적 사용자 UUID·코드·키가 다르면 기존 verifier가 인증되지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void bindsCodeVerifiers() {
        var crypto = crypto();
        UUID userId = UUID.randomUUID();
        String verifier = crypto.codeVerifier(userId, "000001");
        assertTrue(crypto.verifyCode(userId, "000001", verifier));
        assertFalse(crypto.verifyCode(UUID.randomUUID(), "000001", verifier));
        assertFalse(crypto.verifyCode(userId, "000002", verifier));
        var otherKey = new AuthCrypto(new AuthSecrets("test_code", key(64), key(32)));
        assertFalse(otherKey.verifyCode(userId, "000001", verifier));
        for (String invalid : Arrays.asList(null, "", "DISABLED", verifier.replace("test_code", "other"),
                verifier.toUpperCase(Locale.ROOT), verifier + " ", verifier.substring(0, verifier.length() - 1))) {
            assertFalse(crypto.verifyCode(userId, "000001", invalid));
        }
        assertFalse(crypto.verifyCode(null, "000001", verifier));
        assertFalse(crypto.verifyCode(userId, "０００００１", verifier));
        assertThrows(IllegalArgumentException.class, () -> crypto.codeVerifier(userId, "000001 "));
        assertThrows(IllegalArgumentException.class, () -> crypto.codeVerifier(null, "000001"));
    }

    /**
     * 조합 정규화·코드와 제한 키 분리 및 IPv4-mapped 주소의 동등성을 검사한다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void separatesLimitKeys() throws Exception {
        var crypto = crypto();
        String credentialKey = crypto.combinationLimitKey("데모알파", "01000000001");
        assertEquals(credentialKey, crypto.combinationLimitKey(" 데모알파 ", "010-0000-0001"));
        assertNotEquals(credentialKey, crypto.combinationLimitKey("데모베타", "01000000001"));
        assertNotEquals(credentialKey, crypto.combinationLimitKey("데모알파", "01000000002"));
        var codeChanged = new AuthCrypto(new AuthSecrets("other", key(64), key(32)));
        assertEquals(credentialKey, codeChanged.combinationLimitKey("데모알파", "01000000001"));
        var limitChanged = new AuthCrypto(new AuthSecrets("test_code", key(0), key(64)));
        assertNotEquals(credentialKey, limitChanged.combinationLimitKey("데모알파", "01000000001"));
        UUID userId = UUID.randomUUID();
        assertEquals(crypto.codeVerifier(userId, "000001"), limitChanged.codeVerifier(userId, "000001"));
        var ipv4 = InetAddress.getByAddress("untrusted-host-label", new byte[]{(byte) 192, 0, 2, 1});
        var mapped = Inet6Address.getByAddress(null, HexFormat.of().parseHex("00000000000000000000ffffc0000201"), 0);
        assertEquals(crypto.ipLimitKey(ipv4), crypto.ipLimitKey(mapped));
        assertNotEquals(credentialKey, crypto.ipLimitKey(ipv4));
        assertNotEquals(crypto.ipLimitKey(ipv4), crypto.ipLimitKey(InetAddress.getByAddress(new byte[]{(byte) 192, 0, 2, 2})));
        byte[] ipv6 = HexFormat.of().parseHex("20010db8000000000000000000000001");
        assertEquals(crypto.ipLimitKey(InetAddress.getByAddress(ipv6)),
            crypto.ipLimitKey(Inet6Address.getByAddress("label", ipv6, 4)));
        assertThrows(IllegalArgumentException.class, () -> crypto.ipLimitKey(null));
        assertThrows(IllegalArgumentException.class, () -> crypto.combinationLimitKey("김 데모", "01000000001"));
    }

    /**
     * 잘못된 키·동일한 키를 거절하고 생성자·접근자 배열 변경이 비밀 설정에 반영되지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void protectsSecretKeys() {
        for (byte[] invalid : Arrays.asList(null, new byte[0], new byte[31], new byte[33])) {
            assertThrows(IllegalArgumentException.class, () -> new AuthSecrets("key", invalid, key(32)));
            assertThrows(IllegalArgumentException.class, () -> new AuthSecrets("key", key(0), invalid));
        }
        for (String invalid : Arrays.asList(null, "", " ", "key:id", "key\n", "키", "key.id")) {
            assertThrows(IllegalArgumentException.class, () -> new AuthSecrets(invalid, key(0), key(32)));
        }
        assertThrows(IllegalArgumentException.class, () -> new AuthSecrets("key", key(0), key(0)));
        assertThrows(IllegalArgumentException.class, () -> new AuthCrypto(null));
        byte[] codeKey = key(0);
        byte[] limitKey = key(32);
        var secrets = new AuthSecrets("key", codeKey, limitKey);
        UUID userId = UUID.randomUUID();
        var crypto = new AuthCrypto(secrets);
        String before = crypto.codeVerifier(userId, "000001");
        String beforeLimit = crypto.combinationLimitKey("데모알파", "01000000001");
        Arrays.fill(codeKey, (byte) 0);
        Arrays.fill(limitKey, (byte) 0);
        Arrays.fill(secrets.codeKey(), (byte) 0);
        Arrays.fill(secrets.limitKey(), (byte) 0);
        assertEquals(before, crypto.codeVerifier(userId, "000001"));
        assertEquals(beforeLimit, crypto.combinationLimitKey("데모알파", "01000000001"));
        assertEquals("AuthSecrets[REDACTED]", secrets.toString());
        String sentinel = "secret-do-not-expose";
        var failure = assertThrows(IllegalArgumentException.class,
            () -> new AuthSecrets(sentinel + ":", sentinel.getBytes(StandardCharsets.UTF_8), key(32)));
        assertFalse(failure.toString().contains(sentinel));
    }

    /**
     * 같은 서비스에 병렬 요청을 보내도 사용자별 HMAC·토큰 연산 상태가 섞이지 않는다.
     * @created 2026-10-22
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void isolatesConcurrentCalls() throws Exception {
        var crypto = crypto();
        List<UUID> users = new ArrayList<>();
        List<String> expected = new ArrayList<>();
        for (int index = 0; index < 96; index++) {
            users.add(UUID.randomUUID());
            expected.add(crypto.codeVerifier(users.get(index), String.format(Locale.ROOT, "%06d", index)));
        }
        try (var executor = Executors.newFixedThreadPool(8)) {
            var futures = new ArrayList<java.util.concurrent.Future<String>>();
            for (int index = 0; index < users.size(); index++) {
                int position = index;
                futures.add(executor.submit(() -> {
                    String code = String.format(Locale.ROOT, "%06d", position);
                    assertEquals(expected.get(position), crypto.codeVerifier(users.get(position), code));
                    assertTrue(crypto.verifyCode(users.get(position), code, expected.get(position)));
                    var token = crypto.issueToken();
                    assertTrue(crypto.verifyToken(token.value(), token.digest()));
                    return token.value();
                }));
            }
            var tokens = new HashSet<String>();
            for (var future : futures) assertTrue(tokens.add(future.get()));
        }
    }

    /**
     * 독립 known-answer 입력으로 공개한 결정적 테스트 키를 만든다. 운영 기본값이 아니다.
     * @created 2026-10-22
     * @usedBy AuthCryptoTest 각 검사
     * @param first 첫 바이트 값
     * @return 연속 32바이트 테스트 벡터
     */
    private static byte[] key(int first) {
        byte[] key = new byte[32];
        for (int index = 0; index < key.length; index++) key[index] = (byte) (first + index);
        return key;
    }

    /**
     * 테스트 벡터용 코드·제한 키를 분리한 연산 객체를 준비한다.
     * @created 2026-10-22
     * @usedBy AuthCryptoTest 각 검사
     * @return 사용자 상태가 없는 서비스
     */
    private static AuthCrypto crypto() { return new AuthCrypto(new AuthSecrets("test_code", key(0), key(32))); }
}
