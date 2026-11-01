package com.payse.api.finance.mapper;

import com.payse.api.finance.error.TransactionStoreException;
import com.payse.api.finance.vo.OriginalState;
import com.payse.api.finance.vo.OriginalTransaction;
import com.payse.api.finance.vo.TransactionLink;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.Query;
import jakarta.persistence.Tuple;
import java.sql.Date;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 인증한 사용자와 연결 기관의 거래·원거래를 같은 JPA 트랜잭션에서 읽는다.
 * 내부 저장소 자료이며 공개 응답으로 직접 직렬화하지 않는다.
 * @created 2026-10-29
 * @usedBy AuthJdbcTest, 미연결: 금융 조회 응답 조립부
 */
@Repository
@Profile("database")
public class TransactionRepository {
    private static final String LINK_SQL = """
        WITH owned AS NOT MATERIALIZED (
            SELECT tx.id, tx.user_id, tx.card_id, tx.record_kind, tx.purchase_date,
                   tx.cancellation_date, tx.amount_krw, tx.source_version,
                   tx.original_transaction_id,
                   CASE WHEN tx.record_kind = 'account_entry'
                        THEN account.institution_code
                        ELSE card.institution_code
                   END AS institution_code
            FROM payse.financial_transactions tx
            LEFT JOIN payse.financial_accounts account
                ON account.user_id = tx.user_id AND account.id = tx.account_id
            LEFT JOIN payse.financial_cards card
                ON card.user_id = tx.user_id AND card.id = tx.card_id
            WHERE tx.user_id = ?1
        )
        SELECT current.id, current.cancellation_date, current.original_transaction_id,
               CASE WHEN current.original_transaction_id IS NULL THEN 'ABSENT'
                    WHEN original.id IS NULL THEN 'UNAVAILABLE'
                    WHEN original_link.id IS NULL THEN 'RESTRICTED'
                    ELSE 'AVAILABLE'
               END AS original_state,
               CASE WHEN original_link.id IS NOT NULL THEN original.id END AS original_id,
               CASE WHEN original_link.id IS NOT NULL THEN original.card_id END AS original_card_id,
               CASE WHEN original_link.id IS NOT NULL THEN original.record_kind END AS original_kind,
               CASE WHEN original_link.id IS NOT NULL THEN original.purchase_date END AS original_purchase_date,
               CASE WHEN original_link.id IS NOT NULL THEN original.amount_krw END AS original_amount_krw,
               CASE WHEN original_link.id IS NOT NULL THEN original.source_version END AS original_source_version
        FROM owned current
        JOIN payse.institution_links current_link
            ON current_link.user_id = current.user_id
           AND current_link.institution_code = current.institution_code
           AND current_link.disconnected_at IS NULL
        LEFT JOIN owned original
            ON original.user_id = current.user_id
           AND original.id = current.original_transaction_id
        LEFT JOIN payse.institution_links original_link
            ON original_link.user_id = original.user_id
           AND original_link.institution_code = original.institution_code
           AND original_link.disconnected_at IS NULL
        WHERE current.id = ?2
        """;

    private final EntityManager entityManager;
    private final EntityManagerFactory factory;

    /**
     * 기존 인증 트랜잭션과 같은 factory의 공유 EntityManager를 받는다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입, AuthJdbcTest
     * @param entityManager 인증 문맥과 RLS를 공유할 EntityManager
     * @modified 2026-10-29 - 동일 JPA 트랜잭션에서 기존 원거래 SQL·권한·롤백 보존
     */
    public TransactionRepository(EntityManager entityManager) {
        if (entityManager == null || entityManager.getEntityManagerFactory() == null) {
            throw new IllegalArgumentException("Transaction EntityManagerFactory is required");
        }
        this.entityManager = entityManager;
        this.factory = entityManager.getEntityManagerFactory();
    }

    /**
     * 인증 함수가 설정한 사용자 문맥으로 거래를 찾아 원거래를 LEFT JOIN한다.
     * 원거래 미확보·미연결은 현재 행을 제거하지 않는다. 미확보 ID의 공개 권한은
     * 이 조회만으로 확정하지 않으며 공개 응답 조립부가 원천 관계 근거를 검증해야 한다.
     * @created 2026-10-29
     * @usedBy AuthJdbcTest, 미연결: 금융 조회 응답 조립부
     * @param transactionId 요청에서 UUID 형식을 검증한 거래 ID
     * @return 연결 기관의 소유 거래; 없거나 다른 소유자/미연결 기관이면 empty
     * @modified 2026-10-29 - 동일 JPA 트랜잭션에서 기존 원거래 SQL·권한·롤백 보존
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public Optional<TransactionLink> findLink(UUID transactionId) {
        if (transactionId == null) throw new IllegalArgumentException("Transaction ID is required");
        requireTransaction();
        try {
            UUID owner = owner();
            Query query = entityManager.createNativeQuery(LINK_SQL, Tuple.class)
                .setParameter(1, owner).setParameter(2, transactionId);
            List<?> values = query.getResultList();
            List<TransactionLink> rows = values.stream().map(Tuple.class::cast).map(this::mapLink).toList();
            if (rows.size() > 1) throw new TransactionStoreException();
            return rows.stream().findFirst();
        } catch (IllegalStateException failure) {
            rollbackOnly();
            throw failure;
        } catch (RuntimeException failure) {
            rollbackOnly();
            throw new TransactionStoreException();
        }
    }

    /**
     * 인증과 별도 연결·자동 커밋·읽기 전용으로 원천을 조회하지 못하게 한다.
     * @created 2026-10-29
     * @usedBy TransactionRepository.findLink
     * @modified 2026-10-29 - 동일 JPA 트랜잭션에서 기존 원거래 SQL·권한·롤백 보존
     */
    private void requireTransaction() {
        Object resource = TransactionSynchronizationManager.getResource(factory);
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !(resource instanceof EntityManagerHolder holder)
                || !entityManager.isJoinedToTransaction()
                || entityManager.getDelegate() != holder.getEntityManager().getDelegate()
                || TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(TransactionDefinition.ISOLATION_READ_COMMITTED).equals(
                    TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())) {
            throw new IllegalStateException("Transaction read requires the authenticated READ COMMITTED transaction");
        }
    }

    /**
     * AuthRepository.authorize가 같은 트랜잭션에 설정한 사용자와 runtime 역할을 요구한다.
     * @created 2026-10-29
     * @usedBy TransactionRepository.findLink
     * @return 요청 본문이 아닌 인증 DB 문맥의 소유자
     * @modified 2026-10-29 - 동일 JPA 트랜잭션에서 기존 원거래 SQL·권한·롤백 보존
     */
    private UUID owner() {
        UUID userId = (UUID) entityManager.createNativeQuery("""
            SELECT CASE WHEN current_user = 'payse_runtime'
                        THEN NULLIF(current_setting('payse.user_id', true), '')::uuid
                   END
            """, UUID.class).getSingleResult();
        if (userId == null) throw new IllegalStateException("Transaction read requires an authorized user context");
        return userId;
    }

    /**
     * 조회 결과를 내부 객체로 옮기며 원거래 유무·권한과 실제 미상을 구분한다.
     * @created 2026-10-29
     * @usedBy TransactionRepository.findLink
     * @param row 소유권·기관 연결을 검사한 단일 조회 행
     * @return 공개 직렬화를 금지한 원거래 연결 자료
     * @modified 2026-10-29 - 동일 JPA 트랜잭션에서 기존 원거래 SQL·권한·롤백 보존
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    private TransactionLink mapLink(Tuple row) {
        UUID originalId = row.get("original_id", UUID.class);
        Number amount = row.get("original_amount_krw", Number.class);
        OriginalTransaction original = originalId == null ? null : new OriginalTransaction(originalId,
            row.get("original_card_id", UUID.class), row.get("original_kind", String.class),
            date(row, "original_purchase_date"),
            amount.longValue(), row.get("original_source_version", String.class));
        return new TransactionLink(row.get("id", UUID.class),
            date(row, "cancellation_date"), row.get("original_transaction_id", UUID.class),
            OriginalState.valueOf(row.get("original_state", String.class)), original);
    }

    /**
     * 원천 DATE만 날짜로 옮기며 시각·추정 일자를 만들지 않는다.
     * @created 2026-10-29
     * @usedBy mapLink
     */
    private LocalDate date(Tuple row, String field) {
        Object value = row.get(field);
        if (value == null) return null;
        if (value instanceof LocalDate day) return day;
        if (value instanceof Date day) return day.toLocalDate();
        throw new TransactionStoreException();
    }

    /**
     * 호출자가 실패를 잡더라도 부분 작업이 커밋되지 않게 같은 연결을 롤백 대상으로 만든다.
     * @created 2026-10-29
     * @usedBy TransactionRepository.findLink
     * @modified 2026-10-29 - 동일 JPA 트랜잭션에서 기존 원거래 SQL·권한·롤백 보존
     */
    private void rollbackOnly() {
        Object resource = TransactionSynchronizationManager.getResource(factory);
        if (resource instanceof EntityManagerHolder holder) {
            var transaction = holder.getEntityManager().getTransaction();
            if (transaction.isActive()) transaction.setRollbackOnly();
        }
    }

}
