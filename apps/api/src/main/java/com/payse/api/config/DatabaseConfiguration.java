package com.payse.api.config;

import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiMessageConstants;
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
 * @usedBy JpaConfiguration, Spring JDBC 관측 도구
 */
@Configuration(proxyBeanMethods = false)
@Profile("database")
public class DatabaseConfiguration {

    /**
     * 환경변수로 연결한다. 스키마·시드·역할을 자동 생성하거나 변경하지 않는다.
     * @created 2026-10-20
     * @usedBy JpaConfiguration, 애플리케이션 트랜잭션 관리자
     * @modified 2026-10-25 - 명시된 연결 풀 설정을 연결 전에 검증
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @param environment DB 자격과 풀 크기·연결/검증 대기시간을 제공하는 환경
     * @return 종료 시 Spring이 닫는 연결 풀
     */
    @Bean(destroyMethod = "close")
    public DataSource dataSource(Environment environment) {
        return new HikariDataSource(poolConfig(environment));
    }

    /**
     * 연결 없이 필수 DB 설정과 대기시간 관계를 검증해 풀 구성을 만든다.
     * @created 2026-10-25
     * @usedBy DatabaseConfiguration.dataSource, DatabaseConfigurationTest
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @param environment 값 누락을 기본값으로 대체하지 않는 서버 설정
     * @return 아직 DB에 연결하지 않은 구성; 자격을 포함하므로 직렬화·로그 금지
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-05 - 직접 실행에도 원격 DB 인증서 검증과 안전한 URL 경계 적용
     */
    public HikariConfig poolConfig(Environment environment) {
        String url = requireProperty(environment, ApiConfigConstants.Server.PAYSE_JDBC_URL);
        if (!url.startsWith(ApiConfigConstants.Server.POSTGRES_URL_PREFIX)) {
            throw new IllegalArgumentException(ApiMessageConstants.Server.INVALID_JDBC_URL);
        }
        DatabaseTransport.verify(url);

        String username = requireProperty(environment, ApiConfigConstants.Server.PAYSE_DB_USER);
        String password = requireProperty(environment, ApiConfigConstants.Server.PAYSE_DB_PASSWORD);
        int maxPoolSize = requirePositiveInt(
            environment,
            ApiConfigConstants.Server.PAYSE_DB_MAX_POOL_SIZE
        );
        int connectionTimeout = requirePositiveInt(
            environment,
            ApiConfigConstants.Server.PAYSE_DB_CONNECTION_TIMEOUT_MS
        );
        int validationTimeout = requirePositiveInt(
            environment,
            ApiConfigConstants.Server.PAYSE_DB_VALIDATION_TIMEOUT_MS
        );
        if (validationTimeout < 250 || validationTimeout >= connectionTimeout) {
            throw new IllegalArgumentException(
                ApiMessageConstants.Server.INVALID_VALIDATION_TIMEOUT
            );
        }

        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(url);
        config.setUsername(username);
        config.setPassword(password);
        config.setMaximumPoolSize(maxPoolSize);
        config.setConnectionTimeout(connectionTimeout);
        config.setValidationTimeout(validationTimeout);
        config.setInitializationFailTimeout(1);
        return config;
    }

    /**
     * 필수 문자열을 원문 변경 없이 읽고 누락 오류에 설정값을 포함하지 않는다.
     * @created 2026-10-25
     * @usedBy DatabaseConfiguration.poolConfig, DatabaseConfiguration.requirePositiveInt
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @param environment 서버 설정 원천
     * @param name 검증할 설정 이름
     * @return 비어 있지 않은 설정 원문
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private String requireProperty(Environment environment, String name) {
        String value;
        try {
            value = environment.getProperty(name);
        } catch (IllegalArgumentException failure) {
            throw new IllegalArgumentException(
                name + ApiMessageConstants.Server.UNRESOLVED_SETTING
            );
        }

        if (value == null || value.isBlank()) {
            throw new IllegalStateException(name + ApiMessageConstants.Server.REQUIRED_SETTING);
        }

        return value;
    }

    /**
     * 양의 ASCII 십진 정수를 읽으며 형식·범위 오류에 입력 원문을 남기지 않는다.
     * @created 2026-10-25
     * @usedBy DatabaseConfiguration.poolConfig
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @param environment 서버 설정 원천
     * @param name 검증할 설정 이름
     * @return 1 이상 Integer.MAX_VALUE 이하의 값
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private int requirePositiveInt(Environment environment, String name) {
        String value = requireProperty(environment, name);
        try {
            if (!value.matches("[0-9]+")) {
                throw new NumberFormatException();
            }

            int result = Integer.parseInt(value);
            if (result < 1) {
                throw new NumberFormatException();
            }

            return result;
        } catch (NumberFormatException failure) {
            throw new IllegalArgumentException(
                name + ApiMessageConstants.Server.INVALID_INTEGER_SETTING
            );
        }
    }
}
