package com.payse.api.auth;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import javax.sql.DataSource;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.datasource.ConnectionHolder;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 기존 인증 함수 5개만 바인딩 호출한다. 자격 후보 조회는 로그인 성공이나 세션 발급이 아니다.
 * @created 2026-10-25
 * @usedBy AuthJdbcTest, 미연결: 예정 인증 application service
 */
@Repository
@Profile("database")
public class AuthRepository {
    private final JdbcTemplate jdbc;
    private final DataSource dataSource;

    /**
     * 트랜잭션과 같은 DataSource를 사용하는 JDBC를 주입한다.
     * @created 2026-10-25
     * @usedBy Spring 생성자 주입, AuthJdbcTest, AuthRepositoryTest
     * @param jdbc 사용자 입력을 SQL 파라미터로 바인딩할 JDBC
     */
    public AuthRepository(JdbcTemplate jdbc) {
        if (jdbc == null || jdbc.getDataSource() == null) {
            throw new IllegalArgumentException("Authentication DataSource is required");
        }
        this.jdbc = jdbc;
        this.dataSource = jdbc.getDataSource();
    }

    /**
     * 허용·거절과 관계없이 IP 요청 한 건을 기록한다. 상위 계층이 다음 처리 전에 커밋한다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 인증 요청 IP 필터
     * @param key 서버 AuthCrypto가 만든 IP HMAC; 원문 IP가 아님
     * @return 허용 여부와 DB가 정한 재시도 시각
     */
    public IpLimit recordIp(String key) {
        // 요청 이력을 갱신하는 함수다. 단순 읽기 전용 SELECT로 취급하지 않는다.
        return one(query("SELECT allowed,retry_at FROM payse.auth_ip_request(?)", (row, index) -> {
            Boolean allowed = row.getObject("allowed", Boolean.class);
            Instant retryAt = instant(row, "retry_at");
            if (allowed == null || allowed == (retryAt != null)) throw new AuthStoreException();
            return new IpLimit(allowed, retryAt);
        }, key));
    }

    /**
     * 조합 행을 잠그고 만료 이력을 정리한 뒤 차단 종료 시각을 읽는다. null은 인증 성공이 아니다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 인증 application service
     * @param key 정규화된 이름·전화번호의 서버 HMAC
     * @return 차단 시각 또는 미차단이면 null
     */
    public Instant retryAt(String key) {
        return one(query("SELECT payse.auth_limit(?) AS retry_at", (row, index) -> instant(row, "retry_at"), key));
    }

    /**
     * 잘못된 자격 대조 한 번을 기록한다. 반환값을 커밋한 뒤 상위 계층이 인증 오류로 매핑한다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 인증 application service
     * @param key 정규화된 조합의 서버 HMAC
     * @return 5번째 실패/기존 차단의 종료 시각 또는 미차단이면 null
     */
    public Instant recordFailure(String key) {
        return one(query("SELECT payse.auth_failure(?) AS retry_at", (row, index) -> instant(row, "retry_at"), key));
    }

    /**
     * 정규화한 조합의 내부 코드 대조 자료를 읽는다. 비활성 계정·DISABLED verifier도 후보일 수 있다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 AuthCrypto.verifyCode 호출부
     * @param name 기존 이름 계약으로 검증할 입력
     * @param phone 기존 전화번호 계약으로 검증할 입력
     * @return 단일 후보 또는 등록 조합이 없으면 empty; 세션 생성/사용자 문맥 설정 없음
     */
    public Optional<StoredCode> findCode(String name, String phone) {
        String normalizedName = AuthCredentials.normalizeName(name);
        String normalizedPhone = AuthCredentials.normalizePhone(phone);
        return optional(query("SELECT user_id,code_verifier FROM payse.auth_credentials(?,?)", (row, index) -> {
            UUID userId = row.getObject("user_id", UUID.class);
            String verifier = row.getString("code_verifier");
            if (userId == null || verifier == null) throw new AuthStoreException();
            return new StoredCode(userId, verifier);
        }, normalizedName, normalizedPhone));
    }

    /**
     * 토큰 검증값으로 사용자·세션을 잠금 뒤 재확인한다. 후속 소유자 조회도 같은 트랜잭션에서 수행한다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 금융 조회 application service
     * @param tokenDigest 서버가 만든 토큰 digest; null/무효 형식도 DB에서 이전 문맥을 비운 뒤 거절
     * @return 현재 유효 소유자 또는 empty; 반환 UUID만으로 다른 요청을 인증할 수 없음
     */
    public Optional<Session> authorize(String tokenDigest) {
        // 무효 입력도 함수에 바인딩하여 이전 사용자 문맥을 지우는 DB 절차를 반드시 거친다.
        return optional(query("SELECT user_id,session_id FROM payse.auth_authorize(?)", (row, index) -> {
            UUID userId = row.getObject("user_id", UUID.class);
            UUID sessionId = row.getObject("session_id", UUID.class);
            if (userId == null || sessionId == null) throw new AuthStoreException();
            return new Session(userId, sessionId);
        }, tokenDigest));
    }

    /**
     * 동일 DataSource의 명시된 읽기/쓰기 트랜잭션만 사용하고 DB 오류 세부를 외부로 전달하지 않는다.
     * @created 2026-10-25
     * @usedBy AuthRepository.recordIp, retryAt, recordFailure, findCode, authorize
     * @param sql 코드에 고정된 함수 호출문
     * @param mapper 단일 행의 내부 값 해석
     * @param values 별도 바인딩할 입력
     * @return 모든 결과 행; 건수 검증을 위해 임의 첫 행을 택하지 않음
     */
    private <T> List<T> query(String sql, RowMapper<T> mapper, Object... values) {
        requireTransaction();
        try {
            return jdbc.query(sql, mapper, values);
        } catch (RuntimeException failure) {
            // 호출자가 장애를 잡아도 이후 커밋이 성공으로 끝나지 않게 전체 트랜잭션을 표시한다.
            rollbackOnly();
            throw new AuthStoreException();
        }
    }

    /**
     * autocommit·다른 DataSource·read-only·다른 격리 수준에서는 SQL 전에 실패한다.
     * @created 2026-10-25
     * @usedBy AuthRepository.query
     */
    private void requireTransaction() {
        Integer isolation = TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !TransactionSynchronizationManager.hasResource(dataSource)
                || TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(TransactionDefinition.ISOLATION_READ_COMMITTED).equals(isolation)) {
            throw new IllegalStateException("Authentication storage requires a read/write READ COMMITTED transaction");
        }
    }

    /**
     * 저장 오류를 정상 반환으로 삼켜도 현재 트랜잭션을 커밋하지 못하게 한다.
     * @created 2026-10-25
     * @usedBy AuthRepository.query, one, optional
     */
    private void rollbackOnly() {
        Object resource = TransactionSynchronizationManager.getResource(dataSource);
        if (resource instanceof ConnectionHolder connection) connection.setRollbackOnly();
    }

    /**
     * 정확히 한 행인 함수만 해석하며 scalar의 정상 null은 유지한다.
     * @created 2026-10-25
     * @usedBy AuthRepository.recordIp, retryAt, recordFailure
     * @param rows 함수 조회 결과
     * @return 유일한 행의 값
     */
    private <T> T one(List<T> rows) {
        if (rows.size() != 1) {
            rollbackOnly();
            throw new AuthStoreException();
        }
        return rows.getFirst();
    }

    /**
     * 0~1행 계약을 검사하고 중복 후보는 저장 장애로 거절한다.
     * @created 2026-10-25
     * @usedBy AuthRepository.findCode, authorize
     * @param rows 함수 조회 결과
     * @return 정상 부재 또는 유일한 내부 후보
     */
    private <T> Optional<T> optional(List<T> rows) {
        if (rows.size() > 1 || (rows.size() == 1 && rows.getFirst() == null)) {
            rollbackOnly();
            throw new AuthStoreException();
        }
        return rows.isEmpty() ? Optional.empty() : Optional.of(rows.getFirst());
    }

    /**
     * PostgreSQL timestamptz를 절대 시각으로 옮기고 정상 SQL null은 보존한다.
     * @created 2026-10-25
     * @usedBy AuthRepository.recordIp, retryAt, recordFailure
     * @param row 현재 결과 행
     * @param column 코드에 고정된 시각 열
     * @return 절대 시각 또는 null
     */
    private static Instant instant(ResultSet row, String column) throws SQLException {
        OffsetDateTime value = row.getObject(column, OffsetDateTime.class);
        return value == null ? null : value.toInstant();
    }

    /**
     * IP 요청 저장 결과다. allowed=false이면 retryAt이 있으며 외부 응답 DTO로 사용하지 않는다.
     * @created 2026-10-25
     * @usedBy AuthRepository.recordIp, AuthJdbcTest
     */
    public record IpLimit(boolean allowed, Instant retryAt) {}

    /**
     * 서버 내부 코드 비교용 후보다. 계정 활성/세션 판정이나 인증 성공 결과가 아니다.
     * @created 2026-10-25
     * @usedBy AuthRepository.findCode, AuthJdbcTest
     */
    public record StoredCode(UUID userId, String verifier) {
        /**
         * verifier·사용자 식별자가 자동 문자열 표현으로 로그에 남지 않게 한다.
         * @created 2026-10-25
         * @usedBy Java 문자열 표현, AuthRepositoryTest
         * @return 원문 없는 고정 문자열
         */
        @Override
        public String toString() { return "StoredCode[redacted]"; }
    }

    /**
     * 현재 트랜잭션에서 확인된 소유자다. 토큰 원문을 보관하지 않는다.
     * @created 2026-10-25
     * @usedBy AuthRepository.authorize, AuthJdbcTest
     */
    public record Session(UUID userId, UUID sessionId) {}
}
