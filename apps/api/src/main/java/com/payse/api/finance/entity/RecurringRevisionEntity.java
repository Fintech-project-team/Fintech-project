package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.LocalDate;
import java.util.UUID;
import org.hibernate.annotations.Immutable;

/**
 * 승인된 첫 계획 버전만 저장한다. 이후 일정과 금액을 서버에서 산출하지 않는다.
 * @created 2026-11-04
 * @usedBy RecurringWrites
 */
@Entity
@Table(schema = "payse", name = "recurring_plan_revisions")
@Immutable
public class RecurringRevisionEntity implements OwnedEntity {

    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "plan_id", updatable = false)
    private UUID planId;

    @Column(name = "effective_from_month", updatable = false)
    private LocalDate firstMonth;

    @Column(name = "label", updatable = false)
    private String label;

    @Column(name = "amount_krw", updatable = false)
    private long amount;

    @Column(name = "monthly_day", updatable = false)
    private int monthlyDay;

    @Column(name = "payment_timing", updatable = false)
    private String paymentTiming;

    @Column(name = "schedule_basis", updatable = false)
    private String scheduleBasis;

    @Column(name = "withdrawal_account_id", updatable = false)
    private UUID accountId;

    @Column(name = "card_id", updatable = false)
    private UUID cardId;

    @Column(name = "status", updatable = false)
    private String status = com.payse.api.constants.ApiCodeConstants.Finance.ACTIVE;

    @org.hibernate.annotations.ColumnTransformer(write = "?::jsonb")
    @Column(name = "schedule_overrides", updatable = false, columnDefinition = "jsonb")
    private String overrides = "[]";

    @Column(name = "is_current", updatable = false)
    private boolean current = true;
    /**
     * JPA 복원 전용 기본 생성자다.
     * @created 2026-11-04
     * @usedBy Hibernate
     */
    protected RecurringRevisionEntity() {
    }

    /**
     * 검증된 사용자 결정과 원천 참조만 받아 새 설정 행을 만든다.
     * @created 2026-11-04
     * @usedBy RecurringWrites
     */
    public RecurringRevisionEntity(
        UUID id,
        UUID userId,
        UUID planId,
        LocalDate firstMonth,
        String label,
        long amount,
        int monthlyDay,
        String paymentTiming,
        String scheduleBasis,
        UUID accountId,
        UUID cardId
    ) {
        this.id = id;
        this.userId = userId;
        this.planId = planId;
        this.firstMonth = firstMonth;
        this.label = label;
        this.amount = amount;
        this.monthlyDay = monthlyDay;
        this.paymentTiming = paymentTiming;
        this.scheduleBasis = scheduleBasis;
        this.accountId = accountId;
        this.cardId = cardId;
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
