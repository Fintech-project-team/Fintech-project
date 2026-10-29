package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.util.UUID;
import org.hibernate.annotations.ColumnTransformer;
import org.hibernate.annotations.DynamicUpdate;

/**
 * 이미 존재하는 사용자 급여·카드 속성 행의 허용 설정만 변경한다.
 * @created 2026-10-29
 * @usedBy 금융 설정 JPA 저장
 */
@Entity
@Table(schema = "payse", name = "user_attributes")
@DynamicUpdate
public class UserSettingsEntity implements OwnedEntity {
    @Id
    @Column(name = "user_id", insertable = false, updatable = false)
    private UUID userId;

    @Column(name = "salary_day", insertable = false)
    private Integer salaryDay;

    @Column(name = "salary_amount_krw", insertable = false)
    private Long salaryAmount;

    @Column(name = "salary_account_id", insertable = false)
    private UUID salaryAccount;

    @ColumnTransformer(write = "?::jsonb")
    @Column(name = "card_plan_overrides", insertable = false, columnDefinition = "jsonb")
    private String cardPlans;

    /**
     * JPA가 저장 행을 복원할 때만 사용하는 기본 생성자다.
     * @created 2026-10-29
     * @usedBy Hibernate 엔티티 복원
     */
    protected UserSettingsEntity() { }

    /**
     * 같은 인증 사용자 소유인지 검증할 내부 소유자 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity, FinancialReceipts
     */
    public UUID userId() {
        return userId;
    }

    /**
     * PATCH 생략 규칙을 적용한 확정 설정을 저장하며 급여 원천 근거는 별도 유지한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites
     */
    public void change(Integer day, Long amount, UUID account, String cardPlans) {
        salaryDay = day;
        salaryAmount = amount;
        salaryAccount = account;
        this.cardPlans = cardPlans;
    }
}
