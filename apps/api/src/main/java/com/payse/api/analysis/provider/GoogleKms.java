package com.payse.api.analysis.provider;

import com.payse.ai.transport.ProviderHttp.ProviderFailure;
import com.payse.ai.transport.ProviderHttp;
import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
import java.net.URI;
import java.util.Arrays;
import java.util.Base64;
import java.util.Objects;
import java.util.function.Supplier;
import java.util.zip.CRC32C;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * Google Cloud KMS REST로 개별 데이터 키를 감싼다. 금융 본문은 KMS에 전달하지 않는다.
 * @created 2026-10-29
 * @usedBy EnvelopeCipher, GoogleKmsTest
 */
public final class GoogleKms implements KeyProtector {

    private final ProviderHttp http;
    private final Supplier<String> tokens;
    private final URI endpoint;
    private final String key;
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 운영 주소를 Google 공식 HTTPS로 고정한다. 토큰 갱신은 외부 인증 공급자가 담당한다.
     * @created 2026-10-29
     * @usedBy 미연결: 예정 사용처 분석 공급자 설정
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    public GoogleKms(ProviderHttp http, Supplier<String> tokens, String key) {
        this(http, tokens, key, URI.create(ApiConfigConstants.Analysis.KMS_ENDPOINT));
    }

    /**
     * 같은 패키지의 HTTP 모의 검사에만 다른 주소를 주입한다. 런타임 설정으로 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy GoogleKmsTest
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    GoogleKms(ProviderHttp http, Supplier<String> tokens, String key, URI endpoint) {
        this.http = Objects.requireNonNull(http, ApiMessageConstants.Analysis.HTTP);
        this.tokens = Objects.requireNonNull(tokens, ApiMessageConstants.Analysis.TOKENS);
        if (key == null || !key.matches(
            "projects/[A-Za-z0-9_-]+/locations/[A-Za-z0-9_-]+/keyRings/[A-Za-z0-9_-]+/cryptoKeys/[A-Za-z0-9_-]+"
        )) {
            throw new IllegalArgumentException(ApiMessageConstants.Analysis.INVALID_KEY_PATH);
        }

        this.key = key;
        this.endpoint = Objects.requireNonNull(endpoint, ApiMessageConstants.Analysis.ENDPOINT);
    }

    /**
     * 데이터 키·AAD의 CRC 검증과 반환 키 버전 확인 후 감싼 키만 반환한다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.encrypt
     * @modified 2026-11-01 - KMS 무결성 검증값은 실제 boolean true만 허용
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    @Override
    public WrappedKey wrap(byte[] plaintext, byte[] context) {
        if (plaintext == null || plaintext.length != 32 || context == null) {
            throw new IllegalArgumentException(ApiMessageConstants.Analysis.MISSING_KEY_CONTEXT);
        }

        ObjectNode request = json.createObjectNode();
        binary(request, ApiFieldConstants.Analysis.PLAINTEXT, plaintext);
        binary(request, ApiFieldConstants.Analysis.AUTHENTICATED_DATA, context);
        JsonNode response = http.post(
            endpoint.resolve(key + ApiConfigConstants.Analysis.ENCRYPT_ACTION),
            tokens.get(),
            request
        );
        String version = response.path(ApiFieldConstants.Analysis.NAME).asString("");
        if (!validVersion(version)
            || !verified(response, ApiFieldConstants.Analysis.PLAINTEXT_VERIFIED)
            || !verified(response, ApiFieldConstants.Analysis.AAD_VERIFIED)) {
            throw invalid();
        }

        return new WrappedKey(
            version,
            checkedBytes(response, ApiFieldConstants.Analysis.CIPHERTEXT)
        );
    }

    /**
     * 허용된 키의 부모 CryptoKey 주소로 복호화한다. 회전 전 버전도 같은 키면 사용할 수 있다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.decrypt
     * @modified 2026-11-01 - 사전 입력 거절은 KMS 전송 전 실패로 구분
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    @Override
    public byte[] unwrap(WrappedKey wrapped, byte[] context) {
        if (wrapped == null || !validVersion(wrapped.keyRef()) || context == null) {
            throw new ProviderFailure(ApiCodeConstants.Analysis.INVALID_KMS_INPUT, false);
        }

        ObjectNode request = json.createObjectNode();
        binary(request, ApiFieldConstants.Analysis.CIPHERTEXT, wrapped.ciphertext());
        binary(request, ApiFieldConstants.Analysis.AUTHENTICATED_DATA, context);
        JsonNode response = http.post(
            endpoint.resolve(key + ApiConfigConstants.Analysis.DECRYPT_ACTION),
            tokens.get(),
            request
        );
        byte[] plaintext = checkedBytes(response, ApiFieldConstants.Analysis.PLAINTEXT);
        if (plaintext.length != 32) {
            Arrays.fill(plaintext, (byte) 0);
            throw invalid();
        }
        return plaintext;
    }

    /**
     * 검증 플래그의 문자열·숫자 강제 변환을 허용하지 않는다.
     * @created 2026-11-01
     * @usedBy wrap
     */
    private boolean verified(JsonNode response, String field) {
        JsonNode value = response.path(field);
        return value.isBoolean() && value.booleanValue();
    }

    /**
     * 같은 설정 키 아래의 명시 숫자 버전만 허용한다. 응답 경로를 임의 URL로 사용하지 않는다.
     * @created 2026-10-29
     * @usedBy wrap, unwrap
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private boolean validVersion(String version) {
        String prefix = key + ApiConfigConstants.Analysis.KEY_VERSION_PATH;
        return version.startsWith(prefix)
            && version.substring(prefix.length()).matches("[1-9][0-9]*");
    }

    /**
     * Google REST의 Base64 본문과 int64 문자열 CRC32C를 만든다.
     * @created 2026-10-29
     * @usedBy wrap, unwrap
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private void binary(ObjectNode request, String field, byte[] bytes) {
        request.put(field, Base64.getEncoder().encodeToString(bytes));
        request.put(field + ApiFieldConstants.Analysis.CHECKSUM_SUFFIX, Long.toString(crc(bytes)));
    }

    /**
     * 반환 Base64·CRC32C를 검증하며 불일치한 평문 배열을 버린다.
     * @created 2026-10-29
     * @usedBy wrap, unwrap
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private byte[] checkedBytes(JsonNode response, String field) {
        byte[] bytes = null;
        try {
            if (!response.path(field).isString()) {
                throw invalid();
            }

            bytes = Base64.getDecoder().decode(response.get(field).asString());
            JsonNode checksum = response.path(field + ApiFieldConstants.Analysis.CHECKSUM_SUFFIX);
            String value = checksum.isString() ? checksum.asString() : checksum.toString();
            if (!value.matches("[0-9]+") || Long.parseLong(value) != crc(bytes)
                || bytes.length == 0) {
                throw invalid();
            }

            return bytes;
        } catch (RuntimeException failure) {
            if (bytes != null) {
                Arrays.fill(bytes, (byte) 0);
            }
            throw invalid();
        }
    }

    /**
     * 전송 무결성용 CRC32C를 계산한다. 인증 암호나 키 소유권 검증을 대신하지 않는다.
     * @created 2026-10-29
     * @usedBy binary, checkedBytes
     */
    private long crc(byte[] bytes) {
        CRC32C checksum = new CRC32C();
        checksum.update(bytes, 0, bytes.length);
        return checksum.getValue();
    }

    /**
     * 키·공급자 본문이 없는 공통 KMS 무결성 실패를 만든다.
     * @created 2026-10-29
     * @usedBy wrap, unwrap, checkedBytes
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private ProviderFailure invalid() {
        return new ProviderFailure(ApiCodeConstants.Analysis.INVALID_KMS_RESPONSE, true);
    }
}
