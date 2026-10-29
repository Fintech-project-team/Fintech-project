package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.LocalDate;
import java.util.UUID;
import org.hibernate.annotations.DynamicUpdate;

/**
 * 사용자 의무의 수정 가능한 열만 매핑한다. 원천 청구·반복 연결 열은 INSERT·UPDATE하지 않는다.
 * @created 2026-10-29
 * @usedBy 금융 설정 JPA 저장
 */
@Entity
@Table(schema = "payse", name = "obligations")
@DynamicUpdate
public class ObligationEntity implements OwnedEntity {
    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "label")
    private String label;

    @Column(name = "withdrawal_account_id")
    private UUID accountId;

    @Column(name = "amount_krw")
    private long amount;

    @Column(name = "due_date")
    private LocalDate dueDate;

    @Column(name = "status")
    private String status;

    /**
     * JPA가 저장 행을 복원할 때만 사용하는 기본 생성자다.
     * @created 2026-10-29
     * @usedBy Hibernate 엔티티 복원
     */
    protected ObligationEntity() { }

    /**
     * 같은 인증 사용자 소유인지 검증할 내부 소유자 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity, FinancialReceipts
     */
    public UUID userId() {
        return userId;
    }

    /**
     * 새 단건 사용자 의무만 생성한다. 원천·계획 참조는 DB의 null 상태로 둔다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     */
    public ObligationEntity(UUID id, UUID userId, String label, UUID accountId, long amount, LocalDate dueDate) {
        this.id = id;
        this.userId = userId;
        this.label = label;
        this.accountId = accountId;
        this.amount = amount;
        this.dueDate = dueDate;
        status = "active";
    }

    /**
     * 허용된 사용자 의무 필드만 변경한다. 정산·반복 참조는 매핑하지 않는다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     */
    public void change(String label, UUID accountId, long amount, LocalDate dueDate) {
        this.label = label;
        this.accountId = accountId;
        this.amount = amount;
        this.dueDate = dueDate;
    }

    /**
     * 원천 청구의 금액·일정·계좌를 건드리지 않고 사용자 명칭만 변경한다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     */
    public void rename(String label) {
        this.label = label;
    }

    /**
     * 검증된 사용자 의무를 논리 취소한다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     */
    public void cancel() {
        status = "cancelled";
    }
}
