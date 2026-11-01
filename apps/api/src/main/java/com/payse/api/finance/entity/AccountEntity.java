package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.util.UUID;
import org.hibernate.annotations.DynamicUpdate;

/**
 * 계좌의 사용자 선택·별칭만 변경하는 JPA 엔티티다. 원천 열은 쓰기 매핑에서 제외한다.
 * @created 2026-10-29
 * @usedBy 금융 설정 JPA 저장
 */
@Entity
@Table(schema = "payse", name = "financial_accounts")
@DynamicUpdate
public class AccountEntity implements OwnedEntity {
    @Id
    @Column(name = "id", insertable = false, updatable = false)
    private UUID id;

    @Column(name = "user_id", insertable = false, updatable = false)
    private UUID userId;

    @Column(name = "included", insertable = false)
    private boolean included;

    @Column(name = "nickname", insertable = false)
    private String nickname;

    /**
     * JPA가 저장 행을 복원할 때만 사용하는 기본 생성자다.
     * @created 2026-10-29
     * @usedBy Hibernate 엔티티 복원
     */
    protected AccountEntity() { }

    /**
     * 같은 인증 사용자 소유인지 검증할 내부 소유자 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity, FinancialReceipts
     */
    public UUID userId() {
        return userId;
    }

    /**
     * 계좌 원천과 별개인 홈 선택만 변경한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites
     */
    public void select(boolean included) {
        this.included = included;
    }

    /**
     * 검증된 사용자 별칭만 변경하며 null은 해제다.
     * @created 2026-10-29
     * @usedBy SettingsWrites
     */
    public void rename(String nickname) {
        this.nickname = nickname;
    }
}
