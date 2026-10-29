package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.time.OffsetDateTime;
import java.util.UUID;
import org.hibernate.annotations.ColumnTransformer;
import org.hibernate.annotations.Immutable;

/**
 * 멱등 성공 영수증을 불변 JPA 행으로 저장한다. 외부 응답으로 엔티티를 직접 반환하지 않는다.
 * @created 2026-10-29
 * @usedBy 금융 설정 JPA 저장
 */
@Entity
@Table(schema = "payse", name = "write_receipts")
@Immutable
public class WriteReceiptEntity implements OwnedEntity {
    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "operation_key", updatable = false)
    private String operationKey;

    @Column(name = "request_digest", updatable = false)
    private String requestDigest;

    @Column(name = "action", updatable = false)
    private String action;

    @ColumnTransformer(write = "?::jsonb")
    @Column(name = "changed_refs", updatable = false, columnDefinition = "jsonb")
    private String changedRefs;

    @ColumnTransformer(write = "?::jsonb")
    @Column(name = "before_after", updatable = false, columnDefinition = "jsonb")
    private String beforeAfter;

    @Column(name = "result_version", updatable = false)
    private long resultVersion;

    @Column(name = "created_at", updatable = false)
    private OffsetDateTime createdAt;

    /**
     * JPA가 저장 행을 복원할 때만 사용하는 기본 생성자다.
     * @created 2026-10-29
     * @usedBy Hibernate 엔티티 복원
     */
    protected WriteReceiptEntity() { }

    /**
     * 같은 인증 사용자 소유인지 검증할 내부 소유자 ID를 반환한다.
     * @created 2026-10-29
     * @usedBy WriteStore.entity, FinancialReceipts
     */
    public UUID userId() {
        return userId;
    }

    /**
     * 검증한 요청의 성공 영수증을 한 번만 생성한다. 이후 수정 API는 제공하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts.save
     */
    public WriteReceiptEntity(UUID id, UUID userId, String operationKey, String requestDigest, String action, String changedRefs, String beforeAfter, long resultVersion, OffsetDateTime createdAt) {
        this.id = id;
        this.userId = userId;
        this.operationKey = operationKey;
        this.requestDigest = requestDigest;
        this.action = action;
        this.changedRefs = changedRefs;
        this.beforeAfter = beforeAfter;
        this.resultVersion = resultVersion;
        this.createdAt = createdAt;
    }

    /**
     * 저장한 영수증의 id 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public UUID id() {
        return id;
    }

    /**
     * 저장한 영수증의 operationKey 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public String operationKey() {
        return operationKey;
    }

    /**
     * 저장한 영수증의 requestDigest 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public String requestDigest() {
        return requestDigest;
    }

    /**
     * 저장한 영수증의 action 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public String action() {
        return action;
    }

    /**
     * 저장한 영수증의 changedRefs 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public String changedRefs() {
        return changedRefs;
    }

    /**
     * 저장한 영수증의 beforeAfter 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public String beforeAfter() {
        return beforeAfter;
    }

    /**
     * 저장한 영수증의 resultVersion 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public long resultVersion() {
        return resultVersion;
    }

    /**
     * 저장한 영수증의 createdAt 값을 내부 조립에 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts
     */
    public OffsetDateTime createdAt() {
        return createdAt;
    }
}
