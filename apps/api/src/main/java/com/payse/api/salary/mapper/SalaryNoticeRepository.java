package com.payse.api.salary.mapper;

import com.payse.api.salary.vo.SalaryMonth;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.orm.jpa.EntityManagerProxy;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 같은 인증 JPA 트랜잭션에서 급여 회차별 안내 기록만 읽고 최초 닫기 시각을 저장한다.
 * @created 2026-10-30
 * @usedBy SalaryNoticeService
 */
@Repository
@Profile("database & auth & finance & salary-notices")
public class SalaryNoticeRepository {
    private final EntityManager entityManager;
    private final EntityManagerFactory factory;

    /**
     * 기존 인증과 같은 EntityManagerFactory의 공유 JPA 문맥을 받는다.
     * @created 2026-10-30
     * @usedBy Spring 생성자 주입
     */
    public SalaryNoticeRepository(EntityManager entityManager) {
        this.entityManager = entityManager;
        this.factory = entityManager.getEntityManagerFactory();
    }

    /**
     * 조회는 행을 만들지 않으며 기록이 없으면 접지 않은 상태로 반환한다.
     * @created 2026-10-30
     * @usedBy SalaryNoticeService.read, dismiss
     */
    public Optional<Instant> find(UUID owner, SalaryMonth month) {
        requireOwner(owner);
        List<?> rows = entityManager.createNativeQuery("""
            SELECT dismissed_at
            FROM payse.salary_notice_dismissals
            WHERE user_id = ?1
              AND pay_month = ?2
            """).setParameter(1, owner).setParameter(2, month.value()).getResultList();
        if (rows.size() > 1) throw new IllegalStateException("Salary notice identity is not unique");
        if (rows.isEmpty()) return Optional.empty();
        Object value = rows.getFirst();
        if (value instanceof Instant time) return Optional.of(time);
        if (value instanceof OffsetDateTime time) return Optional.of(time.toInstant());
        if (value instanceof Timestamp time) return Optional.of(time.toInstant());
        throw new IllegalStateException("Salary notice time is invalid");
    }

    /**
     * 최초 기록만 삽입한다. 반복 요청은 최초 시각을 유지하고 금융 버전을 올리지 않는다.
     * @created 2026-10-30
     * @usedBy SalaryNoticeService.dismiss
     */
    public Instant dismiss(UUID owner, SalaryMonth month) {
        requireOwner(owner);
        int changed = entityManager.createNativeQuery("""
            INSERT INTO payse.salary_notice_dismissals (
              user_id,
              pay_month
            )
            VALUES (
              ?1,
              ?2
            )
            ON CONFLICT (user_id, pay_month) DO NOTHING
            """).setParameter(1, owner).setParameter(2, month.value()).executeUpdate();
        if (changed < 0 || changed > 1) throw new IllegalStateException("Unexpected salary notice write count");
        return find(owner, month).orElseThrow(() -> new IllegalStateException("Salary notice was not stored"));
    }

    /**
     * 기능 활성화 시 SQL 이행·강제 사용자 격리·최소 권한을 확인하고 미준비 서버는 시작하지 않는다.
     * @created 2026-10-30
     * @usedBy SalaryNoticeService 생성자
     */
    public void verifySchema() {
        Object valid = entityManager.createNativeQuery("""
            SELECT EXISTS (
              SELECT 1
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
              WHERE n.nspname = 'payse'
                AND c.relname = 'salary_notice_dismissals'
                AND c.relrowsecurity
                AND c.relforcerowsecurity
                AND has_table_privilege(current_user, c.oid, 'SELECT')
                AND has_column_privilege(current_user, c.oid, 'user_id', 'INSERT')
                AND has_column_privilege(current_user, c.oid, 'pay_month', 'INSERT')
                AND NOT has_column_privilege(current_user, c.oid, 'dismissed_at', 'INSERT')
                AND NOT has_any_column_privilege(current_user, c.oid, 'UPDATE')
                AND NOT has_table_privilege(current_user, c.oid, 'DELETE')
                AND NOT has_table_privilege(current_user, c.oid, 'TRUNCATE')
            )
            """).getSingleResult();
        if (!Boolean.TRUE.equals(valid)) throw new IllegalStateException("Salary notice migration and permissions are required");
    }

    /**
     * 다른 연결·읽기 전용 문맥·가짜 사용자 식별로 기록에 접근하지 못하게 한다.
     * @created 2026-10-30
     * @usedBy find, dismiss
     */
    private void requireOwner(UUID owner) {
        if (owner == null || !TransactionSynchronizationManager.isActualTransactionActive()
                || !(TransactionSynchronizationManager.getResource(factory) instanceof EntityManagerHolder holder)
                || TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(TransactionDefinition.ISOLATION_READ_COMMITTED).equals(
                    TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())
                || !entityManager.isJoinedToTransaction()) {
            throw new IllegalStateException("Salary notices require an authenticated transaction");
        }
        EntityManager current = entityManager instanceof EntityManagerProxy proxy
            ? proxy.getTargetEntityManager() : entityManager;
        if (current != holder.getEntityManager()) throw new IllegalStateException("Salary notice transaction differs");
        Object identity = entityManager.createNativeQuery("""
            SELECT CASE WHEN current_user = 'payse_runtime'
              THEN NULLIF(current_setting('payse.user_id', true), '')::uuid END
            """).getSingleResult();
        if (!owner.equals(identity)) throw new IllegalStateException("Salary notice owner differs");
    }
}

