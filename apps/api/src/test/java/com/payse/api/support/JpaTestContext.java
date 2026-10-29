package com.payse.api.support;

import com.payse.api.config.JpaConfiguration;
import jakarta.persistence.EntityManager;
import javax.sql.DataSource;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;

/**
 * 실제 PostgreSQL 검사에서 운영과 같은 JPA 구성만 준비하고 소유한 factory를 종료한다.
 * @created 2026-10-29
 * @usedBy AuthJdbcTest, SessionJdbcTest, JpaConfigurationTest
 */
public final class JpaTestContext implements AutoCloseable {
    private final LocalContainerEntityManagerFactoryBean factory;
    private final EntityManager entityManager;
    private final JpaTransactionManager manager;

    /**
     * 호출자가 준비한 폐기용 DataSource를 사용한다. 스키마·시드·역할은 생성하지 않는다.
     * @created 2026-10-29
     * @usedBy 실제 DB 테스트 준비
     */
    public JpaTestContext(DataSource dataSource) {
        var configuration = new JpaConfiguration();
        factory = configuration.entityManagerFactory(dataSource);
        factory.afterPropertiesSet();
        entityManager = configuration.entityManager(factory.getObject());
        manager = configuration.transactionManager(factory.getObject(), dataSource);
        manager.afterPropertiesSet();
    }

    /**
     * 현재 트랜잭션의 EntityManager를 가리키는 프록시를 제공한다.
     * @created 2026-10-29
     * @usedBy AuthRepository, AuthTransactions, TransactionRepository 테스트 구성
     */
    public EntityManager entityManager() { return entityManager; }

    /**
     * 운영과 같은 JPA 트랜잭션 관리자를 제공한다.
     * @created 2026-10-29
     * @usedBy AuthTransactions 테스트 구성
     */
    public JpaTransactionManager manager() { return manager; }

    /**
     * 이 helper가 만든 factory만 닫고 호출자가 소유한 DataSource는 유지한다.
     * @created 2026-10-29
     * @usedBy 테스트 종료 및 try-with-resources
     */
    @Override
    public void close() { factory.destroy(); }
}
