package com.payse.api.finance.service;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.finance.error.FinancialException;
import java.util.Base64;
import java.util.Set;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.mock.env.MockEnvironment;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * cursor의 변조·세션/버전 경계와 멱등 요청의 정확한 동일성을 검사한다.
 * @created 2026-10-29
 * @usedBy Gradle JUnit
 */
class FinancialCursorTest {
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 유효 cursor는 원위치로 복원하고 다른 사용자·세션·자료는 각각 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void bindsOwnerSessionAndVersion() {
        FinancialCursor cursor = cursor();
        UUID user = UUID.randomUUID();
        UUID session = UUID.randomUUID();
        UUID last = UUID.randomUUID();
        String encoded = cursor.encode(user, session, "version-one", last);
        assertEquals(last, cursor.decode(encoded, user, session, "version-one"));
        assertFalse(encoded.contains(user.toString()));
        assertEquals(403, assertThrows(FinancialException.class,
            () -> cursor.decode(encoded, UUID.randomUUID(), session, "version-one")).status());
        assertEquals(403, assertThrows(FinancialException.class,
            () -> cursor.decode(encoded, user, UUID.randomUUID(), "version-one")).status());
        assertEquals(409, assertThrows(FinancialException.class,
            () -> cursor.decode(encoded, user, session, "version-two")).status());
        byte[] bytes = Base64.getUrlDecoder().decode(encoded);
        bytes[15] ^= 1;
        String tampered = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
        assertEquals(400, assertThrows(FinancialException.class,
            () -> cursor.decode(tampered, user, session, "version-one")).status());
        assertEquals(400, assertThrows(FinancialException.class,
            () -> cursor.decode(encoded + "=", user, session, "version-one")).status());
    }

    /**
     * 연결 순서만 바뀌면 동일하지만 원천·연결·조회 범위가 바뀌면 다른 문맥이다.
     * @created 2026-10-29
     * @usedBy JUnit
     * @modified 2026-10-30 - 유효 v3/v4 원천 버전으로 페이지 문맥 변경을 검증
     */
    @Test
    void bindsEverySourceDimension() {
        FinancialCursor cursor = cursor();
        ObjectNode source = json.createObjectNode();
        for (String key : Set.of("userId", "schemaVersion", "dataVersion", "sourceVersion", "ruleVersion", "asOf")) {
            source.put(key, key);
        }
        source.put("schemaVersion", "PAYSE-DRAFT-3");
        source.putArray("coverage").addObject().put("requestedStart", "2025-10-20");
        String before = cursor.context(source, Set.of("bank.a", "card.b"));
        assertEquals(before, cursor.context(source, Set.of("card.b", "bank.a")));
        for (String key : Set.of("userId", "schemaVersion", "dataVersion", "sourceVersion", "ruleVersion", "asOf")) {
            ObjectNode changed = source.deepCopy().put(key,
                key.equals("schemaVersion") ? "PAYSE-DRAFT-4" : "changed");
            assertNotEquals(before, cursor.context(changed, Set.of("bank.a", "card.b")));
        }
        assertNotEquals(before, cursor.context(source, Set.of("bank.a")));
        source.putArray("coverage").addObject().put("requestedStart", "2025-10-21");
        assertNotEquals(before, cursor.context(source, Set.of("bank.a", "card.b")));
    }

    /**
     * 객체 키 순서·업무 키만 제외하고 배열 순서·null·생략·입력 공백을 구분한다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void requestIdentityPreservesMeaningfulDifferences() {
        ObjectNode first = (ObjectNode) json.readTree("{\"idempotencyKey\":\"one\",\"expectedDataVersion\":\"1\",\"label\":\" 월세 \",\"ids\":[1,2]}");
        ObjectNode reordered = (ObjectNode) json.readTree("{\"ids\":[1,2],\"label\":\" 월세 \",\"expectedDataVersion\":\"1\",\"idempotencyKey\":\"two\"}");
        String digest = FinancialJson.requestDigest("POST", "/obligations", first);
        assertEquals(digest, FinancialJson.requestDigest("POST", "/obligations", reordered));
        assertNotEquals(digest, FinancialJson.requestDigest("PATCH", "/obligations", first));
        assertNotEquals(digest, FinancialJson.requestDigest("POST", "/reserves", first));
        assertNotEquals(digest, FinancialJson.requestDigest("POST", "/obligations", first.deepCopy().put("label", "월세")));
        ObjectNode changed = first.deepCopy();
        changed.putArray("ids").add(2).add(1);
        assertNotEquals(digest, FinancialJson.requestDigest("POST", "/obligations", changed));
        assertNotEquals(digest, FinancialJson.requestDigest("POST", "/obligations", first.deepCopy().putNull("extra")));
    }

    /**
     * 명시 키가 없거나 잘못된 경우 임시 키로 시작하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit
     */
    @Test
    void requiresExplicitKey() {
        assertThrows(IllegalArgumentException.class, () -> new FinancialCursor(new MockEnvironment()));
        assertThrows(IllegalArgumentException.class, () -> new FinancialCursor(new MockEnvironment()
            .withProperty("PAYSE_FINANCE_CURSOR_KEY_BASE64", "bad")));
    }

    /**
     * 동일 자료라도 공개 스키마 전환 후 이전 cursor를 이어 쓰지 않는다.
     * @created 2026-10-30
     * @usedBy JUnit
     */
    @Test
    void versionTransitionInvalidatesCursor() {
        FinancialCursor cursor = cursor();
        ObjectNode source = json.createObjectNode().put("schemaVersion", "PAYSE-DRAFT-3");
        UUID user = UUID.randomUUID();
        UUID session = UUID.randomUUID();
        UUID last = UUID.randomUUID();
        String v3 = cursor.context(source, Set.of());
        String encoded = cursor.encode(user, session, v3, last);
        source.put("schemaVersion", "PAYSE-DRAFT-4");
        String v4 = cursor.context(source, Set.of());
        assertNotEquals(v3, v4);
        var failure = assertThrows(FinancialException.class, () -> cursor.decode(encoded, user, session, v4));
        assertEquals(409, failure.status());
        assertEquals("STALE_DATA", failure.code());
        source.put("schemaVersion", "unregistered");
        assertEquals(503, assertThrows(FinancialException.class, () -> cursor.context(source, Set.of())).status());
    }

    /**
     * 테스트 인스턴스에만 사용하는 키를 주입한다. 제품 기본 키가 아니다.
     * @created 2026-10-29
     * @usedBy 위 cursor 테스트
     */
    private FinancialCursor cursor() {
        return new FinancialCursor(new MockEnvironment().withProperty("PAYSE_FINANCE_CURSOR_KEY_BASE64",
            Base64.getEncoder().encodeToString(new byte[32])));
    }
}
