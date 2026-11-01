package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.analysis.service.MemoryPolicy.Access;
import com.payse.api.analysis.service.MemoryPolicy.Availability;
import com.payse.api.analysis.service.MemoryPolicy.Memory;
import com.payse.api.analysis.service.MemoryPolicy.Retention;
import java.time.Instant;
import org.junit.jupiter.api.Test;

/**
 * 확정된 한국 시각 보관 경계와 중요보존·현재 참조 자격의 독립성을 검사한다.
 * @created 2026-10-29
 * @usedBy Gradle JUnit test
 */
class MemoryPolicyTest {
    private final MemoryPolicy policy = new MemoryPolicy();
    private final Instant storedAt = Instant.parse("2026-01-31T06:00:00Z");

    /**
     * 1월31일 한국15시에서 4월30일15시로 보정하고, 경계 직전과 정확한 만료를 구분한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void expiresAtCalendarBoundary() {
        Instant expiry = Instant.parse("2026-04-30T06:00:00Z");
        Memory memory = new Memory(storedAt, true, false, false, null, null);
        assertEquals(expiry, policy.normalExpiry(storedAt));
        assertEquals(Retention.RETAINED, policy.retention(memory, expiry.minusNanos(1)));
        assertEquals(Retention.EXPIRED, policy.retention(memory, expiry));
        assertEquals(expiry, policy.normalExpiry(storedAt));
    }

    /**
     * UTC 월이 달라도 한국 달력 월로 기산하며 윤년과 연도 경계를 보존한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void usesSeoulCalendar() {
        assertEquals(Instant.parse("2026-04-30T15:10:00Z"),
            policy.normalExpiry(Instant.parse("2026-01-31T15:10:00Z")));
        assertEquals(Instant.parse("2024-02-29T06:00:00Z"),
            policy.normalExpiry(Instant.parse("2023-11-30T06:00:00Z")));
        assertEquals(Instant.parse("2027-02-28T06:00:00Z"),
            policy.normalExpiry(Instant.parse("2026-11-30T06:00:00Z")));
    }

    /**
     * 중요보존 해제 시 원래 기한을 사용하며 새 3개월을 부여하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void removalDoesNotRestartRetention() {
        Instant later = Instant.parse("2026-06-01T06:00:00Z");
        assertEquals(Retention.RETAINED,
            policy.retention(new Memory(storedAt, true, true, true, null, null), later));
        assertEquals(Retention.EXPIRED,
            policy.retention(new Memory(storedAt, true, true, false, null, null), later));
    }

    /**
     * 중요보존이어도 삭제·탈퇴 기한을 넘지 않고 탈퇴 즉시 현재 사용은 차단한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void deletionAndWithdrawalOverrideImportance() {
        Instant withdrawn = Instant.parse("2026-02-01T06:00:00Z");
        Memory memory = new Memory(storedAt, true, true, true, null, withdrawn);
        assertEquals(Retention.RETAINED, policy.retention(memory, withdrawn));
        assertEquals(Availability.FORBIDDEN, policy.availability(memory, withdrawn, new Access(true, true)));
        assertEquals(Retention.WITHDRAWAL_EXPIRED,
            policy.retention(memory, Instant.parse("2027-02-01T06:00:00Z")));
        Memory deleted = new Memory(storedAt, true, true, true, withdrawn, null);
        assertEquals(Retention.DELETED, policy.retention(deleted, withdrawn));
        assertEquals(Availability.DELETED, policy.availability(deleted, withdrawn, new Access(true, true)));
    }

    /**
     * 일반 자료는 탈퇴 후1년 정책으로 원래 3개월을 연장하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void withdrawalDoesNotExtendOrdinaryMemory() {
        Memory memory = new Memory(storedAt, true, false, false, null, Instant.parse("2026-02-01T06:00:00Z"));
        assertEquals(Retention.EXPIRED, policy.retention(memory, Instant.parse("2026-05-01T06:00:00Z")));
    }

    /**
     * 관련 근거 변경·권한 상실·비활성은 장기 보관과 분리하여 현재 참조만 차단한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void retainedDoesNotMeanApplicable() {
        Instant later = Instant.parse("2026-06-01T06:00:00Z");
        Memory memory = new Memory(storedAt, true, true, true, null, null);
        assertEquals(Retention.RETAINED, policy.retention(memory, later));
        assertEquals(Availability.AVAILABLE, policy.availability(memory, later, new Access(true, true)));
        assertEquals(Availability.STALE, policy.availability(memory, later, new Access(true, false)));
        assertEquals(Availability.FORBIDDEN, policy.availability(memory, later, new Access(false, true)));
        assertEquals(Availability.INACTIVE, policy.availability(
            new Memory(storedAt, false, true, true, null, null), later, new Access(true, true)));
    }

    /**
     * 잘못된 메타데이터를 만료 또는 정상 보관 상태로 숨기지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void rejectsInvalidMetadata() {
        assertThrows(IllegalArgumentException.class,
            () -> new Memory(storedAt, true, false, true, null, null));
        assertThrows(IllegalArgumentException.class,
            () -> new Memory(storedAt, true, false, false, storedAt.minusSeconds(1), null));
        assertThrows(IllegalArgumentException.class,
            () -> policy.retention(new Memory(storedAt, true, false, false, null, null), storedAt.minusSeconds(1)));
    }
}
