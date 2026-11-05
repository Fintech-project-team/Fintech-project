package com.payse.api.finance.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.util.UUID;
import org.hibernate.annotations.Immutable;

/**
 * 반복 후보에 대한 명시 승인·제외와 당시 근거를 불변 이력으로 저장한다.
 * @created 2026-11-04
 * @usedBy RecurringWrites
 */
@Entity
@Table(schema = "payse", name = "recurring_decisions")
@Immutable
public class RecurringDecisionEntity implements OwnedEntity {

    @Id
    @Column(name = "id", updatable = false)
    private UUID id;

    @Column(name = "user_id", updatable = false)
    private UUID userId;

    @Column(name = "candidate_key", updatable = false)
    private String candidateKey;

    @Column(name = "rule_version", updatable = false)
    private String ruleVersion;

    @Column(name = "source_version", updatable = false)
    private String sourceVersion;

    @org.hibernate.annotations.ColumnTransformer(write = "?::jsonb")
    @Column(name = "evidence_refs", updatable = false, columnDefinition = "jsonb")
    private String evidence;

    @Column(name = "normalized_name", updatable = false)
    private String name;

    @Column(name = "decision", updatable = false)
    private String decision;

    @Column(name = "plan_id", updatable = false)
    private UUID planId;

    /**
     * JPA 복원 전용 기본 생성자다.
     * @created 2026-11-04
     * @usedBy Hibernate
     */
    protected RecurringDecisionEntity() {
    }

    /**
     * 검증된 사용자 결정과 원천 참조만 받아 새 설정 행을 만든다.
     * @created 2026-11-04
     * @usedBy RecurringWrites
     */
    public RecurringDecisionEntity(
        UUID id,
        UUID userId,
        String candidateKey,
        String ruleVersion,
        String sourceVersion,
        String evidence,
        String name,
        String decision,
        UUID planId
    ) {
        this.id = id;
        this.userId = userId;
        this.candidateKey = candidateKey;
        this.ruleVersion = ruleVersion;
        this.sourceVersion = sourceVersion;
        this.evidence = evidence;
        this.name = name;
        this.decision = decision;
        this.planId = planId;
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
