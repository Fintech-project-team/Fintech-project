package com.payse.api.config;

import com.payse.api.finance.entity.AccountEntity;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import java.util.Map;
import javax.sql.DataSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.context.annotation.Profile;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.orm.jpa.LocalContainerEntityManagerFactoryBean;
import org.springframework.orm.jpa.SharedEntityManagerCreator;
import org.springframework.orm.jpa.vendor.HibernateJpaVendorAdapter;

/**
 * 명시한 DB에서만 JPA를 구성하고 기존 스키마·권한·트랜잭션 경계를 유지한다.
 * @created 2026-10-29
 * @usedBy Spring database 프로필, JpaTestContext
 */
@Configuration(proxyBeanMethods = false)
@Profile("database")
public class JpaConfiguration {
    /**
     * 검토한 엔티티만 등록한다. DDL·공유 캐시·SQL/바인딩 로그를 활성화하지 않는다.
     * @created 2026-10-29
     * @usedBy Spring, JpaTestContext
     */
    @Bean
    public LocalContainerEntityManagerFactoryBean entityManagerFactory(DataSource dataSource) {
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setPackagesToScan(AccountEntity.class.getPackageName());
        factory.setPersistenceUnitName("payse");
        factory.setJpaVendorAdapter(new HibernateJpaVendorAdapter());
        factory.setJpaPropertyMap(properties());
        return factory;
    }

    /**
     * 트랜잭션마다 실제 EntityManager가 분리되는 프록시를 제공한다.
     * @created 2026-10-29
     * @usedBy 인증·금융 Repository 생성자 주입
     */
    @Bean
    @Primary
    public EntityManager entityManager(EntityManagerFactory factory) {
        return SharedEntityManagerCreator.createSharedEntityManager(factory);
    }

    /**
     * JPA와 관측용 JDBC가 같은 연결을 사용하며 기존 격리 수준을 적용하도록 한다.
     * @created 2026-10-29
     * @usedBy AuthTransactions, JpaTestContext
     */
    @Bean
    public JpaTransactionManager transactionManager(EntityManagerFactory factory, DataSource dataSource) {
        var manager = new JpaTransactionManager(factory);
        manager.setDataSource(dataSource);
        manager.setNestedTransactionAllowed(false);
        return manager;
    }

    /**
     * SQL 원천 변경·공유 캐시 재사용을 막고 연결은 트랜잭션 종료까지 유지한다.
     * @created 2026-10-29
     * @usedBy entityManagerFactory
     */
    public Map<String, Object> properties() {
        return Map.ofEntries(
            Map.entry("hibernate.dialect", "org.hibernate.dialect.PostgreSQLDialect"),
            Map.entry("hibernate.boot.allow_jdbc_metadata_access", false),
            Map.entry("hibernate.hbm2ddl.auto", "none"),
            Map.entry("jakarta.persistence.schema-generation.database.action", "none"),
            Map.entry("jakarta.persistence.schema-generation.scripts.action", "none"),
            Map.entry("jakarta.persistence.sharedCache.mode", "NONE"),
            Map.entry("hibernate.cache.use_second_level_cache", false),
            Map.entry("hibernate.cache.use_query_cache", false),
            Map.entry("hibernate.connection.handling_mode", "DELAYED_ACQUISITION_AND_HOLD"),
            Map.entry("hibernate.show_sql", false),
            Map.entry("hibernate.format_sql", false),
            Map.entry("hibernate.use_sql_comments", false),
            Map.entry("hibernate.jdbc.time_zone", "UTC")
        );
    }
}
