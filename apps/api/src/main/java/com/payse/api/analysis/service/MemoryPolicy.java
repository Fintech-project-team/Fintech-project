package com.payse.api.analysis.service;

import java.time.Instant;
import java.time.ZoneId;
import java.util.Objects;

/**
 * 개별 분석 기억의 보관 기한과 현재 참조 자격을 구분한다. 금융 날짜는 계산하지 않는다.
 * @created 2026-10-29
 * @usedBy 미연결: 예정 사용처 분석 결과 저장·조회·폐기 서비스, MemoryPolicyTest
 */
public final class MemoryPolicy {
    private static final ZoneId SEOUL = ZoneId.of("Asia/Seoul");

    /**
     * 최초 저장 시각에서 달력 3개월 뒤 같은 한국 시각을 반환한다. 없는 날짜는 말일이다.
     * @created 2026-10-29
     * @usedBy retention, MemoryPolicyTest
     */
    public Instant normalExpiry(Instant storedAt) {
        return Objects.requireNonNull(storedAt, "storedAt").atZone(SEOUL).plusMonths(3).toInstant();
    }

    /**
     * 삭제·탈퇴 후 1년·일반 만료를 검사한다. 중요보존 예외는 참고자료에만 적용한다.
     * @created 2026-10-29
     * @usedBy availability, 미연결: 예정 사용처 분석 기억 폐기 서비스
     */
    public Retention retention(Memory memory, Instant now) {
        Objects.requireNonNull(memory, "memory");
        Objects.requireNonNull(now, "now");
        if (now.isBefore(memory.storedAt())) {
            throw new IllegalArgumentException("Current time precedes the stored memory");
        }
        if (memory.deletedAt() != null) return Retention.DELETED;
        if (memory.withdrawnAt() != null
                && !now.isBefore(memory.withdrawnAt().atZone(SEOUL).plusYears(1).toInstant())) {
            return Retention.WITHDRAWAL_EXPIRED;
        }
        if (memory.important()) return Retention.RETAINED;
        return now.isBefore(normalExpiry(memory.storedAt())) ? Retention.RETAINED : Retention.EXPIRED;
    }

    /**
     * 보관 중이어도 탈퇴·비활성·권한 상실·관련 근거 변경이면 현재 적용을 막는다.
     * @created 2026-10-29
     * @usedBy 미연결: 예정 사용처 분석 결과 재사용 서비스, MemoryPolicyTest
     */
    public Availability availability(Memory memory, Instant now, Access access) {
        Objects.requireNonNull(access, "access");
        Retention retained = retention(memory, now);
        if (!access.authorized() || memory.withdrawnAt() != null) return Availability.FORBIDDEN;
        if (retained == Retention.DELETED) return Availability.DELETED;
        if (retained != Retention.RETAINED) return Availability.EXPIRED;
        if (!memory.active()) return Availability.INACTIVE;
        if (!access.evidenceCurrent()) return Availability.STALE;
        return Availability.AVAILABLE;
    }

    /**
     * 보존 판정에 필요한 불변 시각과 독립 플래그다. required 참조 정책은 보관 예외가 아니다.
     * @created 2026-10-29
     * @usedBy retention, availability
     */
    public record Memory(Instant storedAt, boolean active, boolean reference, boolean important,
            Instant deletedAt, Instant withdrawnAt) {
        /**
         * 의미 없는 중요보존 조합과 저장 전 삭제 시각을 거절한다.
         * @created 2026-10-29
         * @usedBy 분석 기억을 읽는 호출부, MemoryPolicyTest
         */
        public Memory {
            Objects.requireNonNull(storedAt, "storedAt");
            if (important && !reference) throw new IllegalArgumentException("Important memory must be reference data");
            if (deletedAt != null && deletedAt.isBefore(storedAt)) {
                throw new IllegalArgumentException("Deletion precedes storage");
            }
        }
    }

    /**
     * 조회 또는 채택 직전에 확인한 접근권한과 관련 원천·사용자 정정 유효성이다.
     * @created 2026-10-29
     * @usedBy availability
     */
    public record Access(boolean authorized, boolean evidenceCurrent) {}

    /**
     * 보관 허용과 폐기 대상을 구분하며 실제 키·백업 파쇄 완료를 표현하지 않는다.
     * @created 2026-10-29
     * @usedBy retention
     */
    public enum Retention { RETAINED, EXPIRED, DELETED, WITHDRAWAL_EXPIRED }

    /**
     * 내부 재사용 판정이다. 공개 API의 집계 상태나 오류 코드로 그대로 직렬화하지 않는다.
     * @created 2026-10-29
     * @usedBy availability
     */
    public enum Availability { AVAILABLE, EXPIRED, DELETED, INACTIVE, STALE, FORBIDDEN }
}
