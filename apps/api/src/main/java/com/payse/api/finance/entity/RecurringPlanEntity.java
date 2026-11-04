package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.LocalDate;
import java.util.UUID;
import org.hibernate.annotations.Immutable;

/**
 * 사용자가 승인한 월간 계획의 안정된 식별자와 시작 월만 저장한다.
 * @created 2026-11-04
 * @usedBy RecurringWrites
 */
@Entity
@Table(schema = "payse", name = "recurring_plans")
@Immutable
public class RecurringPlanEntity implements OwnedEntity {

    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "first_occurrence_month", updatable = false)
    private LocalDate firstMonth;

    /**
     * JPA 복원 전용 기본 생성자다.
     * @created 2026-11-04
     * @usedBy Hibernate
     */
    protected RecurringPlanEntity() {
    }

    /**
     * 검증된 사용자 결정과 원천 참조만 받아 새 설정 행을 만든다.
     * @created 2026-11-04
     * @usedBy RecurringWrites
     */
    public RecurringPlanEntity(
        UUID id,
        UUID userId,
        LocalDate firstMonth
    ) {
        this.id = id;
        this.userId = userId;
        this.firstMonth = firstMonth;
    }

    /**
     * 같은 인증 사용자의 저장 문맥인지 확인할 소유자를 반환한다.
     * @created 2026-11-04
     * @usedBy WriteStore
     */
    @Override
    public UUID userId() {
        return userId;
    }
}
