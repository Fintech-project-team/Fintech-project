package com.payse.api.auth.mapper;

import com.payse.api.auth.error.AuthStoreException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.PersistenceException;
import java.util.function.Supplier;
import javax.sql.DataSource;
import org.springframework.context.annotation.Profile;
import org.springframework.dao.DataAccessException;
import org.springframework.orm.jpa.EntityManagerFactoryInfo;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.stereotype.Component;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionException;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 인증 DB 작업 한 묶음을 같은 연결에서 커밋/롤백한다. 사용자 상태는 필드에 저장하지 않는다.
 * @created 2026-10-25
 * @usedBy AuthService, FinancialService, AuthJdbcTest
 */
@Component
@Profile("database")
public final class AuthTransactions {
    private final EntityManager entityManager;
    private final EntityManagerFactory factory;
    private final DataSource dataSource;
    private final TransactionTemplate transaction;

    /**
     * 같은 EntityManagerFactory의 JPA 트랜잭션 관리자만 허용하고 명시된 격리 수준을 고정한다.
     * @created 2026-10-25
     * @usedBy Spring 생성자 주입, AuthJdbcTest, AuthRepositoryTest
     * @param entityManager 인증 Repository와 같은 factory의 공유 EntityManager
     * @param manager 해당 factory·DataSource를 관리하는 로컬 JPA 트랜잭션 관리자
     * @modified 2026-10-29 - JPA 트랜잭션의 역할·flush·커밋/롤백과 중첩 차단 유지
     */
    public AuthTransactions(EntityManager entityManager, PlatformTransactionManager manager) {
        if (entityManager == null || entityManager.getEntityManagerFactory() == null
                || !(manager instanceof JpaTransactionManager local)
                || local.getEntityManagerFactory() != entityManager.getEntityManagerFactory()
                || !(entityManager.getEntityManagerFactory() instanceof EntityManagerFactoryInfo info)
                || info.getDataSource() == null || local.getDataSource() != info.getDataSource()) {
            throw new IllegalArgumentException("Authentication storage must use one EntityManagerFactory and DataSource");
        }
        this.entityManager = entityManager;
        this.factory = entityManager.getEntityManagerFactory();
        this.dataSource = local.getDataSource();
        this.transaction = new TransactionTemplate(manager);
        this.transaction.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
        this.transaction.setReadOnly(false);
        this.transaction.setPropagationBehavior(TransactionDefinition.PROPAGATION_REQUIRED);
    }

    /**
     * 연결을 한 번 빌려 역할을 한정하고 콜백을 커밋한 뒤 결과를 반환한다. 중첩 호출은 거절한다.
     * IP 기록과 조합 처리는 이 메서드를 순서대로 두 번 호출한다. 실패 횟수는 정상 결과로 커밋한다.
     * @created 2026-10-25
     * @usedBy AuthService, FinancialService, AuthJdbcTest
     * @param work 외부 API·스레드 전환 없이 같은 연결에서 수행할 DB 작업
     * @return 커밋된 작업 결과; null 자체는 업무 성공을 의미하지 않음
     * @throws AuthStoreException DB 접근 또는 커밋/롤백 장애
     * @modified 2026-10-29 - JPA 트랜잭션의 역할·flush·커밋/롤백과 중첩 차단 유지
     */
    public <T> T run(Supplier<T> work) {
        if (work == null) throw new IllegalArgumentException("Authentication work is required");
        if (TransactionSynchronizationManager.isActualTransactionActive()
                || TransactionSynchronizationManager.isSynchronizationActive()
                || TransactionSynchronizationManager.hasResource(factory)
                || TransactionSynchronizationManager.hasResource(dataSource)) {
            throw new IllegalStateException("Authentication transactions cannot be nested");
        }
        try {
            return transaction.execute(status -> {
                // 역할은 트랜잭션에만 적용한다. 연결 풀에 세션 단위 역할을 남기지 않는다.
                Object resource = TransactionSynchronizationManager.getResource(factory);
                if (!(resource instanceof EntityManagerHolder holder)
                        || !entityManager.isJoinedToTransaction()
                        || entityManager.getDelegate() != holder.getEntityManager().getDelegate()) {
                    throw new AuthStoreException();
                }
                entityManager.createNativeQuery("SET LOCAL ROLE payse_runtime").executeUpdate();
                T result = work.get();
                // 다른 호출부가 SQL 오류를 삼켜도 aborted COMMIT을 성공 결과로 반환하지 않는다.
                entityManager.flush();
                entityManager.createNativeQuery("SELECT 1").getSingleResult();
                return result;
            });
        } catch (DataAccessException | TransactionException | PersistenceException failure) {
            throw new AuthStoreException();
        }
    }
}
