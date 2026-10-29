package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.hibernate.annotations.DynamicUpdate;

/**
 * 연결 동의를 생성하고 해제 시각만 변경하며 이전 동의 행은 보존한다.
 * @created 2026-10-29
 * @usedBy 금융 설정 JPA 저장
 */
@Entity
@Table(schema = "payse", name = "institution_links")
@DynamicUpdate
public class InstitutionLinkEntity implements OwnedEntity {
    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "institution_code", updatable = false)
    private String institutionCode;

    @Column(name = "consented_at", updatable = false)
    private OffsetDateTime consentedAt;

    @Column(name = "disconnected_at")
    private OffsetDateTime disconnectedAt;

    /**
     * JPA가 저장 행을 복원할 때만 사용하는 기본 생성자다.
     * @created 2026-10-29
     * @usedBy Hibernate 엔티티 복원
     */
    protected InstitutionLinkEntity() { }

    /**
     * 같은 인증 사용자 소유인지 검증할 내부 소유자 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity, FinancialReceipts
     */
    public UUID userId() {
        return userId;
    }

    /**
     * 검증한 기관 동의를 새 식별자로 기록한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites
     */
    public InstitutionLinkEntity(UUID id, UUID userId, String institutionCode, OffsetDateTime consentedAt) {
        this.id = id;
        this.userId = userId;
        this.institutionCode = institutionCode;
        this.consentedAt = consentedAt;
    }

    /**
     * 기존 동의 시각을 바꾸지 않고 현재 연결만 종료한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites
     */
    public void disconnect(OffsetDateTime time) {
        disconnectedAt = time;
    }
}
