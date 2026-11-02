package com.payse.api.finance.service;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
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
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    public FinancialCursor(Environment environment) {
        byte[] value = null;
        try {
            String encoded = environment
                .getProperty(ApiConfigConstants.Finance.PAYSE_FINANCE_CURSOR_KEY_BASE64);
            if (encoded == null) {
                throw new IllegalArgumentException();
            }

            value = Base64.getDecoder().decode(encoded);
            if (value.length != 32 || !Base64.getEncoder()
                .encodeToString(value)
                .equals(encoded)) {
                throw new IllegalArgumentException();
            }

            key = new SecretKeySpec(value, ApiConfigConstants.Finance.KEY_ALGORITHM);
        } catch (IllegalArgumentException failure) {
            throw new IllegalArgumentException(ApiMessageConstants.Finance.INVALID_CURSOR_KEY);
        } finally {
            if (value != null) {
                Arrays.fill(value, (byte) 0);
            }
        }
    }

    /**
     * 고정 조회 문맥·마지막 UUID를 새 nonce로 암호화한다. 원천 일정은 계산하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialService.snapshot
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 기존 100건 경로를 보존하며 목적별 페이지 크기 경로로 위임
     */
    public String encode(UUID user, UUID session, String context, UUID lastId) {
        return encode(user, session, context, lastId, 100);
    }

    /**
     * 목적별 문맥과 페이지 크기를 암호화 봉투에 함께 고정한다.
     * @created 2026-11-01
     * @usedBy encode, MemoryCatalog.select
     * @modified 2026-11-02 - 기존 상수·개행 기준으로 목적별 페이지 크기 경로 통합
     */
    public String encode(UUID user, UUID session, String context, UUID lastId, int size) {
        if (size < 1 || size > 100) {
            throw new IllegalArgumentException(ApiMessageConstants.Finance.INVALID_PAGE_SIZE);
        }

        ObjectNode payload = json.createObjectNode()
            .put(ApiFieldConstants.Finance.USER, user.toString())
            .put(ApiFieldConstants.Finance.SESSION, session.toString())
            .put(ApiFieldConstants.Finance.CONTEXT, context)
            .put(ApiFieldConstants.Finance.LAST, lastId.toString())
            .put(ApiFieldConstants.Finance.SIZE, size);
        byte[] nonce = new byte[12];
        random.nextBytes(nonce);
        try {
            Cipher cipher = cipher(Cipher.ENCRYPT_MODE, nonce);
            byte[] encrypted = cipher.doFinal(payload.toString().getBytes(StandardCharsets.UTF_8));
            byte[] combined = new byte[nonce.length + encrypted.length];
            System.arraycopy(nonce, 0, combined, 0, nonce.length);
            System.arraycopy(encrypted, 0, combined, nonce.length, encrypted.length);
            return Base64.getUrlEncoder()
                .withoutPadding()
                .encodeToString(combined);
        } catch (GeneralSecurityException failure) {
            throw new FinancialException(503, ApiCodeConstants.Finance.TEMPORARILY_UNAVAILABLE);
        }
    }

    /**
     * 변조 400·다른 사용자/세션 403·변경된 조회 문맥 409를 구분한다.
     * @created 2026-10-29
     * @usedBy FinancialService.snapshot
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 기존 100건 경로를 보존하며 목적별 페이지 크기를 검증
     */
    public UUID decode(String encoded, UUID user, UUID session, String context) {
        return decode(encoded, user, session, context, 100);
    }

    /**
     * 다른 크기·목적의 페이지를 섞지 않고 소유자·세션·조회 문맥을 재검증한다.
     * @created 2026-11-01
     * @usedBy decode, MemoryCatalog.select
     * @modified 2026-11-02 - 기존 암호화·오류 경계를 보존하며 페이지 크기 경로 통합
     */
    public UUID decode(String encoded, UUID user, UUID session, String context, int size) {
        if (size < 1 || size > 100) {
            throw new IllegalArgumentException(ApiMessageConstants.Finance.INVALID_PAGE_SIZE);
        }

        JsonNode payload;
        UUID last;
        try {
            if (encoded == null || encoded.length() > 2048 || !encoded.matches("[A-Za-z0-9_-]+")) {
                throw new IllegalArgumentException();
            }

            byte[] bytes = Base64.getUrlDecoder().decode(encoded);
            if (bytes.length < 29 || !Base64.getUrlEncoder()
                .withoutPadding()
                .encodeToString(bytes)
                .equals(encoded)) {
                throw new IllegalArgumentException();
            }

            byte[] nonce = Arrays.copyOfRange(bytes, 0, 12);
            byte[] plain = cipher(Cipher.DECRYPT_MODE, nonce).doFinal(bytes, 12, bytes.length - 12);
            payload = json.readTree(plain);
            if (!payload.isObject() || !Set.copyOf(payload.propertyNames())
                .equals(
                    Set.of(
                        ApiFieldConstants.Finance.USER,
                        ApiFieldConstants.Finance.SESSION,
                        ApiFieldConstants.Finance.CONTEXT,
                        ApiFieldConstants.Finance.LAST,
                        ApiFieldConstants.Finance.SIZE
                    )
                )
                || !payload.path(ApiFieldConstants.Finance.SIZE).isIntegralNumber()
                || payload.path(ApiFieldConstants.Finance.SIZE).intValue() != size) {
                throw new IllegalArgumentException();
            }

            var cursorFields = Set.of(
                ApiFieldConstants.Finance.USER,
                ApiFieldConstants.Finance.SESSION,
                ApiFieldConstants.Finance.CONTEXT,
                ApiFieldConstants.Finance.LAST
            );
            for (String field : cursorFields) {
                if (!payload.path(field).isString()) {
                    throw new IllegalArgumentException();
                }
            }

            last = UUID.fromString(payload.get(ApiFieldConstants.Finance.LAST).asString());
        } catch (GeneralSecurityException | RuntimeException failure) {
            throw new FinancialException(400, ApiCodeConstants.Finance.INVALID_CURSOR);
        }

        if (!user.toString().equals(payload.get(ApiFieldConstants.Finance.USER).asString())
            || !session.toString()
                .equals(payload.get(ApiFieldConstants.Finance.SESSION).asString())) {
            throw new FinancialException(403, ApiCodeConstants.Finance.RESOURCE_FORBIDDEN);
        }
        if (!context.equals(payload.get(ApiFieldConstants.Finance.CONTEXT).asString())) {
            throw new FinancialException(409, ApiCodeConstants.Finance.STALE_DATA);
        }

        return last;
    }

    /**
     * 모든 버전·시점·연결·조회 범위를 지문에 묶는다. 연결 순서는 의미 없이 정렬한다.
     * @created 2026-10-29
     * @usedBy FinancialService.snapshot
     * @modified 2026-10-30 - 원천에 대응하는 공개 v3/v4 버전을 cursor 문맥에 명시
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     */
    public String context(ObjectNode source, Set<String> codes) {
        String schema = source.path(ApiFieldConstants.Finance.SCHEMA_VERSION).asString("");
        String apiSchema = switch (schema) {
        case ApiConfigConstants.Finance.DRAFT_V3 -> ApiConfigConstants.Finance.API_V3;
        case ApiConfigConstants.Finance.DRAFT_V4 -> ApiConfigConstants.Finance.API_V4;
        default -> throw FinancialProjection.unavailable();
        };
        ObjectNode value = json.createObjectNode()
            .put(ApiFieldConstants.Finance.API_SCHEMA, apiSchema)
            .put(ApiFieldConstants.Finance.SIZE, 100);
        var contextFields = Set.of(
            ApiFieldConstants.Finance.USER_ID,
            ApiFieldConstants.Finance.SCHEMA_VERSION,
            ApiFieldConstants.Finance.DATA_VERSION,
            ApiFieldConstants.Finance.SOURCE_VERSION,
            ApiFieldConstants.Finance.RULE_VERSION,
            ApiFieldConstants.Finance.AS_OF,
            ApiFieldConstants.Finance.COVERAGE
        );
        for (String field : contextFields) {
            value.set(field, source.get(field));
        }

        var links = value.putArray(ApiFieldConstants.Finance.CONNECTIONS);
        codes.stream()
            .sorted()
            .forEach(links::add);
        return FinancialJson.digest(value);
    }

    /**
     * 호출마다 독립 AES-GCM 객체를 만든다. Cipher의 가변 상태를 공유하지 않는다.
     * @created 2026-10-29
     * @usedBy encode, decode
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private Cipher cipher(int mode, byte[] nonce) throws GeneralSecurityException {
        Cipher cipher = Cipher.getInstance(ApiConfigConstants.Finance.CIPHER_ALGORITHM);
        cipher.init(mode, key, new GCMParameterSpec(128, nonce));
        cipher.updateAAD(AAD);
        return cipher;
    }
}
