package com.payse.api.finance;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.LocalDate;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import javax.sql.DataSource;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.ConnectionHolder;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 인증한 사용자와 연결 기관의 거래·원거래를 같은 JDBC 트랜잭션에서 읽는다.
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
            WHERE tx.user_id = ?
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
        WHERE current.id = ?
        """;

    private final JdbcTemplate jdbc;
    private final DataSource dataSource;

    /**
     * 기존 인증 트랜잭션과 같은 DataSource의 JDBC를 받는다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입, AuthJdbcTest
     * @param jdbc 인증 문맥과 RLS를 공유할 JDBC
     */
    public TransactionRepository(JdbcTemplate jdbc) {
        if (jdbc == null || jdbc.getDataSource() == null) {
            throw new IllegalArgumentException("Transaction DataSource is required");
        }
        this.jdbc = jdbc;
        this.dataSource = jdbc.getDataSource();
    }

    /**
     * 인증 함수가 설정한 사용자 문맥으로 거래를 찾아 원거래를 LEFT JOIN한다.
     * 원거래 미확보·미연결은 현재 행을 제거하지 않는다. 미확보 ID의 공개 권한은
     * 이 조회만으로 확정하지 않으며 공개 응답 조립부가 원천 관계 근거를 검증해야 한다.
     * @created 2026-10-29
     * @usedBy AuthJdbcTest, 미연결: 금융 조회 응답 조립부
     * @param transactionId 요청에서 UUID 형식을 검증한 거래 ID
     * @return 연결 기관의 소유 거래; 없거나 다른 소유자/미연결 기관이면 empty
     */
    public Optional<TransactionLink> findLink(UUID transactionId) {
        if (transactionId == null) throw new IllegalArgumentException("Transaction ID is required");
        requireTransaction();
        try {
            UUID owner = owner();
            List<TransactionLink> rows = jdbc.query(LINK_SQL, (row, index) -> mapLink(row), owner, transactionId);
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
     */
    private void requireTransaction() {
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.hasResource(dataSource)
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
     */
    private UUID owner() {
        UUID userId = jdbc.queryForObject("""
            SELECT CASE WHEN current_user = 'payse_runtime'
                        THEN NULLIF(current_setting('payse.user_id', true), '')::uuid
                   END
            """, UUID.class);
        if (userId == null) throw new IllegalStateException("Transaction read requires an authorized user context");
        return userId;
    }

    /**
     * 조회 결과를 내부 객체로 옮기며 원거래 유무·권한과 실제 미상을 구분한다.
     * @created 2026-10-29
     * @usedBy TransactionRepository.findLink
     * @param row 소유권·기관 연결을 검사한 단일 조회 행
     * @return 공개 직렬화를 금지한 원거래 연결 자료
     * @throws SQLException JDBC 읽기에 실패한 경우
     */
    private TransactionLink mapLink(ResultSet row) throws SQLException {
        UUID originalId = row.getObject("original_id", UUID.class);
        Original original = originalId == null ? null : new Original(originalId,
            row.getObject("original_card_id", UUID.class), row.getString("original_kind"),
            row.getObject("original_purchase_date", LocalDate.class),
            row.getLong("original_amount_krw"), row.getString("original_source_version"));
        return new TransactionLink(row.getObject("id", UUID.class),
            row.getObject("cancellation_date", LocalDate.class),
            row.getObject("original_transaction_id", UUID.class),
            OriginalState.valueOf(row.getString("original_state")), original);
    }

    /**
     * 호출자가 실패를 잡더라도 부분 작업이 커밋되지 않게 같은 연결을 롤백 대상으로 만든다.
     * @created 2026-10-29
     * @usedBy TransactionRepository.findLink
     */
    private void rollbackOnly() {
        Object resource = TransactionSynchronizationManager.getResource(dataSource);
        if (resource instanceof ConnectionHolder connection) connection.setRollbackOnly();
    }

    /**
     * 원거래 참조 없음·공개 가능한 확보 자료·미확보·기관 미연결을 분리한다.
     * @created 2026-10-29
     * @usedBy TransactionLink, TransactionRepository.mapLink
     */
    public enum OriginalState { ABSENT, AVAILABLE, UNAVAILABLE, RESTRICTED }

    /**
     * 현재 거래·취소일과 원거래 연결을 보관한다. 원거래 ID는 내부 자료이며,
     * UNAVAILABLE/RESTRICTED를 공개 응답에 그대로 내보내지 않는다.
     * @created 2026-10-29
     * @usedBy TransactionRepository.findLink, AuthJdbcTest
     */
    public record TransactionLink(UUID id, LocalDate cancellationDate, UUID originalTransactionId,
            OriginalState originalState, Original original) {
        /**
         * 자동 로그·검사 출력에 금융 식별자와 날짜가 남지 않게 한다.
         * @created 2026-10-29
         * @usedBy 내부 객체 문자열 표현
         * @return 금융 원문을 포함하지 않는 고정 설명
         */
        @Override public String toString() { return "TransactionLink[REDACTED]"; }
    }

    /**
     * 원거래 상세 표시에 필요한 최소 원천만 보관하며 잔액·금액을 계산하지 않는다.
     * @created 2026-10-29
     * @usedBy TransactionLink, TransactionRepository.mapLink, AuthJdbcTest
     */
    public record Original(UUID id, UUID cardId, String recordKind, LocalDate purchaseDate,
            long amountKRW, String sourceVersion) {
        /**
         * 자동 로그·검사 출력에 원거래 금액과 식별자가 남지 않게 한다.
         * @created 2026-10-29
         * @usedBy 내부 객체 문자열 표현
         * @return 금융 원문을 포함하지 않는 고정 설명
         */
        @Override public String toString() { return "Original[REDACTED]"; }
    }
}
