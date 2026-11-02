package com.payse.api.config;

import com.payse.api.constants.ApiConfigConstants.Server;
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
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    @Bean
    public LocalContainerEntityManagerFactoryBean entityManagerFactory(DataSource dataSource) {
        var factory = new LocalContainerEntityManagerFactoryBean();
        factory.setDataSource(dataSource);
        factory.setPackagesToScan(AccountEntity.class.getPackageName());
        factory.setPersistenceUnitName(Server.PAYSE);
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
    public JpaTransactionManager transactionManager(
        EntityManagerFactory factory,
        DataSource dataSource
    ) {
        var manager = new JpaTransactionManager(factory);
        manager.setDataSource(dataSource);
        manager.setNestedTransactionAllowed(false);
        return manager;
    }

    /**
     * SQL 원천 변경·공유 캐시 재사용을 막고 연결은 트랜잭션 종료까지 유지한다.
     * @created 2026-10-29
     * @usedBy entityManagerFactory
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    public Map<String, Object> properties() {
        return Map.ofEntries(
            Map.entry(Server.DIALECT_SETTING, Server.POSTGRES_DIALECT),
            Map.entry(Server.METADATA_ACCESS, false),
            Map.entry(Server.DDL_ACTION, Server.NONE),
            Map.entry(Server.DATABASE_ACTION, Server.NONE),
            Map.entry(Server.SCRIPTS_ACTION, Server.NONE),
            Map.entry(Server.SHARED_CACHE_MODE, Server.NO_SHARED_CACHE),
            Map.entry(Server.SECOND_LEVEL_CACHE, false),
            Map.entry(Server.QUERY_CACHE, false),
            Map.entry(Server.CONNECTION_MODE, Server.DELAYED_ACQUISITION_AND_HOLD),
            Map.entry(Server.SHOW_SQL, false),
            Map.entry(Server.FORMAT_SQL, false),
            Map.entry(Server.SQL_COMMENTS, false),
            Map.entry(Server.TIME_ZONE, Server.UTC)
        );
    }
}
