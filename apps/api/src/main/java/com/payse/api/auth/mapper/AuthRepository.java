package com.payse.api.auth.mapper;

import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.auth.vo.AuthCredentials;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.Query;
import jakarta.persistence.Tuple;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.function.Function;
import org.springframework.context.annotation.Profile;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * 인증 함수에 입력을 바인딩하고 내부 결과를 검증한다. 후보 조회만으로 인증을 승인하지 않는다.
 * @created 2026-10-25
 * @usedBy AuthService, AuthJdbcTest, SessionJdbcTest
 * @modified 2026-10-26 - 잠금 자격 조회와 세션 생성·종료 함수 연결
 */
@Repository
@Profile("database")
public class AuthRepository {
    private final EntityManager entityManager;
    private final EntityManagerFactory factory;

    /**
     * 트랜잭션과 같은 EntityManagerFactory의 공유 EntityManager를 주입한다.
     * @created 2026-10-25
     * @usedBy Spring 생성자 주입, AuthJdbcTest, AuthRepositoryTest
     * @param entityManager 사용자 입력을 native SQL 파라미터로 바인딩할 공유 EntityManager
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    public AuthRepository(EntityManager entityManager) {
        if (entityManager == null || entityManager.getEntityManagerFactory() == null) {
            throw new IllegalArgumentException("Authentication EntityManagerFactory is required");
        }
        this.entityManager = entityManager;
        this.factory = entityManager.getEntityManagerFactory();
    }

    /**
     * 허용·거절과 관계없이 IP 요청 한 건을 기록한다. 상위 계층이 다음 처리 전에 커밋한다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 인증 요청 IP 필터
     * @param key 서버 AuthCrypto가 만든 IP HMAC; 원문 IP가 아님
     * @return 허용 여부와 DB가 정한 재시도 시각
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public AuthRows.IpLimit recordIp(String key) {
        // 요청 이력을 갱신하는 함수다. 단순 읽기 전용 SELECT로 취급하지 않는다.
        return one(query("SELECT allowed,retry_at FROM payse.auth_ip_request(?1)", row -> {
            Boolean allowed = row.get("allowed", Boolean.class);
            Instant retryAt = instant(row, "retry_at");
            if (allowed == null || allowed == (retryAt != null)) throw new AuthStoreException();
            return new AuthRows.IpLimit(allowed, retryAt);
        }, key));
    }

    /**
     * 조합 행을 잠그고 만료 이력을 정리한 뒤 차단 종료 시각을 읽는다. null은 인증 성공이 아니다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 인증 application service
     * @param key 정규화된 이름·전화번호의 서버 HMAC
     * @return 차단 시각 또는 미차단이면 null
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    public Instant retryAt(String key) {
        return one(query("SELECT payse.auth_limit(?1) AS retry_at", row -> instant(row, "retry_at"), key));
    }

    /**
     * 잘못된 자격 대조 한 번을 기록한다. 반환값을 커밋한 뒤 상위 계층이 인증 오류로 매핑한다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 인증 application service
     * @param key 정규화된 조합의 서버 HMAC
     * @return 5번째 실패/기존 차단의 종료 시각 또는 미차단이면 null
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    public Instant recordFailure(String key) {
        return one(query("SELECT payse.auth_failure(?1) AS retry_at", row -> instant(row, "retry_at"), key));
    }

    /**
     * 정규화한 조합의 내부 코드 대조 자료를 읽는다. 비활성 계정·DISABLED verifier도 후보일 수 있다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 AuthCrypto.verifyCode 호출부
     * @param name 기존 이름 계약으로 검증할 입력
     * @param phone 기존 전화번호 계약으로 검증할 입력
     * @return 단일 후보 또는 등록 조합이 없으면 empty; 세션 생성/사용자 문맥 설정 없음
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public Optional<AuthRows.StoredCode> findCode(String name, String phone) {
        String normalizedName = AuthCredentials.normalizeName(name);
        String normalizedPhone = AuthCredentials.normalizePhone(phone);
        return optional(query("SELECT user_id,code_verifier FROM payse.auth_credentials(?1,?2)", row -> {
            UUID userId = row.get("user_id", UUID.class);
            String verifier = row.get("code_verifier", String.class);
            if (userId == null || verifier == null) throw new AuthStoreException();
            return new AuthRows.StoredCode(userId, verifier);
        }, normalizedName, normalizedPhone));
    }

    /**
     * 토큰 검증값으로 사용자·세션을 잠금 뒤 재확인한다. 후속 소유자 조회도 같은 트랜잭션에서 수행한다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest, 미연결: 예정 금융 조회 application service
     * @param tokenDigest 서버가 만든 토큰 digest; null/무효 형식도 DB에서 이전 문맥을 비운 뒤 거절
     * @return 현재 유효 소유자 또는 empty; 반환 UUID만으로 다른 요청을 인증할 수 없음
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public Optional<AuthRows.Session> authorize(String tokenDigest) {
        // 무효 입력도 함수에 바인딩하여 이전 사용자 문맥을 지우는 DB 절차를 반드시 거친다.
        return optional(query("SELECT user_id,session_id FROM payse.auth_authorize(?1)", row -> {
            UUID userId = row.get("user_id", UUID.class);
            UUID sessionId = row.get("session_id", UUID.class);
            if (userId == null || sessionId == null) throw new AuthStoreException();
            return new AuthRows.Session(userId, sessionId);
        }, tokenDigest));
    }

    /**
     * 로그인 조합의 사용자 행을 잠근 뒤 현재 코드·저장 이름을 읽는다. 비활성도 코드 비교 대상으로 유지한다.
     * @created 2026-10-26
     * @usedBy AuthService.signIn
     * @return 잠긴 현재 사용자 또는 후보 없음; 인증 성공 결과가 아님
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public Optional<AuthRows.LoginAccount> lockCode(String name, String phone) {
        return optional(query("SELECT user_id,name,code_verifier FROM payse.auth_login_account(?1,?2)", row -> {
            UUID userId = row.get("user_id", UUID.class);
            String storedName = row.get("name", String.class);
            String verifier = row.get("code_verifier", String.class);
            if (userId == null || storedName == null || verifier == null
                    || !storedName.equals(AuthCredentials.normalizeName(storedName))) throw new AuthStoreException();
            return new AuthRows.LoginAccount(userId, storedName, verifier);
        }, AuthCredentials.normalizeName(name), AuthCredentials.normalizePhone(phone)));
    }

    /**
     * 코드 대조가 끝난 사용자에만 활성 상태를 재검사하고 세션을 저장한다. 호출자는 사용자 잠금을 유지한다.
     * @created 2026-10-26
     * @usedBy AuthService.signIn
     * @param userId 서버에서 잠금·코드 대조를 마친 사용자
     * @param tokenDigest 새 토큰의 저장용 검증값; 원문 아님
     * @return 저장된 세션 또는 기존 세션/비활성으로 인한 거절
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     * @modified 2026-10-29 - 분리한 DTO·VO를 사용하고 기존 처리·응답 계약 유지
     */
    public Optional<AuthRows.OpenedSession> openSession(UUID userId, String tokenDigest) {
        return optional(query("SELECT user_id,session_id,name,issued_at FROM payse.auth_open_session(?1,?2)", row -> {
            UUID owner = row.get("user_id", UUID.class);
            UUID sessionId = row.get("session_id", UUID.class);
            String name = row.get("name", String.class);
            Instant issuedAt = instant(row, "issued_at");
            if (owner == null || !owner.equals(userId) || sessionId == null || issuedAt == null || name == null
                    || !name.equals(AuthCredentials.normalizeName(name))) throw new AuthStoreException();
            return new AuthRows.OpenedSession(owner, sessionId, name, issuedAt);
        }, userId, tokenDigest));
    }

    /**
     * 현재 토큰 소유자의 세션만 종료하고 RLS 문맥을 비운다. false는 이미 종료됐거나 무효라는 뜻이다.
     * @created 2026-10-26
     * @usedBy AuthService.logout
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    public boolean endSession(String tokenDigest) {
        return one(query("SELECT payse.auth_end_session(?1) AS ended", row -> {
            Boolean ended = row.get("ended", Boolean.class);
            if (ended == null) throw new AuthStoreException();
            return ended;
        }, tokenDigest));
    }

    /**
     * 동일 EntityManager의 명시된 읽기/쓰기 트랜잭션만 사용하고 DB 오류 세부를 외부로 전달하지 않는다.
     * @created 2026-10-25
     * @usedBy AuthRepository.recordIp, retryAt, recordFailure, findCode, authorize
     * @param sql 코드에 고정된 함수 호출문
     * @param mapper 단일 행의 내부 값 해석
     * @param values 별도 바인딩할 입력
     * @return 모든 결과 행; 건수 검증을 위해 임의 첫 행을 택하지 않음
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    private <T> List<T> query(String sql, Function<Tuple, T> mapper, Object... values) {
        requireTransaction();
        try {
            Query query = entityManager.createNativeQuery(sql, Tuple.class);
            for (int index = 0; index < values.length; index++) query.setParameter(index + 1, values[index]);
            List<?> rows = query.getResultList();
            return rows.stream().map(Tuple.class::cast).map(mapper).toList();
        } catch (RuntimeException failure) {
            // 호출자가 장애를 잡아도 이후 커밋이 성공으로 끝나지 않게 전체 트랜잭션을 표시한다.
            rollbackOnly();
            throw new AuthStoreException();
        }
    }

    /**
     * autocommit·다른 EntityManager·read-only·다른 격리 수준에서는 SQL 전에 실패한다.
     * @created 2026-10-25
     * @usedBy AuthRepository.query
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    private void requireTransaction() {
        Integer isolation = TransactionSynchronizationManager.getCurrentTransactionIsolationLevel();
        Object resource = TransactionSynchronizationManager.getResource(factory);
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || !(resource instanceof EntityManagerHolder holder)
                || TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(TransactionDefinition.ISOLATION_READ_COMMITTED).equals(isolation)
                || !entityManager.isJoinedToTransaction()
                || entityManager.getDelegate() != holder.getEntityManager().getDelegate()) {
            throw new IllegalStateException("Authentication storage requires a read/write READ COMMITTED transaction");
        }
    }

    /**
     * 저장 오류를 정상 반환으로 삼켜도 현재 트랜잭션을 커밋하지 못하게 한다.
     * @created 2026-10-25
     * @usedBy AuthRepository.query, one, optional
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    private void rollbackOnly() {
        Object resource = TransactionSynchronizationManager.getResource(factory);
        if (resource instanceof EntityManagerHolder holder) {
            var transaction = holder.getEntityManager().getTransaction();
            if (transaction.isActive()) transaction.setRollbackOnly();
        }
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
     * @modified 2026-10-29 - 동일 JPA 트랜잭션의 native SQL·결과 매핑과 롤백 보존
     */
    private static Instant instant(Tuple row, String column) {
        Object value = row.get(column);
        if (value == null) return null;
        if (value instanceof Instant instant) return instant;
        if (value instanceof OffsetDateTime time) return time.toInstant();
        if (value instanceof Timestamp time) return time.toInstant();
        throw new AuthStoreException();
    }

}
