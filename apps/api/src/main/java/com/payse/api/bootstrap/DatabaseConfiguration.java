package com.payse.api.bootstrap;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import javax.sql.DataSource;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Profile;
import org.springframework.core.env.Environment;

/**
 * 명시적으로 database 프로필을 켠 경우에만 PostgreSQL 연결 풀을 구성한다.
 * @created 2026-10-20
 * @usedBy Spring JDBC 자동 구성, 후속 Repository 구현
 */
@Configuration(proxyBeanMethods = false)
@Profile("database")
public class DatabaseConfiguration {
    /**
     * 환경변수로 연결한다. 스키마·시드·역할을 자동 생성하거나 변경하지 않는다.
     * @created 2026-10-20
     * @usedBy Spring JdbcTemplate, 애플리케이션 트랜잭션 관리자
     * @param environment PAYSE_JDBC_URL, PAYSE_DB_USER, PAYSE_DB_PASSWORD를 제공하는 환경
     * @return 종료 시 Spring이 닫는 연결 풀
     */
    @Bean(destroyMethod = "close")
    public DataSource dataSource(Environment environment) {
        String url = environment.getRequiredProperty("PAYSE_JDBC_URL");
        if (!url.startsWith("jdbc:postgresql:")) {
            throw new IllegalArgumentException("PAYSE_JDBC_URL must use PostgreSQL");
        }
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(url);
        config.setUsername(environment.getRequiredProperty("PAYSE_DB_USER"));
        config.setPassword(environment.getRequiredProperty("PAYSE_DB_PASSWORD"));
        config.setMaximumPoolSize(5);
        config.setConnectionTimeout(5000);
        config.setInitializationFailTimeout(1);
        return new HikariDataSource(config);
    }
}
