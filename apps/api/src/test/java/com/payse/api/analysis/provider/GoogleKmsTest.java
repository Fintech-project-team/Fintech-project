package com.payse.api.analysis.provider;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.provider.ProviderHttp.ProviderFailure;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.zip.CRC32C;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 로컬 HTTP 대역으로 KMS의 키 경계·AAD·CRC32C와 전송 전 거절을 검사한다.
 * @created 2026-11-01
 * @usedBy JUnit 5
 */
class GoogleKmsTest {
    private static final String KEY = "projects/test-project/locations/global/keyRings/test-ring/cryptoKeys/memory";
    private static final String VERSION = KEY + "/cryptoKeyVersions/7";
    private static final byte[] PLAINTEXT = "0123456789abcdef0123456789abcdef".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CONTEXT = "123456789".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] CIPHERTEXT = "synthetic-wrapped-key".getBytes(StandardCharsets.US_ASCII);
    private static final JsonMapper JSON = JsonMapper.builder().build();

    /**
     * 32바이트 키와 AAD를 각 CRC32C와 함께 보내고 명시 키 버전을 보존한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void wrapsKeyWithCrc32cAndAuthenticatedContext() throws Exception {
        try (var stub = new ProviderStub()) {
            stub.reply(200, JSON.writeValueAsString(encryptedResponse()));
            var kms = new GoogleKms(stub.http(), () -> "synthetic-token", KEY, stub.endpoint());

            WrappedKey wrapped = kms.wrap(PLAINTEXT, CONTEXT);

            assertEquals(VERSION, wrapped.keyRef());
            assertArrayEquals(CIPHERTEXT, wrapped.ciphertext());
            assertEquals(1, stub.requests().size());
            var request = stub.requests().getFirst();
            assertEquals("/v1/" + KEY + ":encrypt", request.path());
            assertEquals("Bearer synthetic-token", request.authorization());
            assertBinary(request.body(), "plaintext", PLAINTEXT);
            assertBinary(request.body(), "additionalAuthenticatedData", CONTEXT);
            assertEquals("3808858755", request.body().path("additionalAuthenticatedDataCrc32c").asString());
            assertEquals(4, request.body().size());
        }
    }

    /**
     * 이전 숫자 버전도 같은 키라면 부모 CryptoKey로 복호화하고 AAD를 함께 전송한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void unwrapsEarlierVersionThroughConfiguredParentKey() throws Exception {
        try (var stub = new ProviderStub()) {
            stub.reply(200, JSON.writeValueAsString(binaryResponse("plaintext", PLAINTEXT)));
            var kms = new GoogleKms(stub.http(), () -> "synthetic-token", KEY, stub.endpoint());

            byte[] unwrapped = kms.unwrap(new WrappedKey(KEY + "/cryptoKeyVersions/1", CIPHERTEXT), CONTEXT);

            assertArrayEquals(PLAINTEXT, unwrapped);
            assertEquals(1, stub.requests().size());
            var request = stub.requests().getFirst();
            assertEquals("/v1/" + KEY + ":decrypt", request.path());
            assertBinary(request.body(), "ciphertext", CIPHERTEXT);
            assertBinary(request.body(), "additionalAuthenticatedData", CONTEXT);
            assertEquals(4, request.body().size());
        }
    }

    /**
     * 누락·잘못된 길이의 평문 키와 누락 AAD는 토큰 조회와 HTTP 전송 전에 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsInvalidWrapInputsBeforeSending() throws Exception {
        try (var stub = new ProviderStub()) {
            var tokenCalls = new AtomicInteger();
            var kms = new GoogleKms(stub.http(), () -> "synthetic-" + tokenCalls.incrementAndGet(), KEY, stub.endpoint());

            assertThrows(IllegalArgumentException.class, () -> kms.wrap(null, CONTEXT));
            for (int length : new int[] {0, 31, 33}) {
                assertThrows(IllegalArgumentException.class, () -> kms.wrap(new byte[length], CONTEXT));
            }
            assertThrows(IllegalArgumentException.class, () -> kms.wrap(PLAINTEXT, null));

            assertEquals(0, tokenCalls.get());
            assertTrue(stub.requests().isEmpty());
        }
    }

    /**
     * 다른 CryptoKey와 비정상 버전 참조는 외부 전송 가능성을 남기지 않고 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsForeignOrMalformedWrappedKeyReferencesBeforeSending() throws Exception {
        try (var stub = new ProviderStub()) {
            var tokenCalls = new AtomicInteger();
            var kms = new GoogleKms(stub.http(), () -> "synthetic-" + tokenCalls.incrementAndGet(), KEY, stub.endpoint());
            List<String> references = List.of(
                KEY + "-other/cryptoKeyVersions/7", KEY,
                KEY + "/cryptoKeyVersions/0", KEY + "/cryptoKeyVersions/01",
                KEY + "/cryptoKeyVersions/-1", KEY + "/cryptoKeyVersions/latest",
                VERSION + "/extra", VERSION + "?other=1");

            assertFalse(assertThrows(ProviderFailure.class, () -> kms.unwrap(null, CONTEXT)).mayHaveBeenSent());
            for (String reference : references) {
                var wrapped = new WrappedKey(reference, CIPHERTEXT);
                ProviderFailure failure = assertThrows(ProviderFailure.class, () -> kms.unwrap(wrapped, CONTEXT));
                assertFalse(failure.mayHaveBeenSent(), reference);
            }

            assertEquals(0, tokenCalls.get());
            assertTrue(stub.requests().isEmpty());
        }
    }

    /**
     * 정상 감싼 키라도 AAD가 누락되면 외부 전송 없이 실패한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsMissingUnwrapContextWithoutSending() throws Exception {
        try (var stub = new ProviderStub()) {
            var tokenCalls = new AtomicInteger();
            var kms = new GoogleKms(stub.http(), () -> "synthetic-" + tokenCalls.incrementAndGet(), KEY, stub.endpoint());

            ProviderFailure failure = assertThrows(ProviderFailure.class,
                () -> kms.unwrap(new WrappedKey(VERSION, CIPHERTEXT), null));

            assertFalse(failure.mayHaveBeenSent());
            assertEquals(0, tokenCalls.get());
            assertTrue(stub.requests().isEmpty());
        }
    }

    /**
     * 암호화 성공 응답도 다른 키·누락·비정상 숫자 버전이면 수락하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsForeignOrMalformedEncryptResponseVersions() throws Exception {
        for (String reference : List.of("", KEY + "-other/cryptoKeyVersions/7",
                KEY + "/cryptoKeyVersions/0", KEY + "/cryptoKeyVersions/01",
                KEY + "/cryptoKeyVersions/latest", VERSION + "/extra")) {
            ObjectNode response = encryptedResponse();
            response.put("name", reference);
            assertRejectedWrapResponse(response);
        }
        ObjectNode missing = encryptedResponse();
        missing.remove("name");
        assertRejectedWrapResponse(missing);
    }

    /**
     * CRC 검증 확인값은 실제 boolean true만 허용하고 문자열·숫자·누락을 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void requiresBooleanTrueForBothEncryptVerificationFlags() throws Exception {
        for (String field : List.of("verifiedPlaintextCrc32c", "verifiedAdditionalAuthenticatedDataCrc32c")) {
            for (String invalidJson : List.of("false", "\"true\"", "1", "null", "{}", "[]")) {
                ObjectNode response = encryptedResponse();
                response.set(field, JSON.readTree(invalidJson));
                assertRejectedWrapResponse(response);
            }
            ObjectNode missing = encryptedResponse();
            missing.remove(field);
            assertRejectedWrapResponse(missing);
        }
    }

    /**
     * 암호문 Base64·CRC 누락과 손상을 응답 본문 노출 없이 전송 후 실패로 구분한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsInvalidCiphertextBase64AndCrc32c() throws Exception {
        for (String encoded : List.of("%%%", "")) {
            ObjectNode response = encryptedResponse();
            response.put("ciphertext", encoded);
            assertRejectedWrapResponse(response);
        }
        for (String checksum : List.of("0", "-1", "not-a-checksum", "18446744073709551616", "1.5")) {
            ObjectNode response = encryptedResponse();
            response.put("ciphertextCrc32c", checksum);
            assertRejectedWrapResponse(response);
        }
        for (String field : List.of("ciphertext", "ciphertextCrc32c")) {
            ObjectNode response = encryptedResponse();
            response.remove(field);
            assertRejectedWrapResponse(response);
        }
        ObjectNode wrongType = encryptedResponse();
        wrongType.put("ciphertext", 17);
        assertRejectedWrapResponse(wrongType);
    }

    /**
     * 복호화 응답은 정확한 32바이트 평문과 유효 Base64·CRC32C를 모두 요구한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsWrongPlaintextLengthAndDamagedDecryptResponses() throws Exception {
        for (int length : new int[] {0, 31, 33}) {
            assertRejectedUnwrapResponse(binaryResponse("plaintext", new byte[length]));
        }
        ObjectNode badBase64 = binaryResponse("plaintext", PLAINTEXT);
        badBase64.put("plaintext", "%%%synthetic-invalid%%%");
        assertRejectedUnwrapResponse(badBase64);
        ObjectNode badCrc = binaryResponse("plaintext", PLAINTEXT);
        badCrc.put("plaintextCrc32c", "0");
        assertRejectedUnwrapResponse(badCrc);
        for (String field : List.of("plaintext", "plaintextCrc32c")) {
            ObjectNode response = binaryResponse("plaintext", PLAINTEXT);
            response.remove(field);
            assertRejectedUnwrapResponse(response);
        }
    }

    /**
     * 토큰 공급자를 각 요청에 다시 호출해 갱신된 자격을 다음 전송에 사용한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void obtainsFreshTokenForEveryWrapAndUnwrap() throws Exception {
        try (var stub = new ProviderStub()) {
            var tokenCalls = new AtomicInteger();
            var kms = new GoogleKms(stub.http(), () -> "synthetic-token-" + tokenCalls.incrementAndGet(), KEY, stub.endpoint());
            stub.reply(200, JSON.writeValueAsString(encryptedResponse()));
            WrappedKey wrapped = kms.wrap(PLAINTEXT, CONTEXT);
            stub.reply(200, JSON.writeValueAsString(binaryResponse("plaintext", PLAINTEXT)));

            assertArrayEquals(PLAINTEXT, kms.unwrap(wrapped, CONTEXT));

            assertEquals(2, tokenCalls.get());
            assertEquals(2, stub.requests().size());
            assertEquals("Bearer synthetic-token-1", stub.requests().get(0).authorization());
            assertEquals("Bearer synthetic-token-2", stub.requests().get(1).authorization());
        }
    }

    /**
     * 정상 암호화 응답의 키 버전과 실제 boolean 검증값을 준비한다.
     * @created 2026-11-01
     * @usedBy GoogleKmsTest
     */
    private static ObjectNode encryptedResponse() {
        ObjectNode response = binaryResponse("ciphertext", CIPHERTEXT);
        response.put("name", VERSION);
        response.put("verifiedPlaintextCrc32c", true);
        response.put("verifiedAdditionalAuthenticatedDataCrc32c", true);
        return response;
    }

    /**
     * 합성 바이트의 Base64와 표준 CRC32C 문자열 응답을 준비한다.
     * @created 2026-11-01
     * @usedBy GoogleKmsTest.encryptedResponse, GoogleKmsTest
     */
    private static ObjectNode binaryResponse(String field, byte[] bytes) {
        ObjectNode response = JSON.createObjectNode();
        response.put(field, Base64.getEncoder().encodeToString(bytes));
        response.put(field + "Crc32c", checksum(bytes));
        return response;
    }

    /**
     * 요청의 Base64 내용과 int64 문자열 CRC32C를 함께 확인한다.
     * @created 2026-11-01
     * @usedBy GoogleKmsTest.wrapsKeyWithCrc32cAndAuthenticatedContext, GoogleKmsTest.unwrapsEarlierVersionThroughConfiguredParentKey
     */
    private static void assertBinary(JsonNode request, String field, byte[] expected) {
        assertTrue(request.path(field).isString());
        assertArrayEquals(expected, Base64.getDecoder().decode(request.path(field).asString()));
        assertTrue(request.path(field + "Crc32c").isString());
        assertEquals(checksum(expected), request.path(field + "Crc32c").asString());
    }

    /**
     * 표준 CRC32C로 합성 데이터의 비교값을 계산한다.
     * @created 2026-11-01
     * @usedBy GoogleKmsTest.binaryResponse, GoogleKmsTest.assertBinary
     */
    private static String checksum(byte[] bytes) {
        CRC32C checksum = new CRC32C();
        checksum.update(bytes, 0, bytes.length);
        return Long.toString(checksum.getValue());
    }

    /**
     * 잘못된 암호화 응답이 한 번 전송된 뒤 공개 오류 분류로만 거절되는지 확인한다.
     * @created 2026-11-01
     * @usedBy GoogleKmsTest.rejectsForeignOrMalformedEncryptResponseVersions, GoogleKmsTest.requiresBooleanTrueForBothEncryptVerificationFlags, GoogleKmsTest.rejectsInvalidCiphertextBase64AndCrc32c
     */
    private static void assertRejectedWrapResponse(ObjectNode response) throws Exception {
        try (var stub = new ProviderStub()) {
            stub.reply(200, JSON.writeValueAsString(response));
            var kms = new GoogleKms(stub.http(), () -> "synthetic-token", KEY, stub.endpoint());
            ProviderFailure failure = assertThrows(ProviderFailure.class, () -> kms.wrap(PLAINTEXT, CONTEXT));
            assertEquals("INVALID_KMS_RESPONSE", failure.getMessage());
            assertTrue(failure.mayHaveBeenSent());
            assertNull(failure.getCause());
            assertEquals(1, stub.requests().size());
        }
    }

    /**
     * 잘못된 복호화 응답을 평문 반환 없이 전송 후 무결성 실패로 구분한다.
     * @created 2026-11-01
     * @usedBy GoogleKmsTest.rejectsWrongPlaintextLengthAndDamagedDecryptResponses
     */
    private static void assertRejectedUnwrapResponse(ObjectNode response) throws Exception {
        try (var stub = new ProviderStub()) {
            stub.reply(200, JSON.writeValueAsString(response));
            var kms = new GoogleKms(stub.http(), () -> "synthetic-token", KEY, stub.endpoint());
            ProviderFailure failure = assertThrows(ProviderFailure.class,
                () -> kms.unwrap(new WrappedKey(VERSION, CIPHERTEXT), CONTEXT));
            assertEquals("INVALID_KMS_RESPONSE", failure.getMessage());
            assertTrue(failure.mayHaveBeenSent());
            assertNull(failure.getCause());
            assertEquals(1, stub.requests().size());
        }
    }
}
