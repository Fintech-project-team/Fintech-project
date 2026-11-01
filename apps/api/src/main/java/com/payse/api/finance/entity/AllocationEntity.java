package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.util.UUID;
import org.hibernate.annotations.ColumnTransformer;
import org.hibernate.annotations.DynamicUpdate;

/**
 * 명시 배정 총액을 변경하고 기존 지급 해제 누계·근거에는 UPDATE를 생성하지 않는다.
 * @created 2026-10-29
 * @usedBy 금융 설정 JPA 저장
 */
@Entity
@Table(schema = "payse", name = "reserve_allocations")
@DynamicUpdate
public class AllocationEntity implements OwnedEntity {
    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "reserve_id", updatable = false)
    private UUID reserveId;

    @Column(name = "obligation_id", updatable = false)
    private UUID obligationId;

    @Column(name = "amount_krw")
    private long amount;

    @Column(name = "released_krw", updatable = false)
    private long released;

    @ColumnTransformer(write = "?::jsonb")
    @Column(name = "release_evidence", updatable = false, columnDefinition = "jsonb")
    private String releaseEvidence;

    /**
     * JPA가 저장 행을 복원할 때만 사용하는 기본 생성자다.
     * @created 2026-10-29
     * @usedBy Hibernate 엔티티 복원
     */
    protected AllocationEntity() { }

    /**
     * 같은 인증 사용자 소유인지 검증할 내부 소유자 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity, FinancialReceipts
     */
    public UUID userId() {
        return userId;
    }

    /**
     * 미지급 배정을 0원 해제 누계와 빈 근거로 생성한다.
     * @created 2026-10-29
     * @usedBy AllocationWrites
     */
    public AllocationEntity(UUID id, UUID userId, UUID reserveId, UUID obligationId, long amount) {
        this.id = id;
        this.userId = userId;
        this.reserveId = reserveId;
        this.obligationId = obligationId;
        this.amount = amount;
        released = 0;
        releaseEvidence = "[]";
    }

    /**
     * 해제 누계 이상으로 검증한 총 배정액만 변경한다.
     * @created 2026-10-29
     * @usedBy AllocationWrites
     */
    public void changeAmount(long amount) {
        this.amount = amount;
    }
}
