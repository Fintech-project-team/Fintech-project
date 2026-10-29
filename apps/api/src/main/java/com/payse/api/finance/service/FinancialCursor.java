package com.payse.api.finance.service;

import com.payse.api.finance.error.FinancialException;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import java.util.Set;
import java.util.UUID;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;
import org.springframework.context.annotation.Profile;
import org.springframework.core.env.Environment;
import org.springframework.stereotype.Component;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 금융 페이지 위치와 조회 문맥을 인증 암호화한다. 토큰·자격·금융 원문은 포함하지 않는다.
 * @created 2026-10-29
 * @usedBy FinancialService
 */
@Component
@Profile("database & auth & finance")
public final class FinancialCursor {
    private static final byte[] AAD = "PAYSE-cursor-v1".getBytes(StandardCharsets.US_ASCII);
    private final SecretKeySpec key;
    private final SecureRandom random = new SecureRandom();
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 별도 32바이트 서버 키를 요구한다. 임시 키나 인증 키를 묵시적으로 재사용하지 않는다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입, FinancialCursorTest
     */
    public FinancialCursor(Environment environment) {
        byte[] value = null;
        try {
            String encoded = environment.getProperty("PAYSE_FINANCE_CURSOR_KEY_BASE64");
            if (encoded == null) throw new IllegalArgumentException();
            value = Base64.getDecoder().decode(encoded);
            if (value.length != 32 || !Base64.getEncoder().encodeToString(value).equals(encoded)) {
                throw new IllegalArgumentException();
            }
            key = new SecretKeySpec(value, "AES");
        } catch (IllegalArgumentException failure) {
            throw new IllegalArgumentException("Invalid required financial cursor key configuration");
        } finally {
            if (value != null) Arrays.fill(value, (byte) 0);
        }
    }

    /**
     * 고정 조회 문맥·마지막 UUID를 새 nonce로 암호화한다. 원천 일정은 계산하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialService.snapshot
     */
    public String encode(UUID user, UUID session, String context, UUID lastId) {
        ObjectNode payload = json.createObjectNode().put("user", user.toString()).put("session", session.toString())
            .put("context", context).put("last", lastId.toString()).put("size", 100);
        byte[] nonce = new byte[12];
        random.nextBytes(nonce);
        try {
            Cipher cipher = cipher(Cipher.ENCRYPT_MODE, nonce);
            byte[] encrypted = cipher.doFinal(payload.toString().getBytes(StandardCharsets.UTF_8));
            byte[] combined = new byte[nonce.length + encrypted.length];
            System.arraycopy(nonce, 0, combined, 0, nonce.length);
            System.arraycopy(encrypted, 0, combined, nonce.length, encrypted.length);
            return Base64.getUrlEncoder().withoutPadding().encodeToString(combined);
        } catch (GeneralSecurityException failure) {
            throw new FinancialException(503, "TEMPORARILY_UNAVAILABLE");
        }
    }

    /**
     * 변조 400·다른 사용자/세션 403·변경된 조회 문맥 409를 구분한다.
     * @created 2026-10-29
     * @usedBy FinancialService.snapshot
     */
    public UUID decode(String encoded, UUID user, UUID session, String context) {
        JsonNode payload;
        UUID last;
        try {
            if (encoded == null || encoded.length() > 2048 || !encoded.matches("[A-Za-z0-9_-]+")) {
                throw new IllegalArgumentException();
            }
            byte[] bytes = Base64.getUrlDecoder().decode(encoded);
            if (bytes.length < 29 || !Base64.getUrlEncoder().withoutPadding().encodeToString(bytes).equals(encoded)) {
                throw new IllegalArgumentException();
            }
            byte[] nonce = Arrays.copyOfRange(bytes, 0, 12);
            byte[] plain = cipher(Cipher.DECRYPT_MODE, nonce).doFinal(bytes, 12, bytes.length - 12);
            payload = json.readTree(plain);
            if (!payload.isObject() || !Set.copyOf(payload.propertyNames()).equals(Set.of("user", "session", "context", "last", "size"))
                    || !payload.path("size").isIntegralNumber() || payload.path("size").intValue() != 100) {
                throw new IllegalArgumentException();
            }
            for (String field : Set.of("user", "session", "context", "last")) {
                if (!payload.path(field).isString()) throw new IllegalArgumentException();
            }
            last = UUID.fromString(payload.get("last").asString());
        } catch (GeneralSecurityException | RuntimeException failure) {
            throw new FinancialException(400, "INVALID_CURSOR");
        }
        if (!user.toString().equals(payload.get("user").asString())
                || !session.toString().equals(payload.get("session").asString())) {
            throw new FinancialException(403, "RESOURCE_FORBIDDEN");
        }
        if (!context.equals(payload.get("context").asString())) throw new FinancialException(409, "STALE_DATA");
        return last;
    }

    /**
     * 모든 버전·시점·연결·조회 범위를 지문에 묶는다. 연결 순서는 의미 없이 정렬한다.
     * @created 2026-10-29
     * @usedBy FinancialService.snapshot
     */
    public String context(ObjectNode source, Set<String> codes) {
        ObjectNode value = json.createObjectNode().put("apiSchema", "PAYSE-API-0.6-3").put("size", 100);
        for (String field : Set.of("userId", "schemaVersion", "dataVersion", "sourceVersion", "ruleVersion", "asOf", "coverage")) {
            value.set(field, source.get(field));
        }
        var links = value.putArray("connections");
        codes.stream().sorted().forEach(links::add);
        return FinancialJson.digest(value);
    }

    /**
     * 호출마다 독립 AES-GCM 객체를 만든다. Cipher의 가변 상태를 공유하지 않는다.
     * @created 2026-10-29
     * @usedBy encode, decode
     */
    private Cipher cipher(int mode, byte[] nonce) throws GeneralSecurityException {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(mode, key, new GCMParameterSpec(128, nonce));
        cipher.updateAAD(AAD);
        return cipher;
    }
}
