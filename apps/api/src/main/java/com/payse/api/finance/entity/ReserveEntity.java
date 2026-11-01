package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.hibernate.annotations.DynamicUpdate;

/**
 * 현재 보호 설정을 저장하며 실제 계좌 잔액은 변경하지 않는다.
 * @created 2026-10-29
 * @usedBy 금융 설정 JPA 저장
 */
@Entity
@Table(schema = "payse", name = "reserves")
@DynamicUpdate
public class ReserveEntity implements OwnedEntity {
    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "account_id")
    private UUID accountId;

    @Column(name = "label")
    private String label;

    @Column(name = "amount_krw")
    private long amount;

    @Column(name = "cancelled_at")
    private OffsetDateTime cancelledAt;

    /**
     * JPA가 저장 행을 복원할 때만 사용하는 기본 생성자다.
     * @created 2026-10-29
     * @usedBy Hibernate 엔티티 복원
     */
    protected ReserveEntity() { }

    /**
     * 같은 인증 사용자 소유인지 검증할 내부 소유자 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity, FinancialReceipts
     */
    public UUID userId() {
        return userId;
    }

    /**
     * 새 보호 설정을 만든다. 배정은 같은 트랜잭션의 별도 엔티티로 생성한다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     */
    public ReserveEntity(UUID id, UUID userId, UUID accountId, String label, long amount) {
        this.id = id;
        this.userId = userId;
        this.accountId = accountId;
        this.label = label;
        this.amount = amount;
    }

    /**
     * 검증된 계좌·명칭·보호 금액만 변경한다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     */
    public void change(UUID accountId, String label, long amount) {
        this.accountId = accountId;
        this.label = label;
        this.amount = amount;
    }

    /**
     * 명시적으로 취소하되 보호액·지급 이력은 파괴하지 않는다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     */
    public void cancel(OffsetDateTime time) {
        cancelledAt = time;
    }
}
