package com.payse.api.auth.crypto;

import com.payse.api.auth.vo.AuthCredentials;
import com.payse.api.auth.vo.IssuedToken;
import java.net.InetAddress;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.HexFormat;
import java.util.UUID;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * JDK 암호 API로 토큰·코드·제한 키를 만든다. 계정·세션·실패 횟수는 보관하지 않는다.
 * @created 2026-10-22
 * @usedBy AuthCryptoConfiguration.authCrypto, AuthService
 */
public final class AuthCrypto {
    private final AuthSecrets secrets;
    private final SecureRandom random = new SecureRandom();

    /**
     * 검증된 불변 비밀 설정을 주입한다.
     * @created 2026-10-22
     * @usedBy AuthCryptoConfiguration.authCrypto, AuthCryptoTest
     * @param secrets 코드·제한 키가 분리된 설정
     */
    public AuthCrypto(AuthSecrets secrets) {
        if (secrets == null) throw new IllegalArgumentException("Authentication secrets are required");
        this.secrets = secrets;
    }

    /**
     * SecureRandom 32바이트를 Base64url 무패딩으로 인코딩하고 저장용 digest를 만든다.
     * @created 2026-10-22
     * @usedBy AuthService 로그인 성공, AuthCryptoTest
     * @return 응답용 원문과 저장용 digest
     */
    public IssuedToken issueToken() {
        byte[] bytes = new byte[32];
        random.nextBytes(bytes);
        String token = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        Arrays.fill(bytes, (byte) 0);
        return new IssuedToken(token, tokenDigest(token));
    }

    /**
     * 원문을 변경하지 않고 지정 토큰 형식 검사 후 UTF-8 SHA-256 digest를 계산한다.
     * @created 2026-10-22
     * @usedBy AuthCrypto.issueToken, AuthCrypto.verifyToken, 미연결: 예정 Bearer 검증
     * @param token 32바이트를 인코딩한 정규 Base64url 무패딩 원문
     * @return sha256 접두사와 소문자 hex
     */
    public String tokenDigest(String token) {
        if (!isCanonicalToken(token)) throw new IllegalArgumentException("Invalid session token format");
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(token.getBytes(StandardCharsets.UTF_8));
            return "sha256:" + HexFormat.of().formatHex(digest);
        } catch (GeneralSecurityException failure) {
            throw new IllegalStateException("Required authentication algorithm unavailable");
        }
    }

    /**
     * 정규 인코딩 외 별칭·패딩·공백을 허용하지 않는다.
     * @created 2026-10-22
     * @usedBy AuthCrypto.tokenDigest, AuthCrypto.verifyToken
     * @param token 검사할 토큰
     * @return 32바이트 정규 형식 여부
     */
    private static boolean isCanonicalToken(String token) {
        if (token == null || !token.matches("[A-Za-z0-9_-]{43}")) return false;
        byte[] decoded = Base64.getUrlDecoder().decode(token);
        boolean valid = Base64.getUrlEncoder().withoutPadding().encodeToString(decoded).equals(token);
        Arrays.fill(decoded, (byte) 0);
        return valid;
    }

    /**
     * 유효 형식의 digest 바이트를 일정 시간 비교 API로 확인한다.
     * @created 2026-10-22
     * @usedBy AuthService, AuthCryptoTest
     * @param token 클라이언트의 토큰 원문
     * @param storedDigest 저장된 sha256 검증값
     * @return 잘못된 형식 또는 불일치이면 false
     */
    public boolean verifyToken(String token, String storedDigest) {
        if (!isCanonicalToken(token) || storedDigest == null || !storedDigest.matches("sha256:[0-9a-f]{64}")) {
            return false;
        }
        return MessageDigest.isEqual(
            HexFormat.of().parseHex(tokenDigest(token).substring(7)),
            HexFormat.of().parseHex(storedDigest.substring(7)));
    }

    /**
     * 사용자 ID와 코드 도메인에 묶인 HMAC verifier를 생성한다.
     * @created 2026-10-22
     * @usedBy AuthCrypto.verifyCode, 미연결: 예정 합성 계정 코드 준비, AuthCryptoTest
     * @param userId 서버에서 확인한 사용자 UUID
     * @param code 정규화하지 않은 ASCII 숫자 6자리
     * @return hmac-sha256 키 ID와 소문자 hex
     */
    public String codeVerifier(UUID userId, String code) {
        if (userId == null) throw new IllegalArgumentException("Authentication user ID is required");
        AuthCredentials.requireCode(code);
        String value = "payse-code-v1\n" + userId + "\n" + code;
        return "hmac-sha256:" + secrets.codeKeyId() + ":" + hmac(secrets.codeKey(), value);
    }

    /**
     * 활성 키 ID의 verifier만 받아 digest 바이트를 일정 시간 비교한다.
     * @created 2026-10-22
     * @usedBy AuthService, AuthCryptoTest
     * @param userId 확인할 서버 사용자 UUID
     * @param code 제출 코드
     * @param storedVerifier 서버 저장 검증값
     * @return DISABLED·미지원 키·잘못된 형식·불일치이면 false
     */
    public boolean verifyCode(UUID userId, String code, String storedVerifier) {
        if (userId == null || code == null || !code.matches("[0-9]{6}") || storedVerifier == null) return false;
        String prefix = "hmac-sha256:" + secrets.codeKeyId() + ":";
        if (!storedVerifier.startsWith(prefix)) return false;
        String storedHex = storedVerifier.substring(prefix.length());
        if (!storedHex.matches("[0-9a-f]{64}")) return false;
        String calculatedHex = codeVerifier(userId, code).substring(prefix.length());
        return MessageDigest.isEqual(HexFormat.of().parseHex(calculatedHex), HexFormat.of().parseHex(storedHex));
    }

    /**
     * 코드와 무관하게 정규화된 이름·전화번호의 제한 식별값을 만든다.
     * @created 2026-10-22
     * @usedBy 미연결: 예정 인증 제한 서비스, AuthCryptoTest
     * @param name 합성 이름 입력
     * @param phone 합성 전화번호 입력
     * @return 제한 키로 만든 HMAC-SHA256 소문자 hex
     */
    public String combinationLimitKey(String name, String phone) {
        String value = "payse-limit-combo-v1\n" + AuthCredentials.normalizeName(name)
            + "\n" + AuthCredentials.normalizePhone(phone);
        return hmac(secrets.limitKey(), value);
    }

    /**
     * 확인된 연결 IP의 주소 바이트를 정규화하여 별도 IP 도메인으로 제한 키를 만든다.
     * @created 2026-10-22
     * @usedBy 미연결: 예정 신뢰 프록시·연결 주소 어댑터, AuthCryptoTest
     * @param peer 서버 연결 또는 검증된 프록시에서 얻은 주소; 이 메서드는 DNS·헤더를 해석하지 않음
     * @return HMAC-SHA256 소문자 hex
     */
    public String ipLimitKey(InetAddress peer) {
        if (peer == null) throw new IllegalArgumentException("Authentication peer address is required");
        byte[] bytes = peer.getAddress();
        boolean mapped = bytes.length == 16 && bytes[10] == (byte) 0xff && bytes[11] == (byte) 0xff;
        for (int index = 0; mapped && index < 10; index++) mapped = bytes[index] == 0;
        if (mapped) bytes = Arrays.copyOfRange(bytes, 12, 16);
        String normalized;
        if (bytes.length == 4) {
            normalized = Byte.toUnsignedInt(bytes[0]) + "." + Byte.toUnsignedInt(bytes[1])
                + "." + Byte.toUnsignedInt(bytes[2]) + "." + Byte.toUnsignedInt(bytes[3]);
        } else {
            StringBuilder address = new StringBuilder();
            for (int index = 0; index < bytes.length; index += 2) {
                if (index > 0) address.append(':');
                int group = Byte.toUnsignedInt(bytes[index]) * 256 + Byte.toUnsignedInt(bytes[index + 1]);
                address.append(Integer.toHexString(group));
            }
            normalized = address.toString();
        }
        return hmac(secrets.limitKey(), "payse-limit-ip-v1\n" + normalized);
    }

    /**
     * 호출마다 별도 Mac을 만들고 전달받은 임시 키 사본을 연산 후 지운다.
     * @created 2026-10-22
     * @usedBy AuthCrypto.codeVerifier, AuthCrypto.combinationLimitKey, AuthCrypto.ipLimitKey
     * @param key 연산 후 지울 비밀 키 사본
     * @param value 도메인이 포함된 UTF-8 입력
     * @return 소문자 HMAC hex
     */
    private static String hmac(byte[] key, String value) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return HexFormat.of().formatHex(mac.doFinal(value.getBytes(StandardCharsets.UTF_8)));
        } catch (GeneralSecurityException failure) {
            throw new IllegalStateException("Required authentication algorithm unavailable");
        } finally {
            Arrays.fill(key, (byte) 0);
        }
    }
}
