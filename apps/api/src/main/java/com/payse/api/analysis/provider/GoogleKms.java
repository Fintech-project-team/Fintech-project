package com.payse.api.analysis.provider;

import com.payse.api.analysis.crypto.KeyProtector;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.provider.ProviderHttp.ProviderFailure;
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
     */
    public GoogleKms(ProviderHttp http, Supplier<String> tokens, String key) {
        this(http, tokens, key, URI.create("https://cloudkms.googleapis.com/v1/"));
    }

    /**
     * 같은 패키지의 HTTP 모의 검사에만 다른 주소를 주입한다. 런타임 설정으로 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy GoogleKmsTest
     */
    GoogleKms(ProviderHttp http, Supplier<String> tokens, String key, URI endpoint) {
        this.http = Objects.requireNonNull(http, "http");
        this.tokens = Objects.requireNonNull(tokens, "tokens");
        if (key == null || !key.matches("projects/[A-Za-z0-9_-]+/locations/[A-Za-z0-9_-]+/keyRings/[A-Za-z0-9_-]+/cryptoKeys/[A-Za-z0-9_-]+")) {
            throw new IllegalArgumentException("One approved CryptoKey path is required");
        }
        this.key = key;
        this.endpoint = Objects.requireNonNull(endpoint, "endpoint");
    }

    /**
     * 데이터 키·AAD의 CRC 검증과 반환 키 버전 확인 후 감싼 키만 반환한다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.encrypt
     */
    @Override
    public WrappedKey wrap(byte[] plaintext, byte[] context) {
        if (plaintext == null || plaintext.length != 32 || context == null) {
            throw new IllegalArgumentException("Memory key and context are required");
        }
        ObjectNode request = json.createObjectNode();
        binary(request, "plaintext", plaintext);
        binary(request, "additionalAuthenticatedData", context);
        JsonNode response = http.post(endpoint.resolve(key + ":encrypt"), tokens.get(), request);
        String version = response.path("name").asString("");
        if (!validVersion(version) || !response.path("verifiedPlaintextCrc32c").asBoolean(false)
                || !response.path("verifiedAdditionalAuthenticatedDataCrc32c").asBoolean(false)) {
            throw invalid();
        }
        return new WrappedKey(version, checkedBytes(response, "ciphertext"));
    }

    /**
     * 허용된 키의 부모 CryptoKey 주소로 복호화한다. 회전 전 버전도 같은 키면 사용할 수 있다.
     * @created 2026-10-29
     * @usedBy EnvelopeCipher.decrypt
     */
    @Override
    public byte[] unwrap(WrappedKey wrapped, byte[] context) {
        if (wrapped == null || !validVersion(wrapped.keyRef()) || context == null) throw invalid();
        ObjectNode request = json.createObjectNode();
        binary(request, "ciphertext", wrapped.ciphertext());
        binary(request, "additionalAuthenticatedData", context);
        JsonNode response = http.post(endpoint.resolve(key + ":decrypt"), tokens.get(), request);
        byte[] plaintext = checkedBytes(response, "plaintext");
        if (plaintext.length != 32) {
            Arrays.fill(plaintext, (byte) 0);
            throw invalid();
        }
        return plaintext;
    }

    /**
     * 같은 설정 키 아래의 명시 숫자 버전만 허용한다. 응답 경로를 임의 URL로 사용하지 않는다.
     * @created 2026-10-29
     * @usedBy wrap, unwrap
     */
    private boolean validVersion(String version) {
        String prefix = key + "/cryptoKeyVersions/";
        return version.startsWith(prefix) && version.substring(prefix.length()).matches("[1-9][0-9]*");
    }

    /**
     * Google REST의 Base64 본문과 int64 문자열 CRC32C를 만든다.
     * @created 2026-10-29
     * @usedBy wrap, unwrap
     */
    private void binary(ObjectNode request, String field, byte[] bytes) {
        request.put(field, Base64.getEncoder().encodeToString(bytes));
        request.put(field + "Crc32c", Long.toString(crc(bytes)));
    }

    /**
     * 반환 Base64·CRC32C를 검증하며 불일치한 평문 배열을 버린다.
     * @created 2026-10-29
     * @usedBy wrap, unwrap
     */
    private byte[] checkedBytes(JsonNode response, String field) {
        byte[] bytes = null;
        try {
            if (!response.path(field).isString()) throw invalid();
            bytes = Base64.getDecoder().decode(response.get(field).asString());
            JsonNode checksum = response.path(field + "Crc32c");
            String value = checksum.isString() ? checksum.asString() : checksum.toString();
            if (!value.matches("[0-9]+") || Long.parseLong(value) != crc(bytes) || bytes.length == 0) throw invalid();
            return bytes;
        } catch (RuntimeException failure) {
            if (bytes != null) Arrays.fill(bytes, (byte) 0);
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
     */
    private ProviderFailure invalid() { return new ProviderFailure("INVALID_KMS_RESPONSE", true); }
}
