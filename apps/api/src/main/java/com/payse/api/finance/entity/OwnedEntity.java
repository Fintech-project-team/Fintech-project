package com.payse.api.finance.entity;

import java.util.UUID;

/**
 * JPA 1차 캐시로 복원한 행도 인증 소유자와 다시 비교하도록 소유자 접근을 통일한다.
 * @created 2026-10-29
 * @usedBy WriteStore.entity
 */
public interface OwnedEntity {
    /**
     * 서버가 검증한 사용자 ID와 비교할 저장 소유자를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity
     */
    UUID userId();
}
