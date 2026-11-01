package com.payse.api.config;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.config.DatabaseConfiguration;
import com.zaxxer.hikari.HikariConfig;
import java.util.Map;
import javax.sql.DataSource;
import org.junit.jupiter.api.Test;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.mock.env.MockEnvironment;

/**
 * DB 설정을 연결 전에 검증한다. 실제 PostgreSQL 연결 검사는 별도다.
 * @created 2026-10-20
 * @usedBy Gradle test의 JUnit 실행
 */
class DatabaseConfigurationTest {
    /**
     * DB 설정 누락 시 임의 내장 DB로 대체하지 않는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void requiresDatabaseSettings() {
        assertThrows(IllegalStateException.class,
            () -> new DatabaseConfiguration().dataSource(new MockEnvironment()));
    }

    /**
     * PostgreSQL 외 JDBC URL을 연결 전에 거절하는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void rejectsOtherDrivers() {
        assertThrows(IllegalArgumentException.class,
            () -> new DatabaseConfiguration().dataSource(
                new MockEnvironment().withProperty("PAYSE_JDBC_URL", "jdbc:h2:mem:test")));
    }

    /**
     * 비활성 database 프로필은 DB 설정과 연결을 요구하지 않는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void skipsInactiveProfile() {
        try (var context = new AnnotationConfigApplicationContext()) {
            context.setEnvironment(new MockEnvironment());
            context.register(DatabaseConfiguration.class);
            context.refresh();
            assertTrue(context.getBeansOfType(DataSource.class).isEmpty());
        }
    }

    /**
     * 활성 프로필의 필수 설정 누락은 Spring 시작 단계에서 실패하는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void failsStartupWithoutSettings() {
        try (var context = new AnnotationConfigApplicationContext()) {
            var environment = new MockEnvironment();
            environment.setActiveProfiles("database");
            context.setEnvironment(environment);
            context.register(DatabaseConfiguration.class);
            assertThrows(RuntimeException.class, context::refresh);
        }
    }

    /**
     * 자격과 운영값 각각의 누락·빈 문자열을 기본값으로 숨기지 않는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void requiresEverySetting() {
        for (String name : validSettings().keySet()) {
            var missing = new MockEnvironment();
            validSettings().forEach((key, value) -> {
                if (!key.equals(name)) {
                    missing.setProperty(key, value);
                }
            });
            assertThrows(IllegalStateException.class,
                () -> new DatabaseConfiguration().poolConfig(missing), name);
            for (String blank : new String[] {"", " \t\n"}) {
                var environment = validEnvironment().withProperty(name, blank);
                assertThrows(IllegalStateException.class,
                    () -> new DatabaseConfiguration().poolConfig(environment), name);
            }
        }
    }

    /**
     * 두 운영 설정의 값과 최소 유효 경계가 보정 없이 풀 구성에 반영되는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void usesExplicitPoolSettings() {
        HikariConfig config = new DatabaseConfiguration().poolConfig(validEnvironment());
        assertEquals(3, config.getMaximumPoolSize());
        assertEquals(3000, config.getConnectionTimeout());
        assertEquals(1000, config.getValidationTimeout());
        assertEquals(1, config.getInitializationFailTimeout());

        var environment = validEnvironment()
            .withProperty("PAYSE_DB_MAX_POOL_SIZE", "1")
            .withProperty("PAYSE_DB_CONNECTION_TIMEOUT_MS", "251")
            .withProperty("PAYSE_DB_VALIDATION_TIMEOUT_MS", "250");
        HikariConfig minimumConfig = new DatabaseConfiguration().poolConfig(environment);
        assertEquals(1, minimumConfig.getMaximumPoolSize());
        assertEquals(251, minimumConfig.getConnectionTimeout());
        assertEquals(250, minimumConfig.getValidationTimeout());
        assertEquals("fixture-user", minimumConfig.getUsername());
        assertEquals("fixture-password", minimumConfig.getPassword());
    }

    /**
     * 운영값의 음수·0·소수·공백·범위 초과·비ASCII 입력을 연결 전에 거절한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void rejectsInvalidNumbers() {
        String[] names = {"PAYSE_DB_MAX_POOL_SIZE", "PAYSE_DB_CONNECTION_TIMEOUT_MS",
            "PAYSE_DB_VALIDATION_TIMEOUT_MS"};
        for (String name : names) {
            for (String invalid : new String[] {"-1", "0", "1.5", "+2", " 2", "2 ", "２", "2147483648"}) {
                var environment = validEnvironment().withProperty(name, invalid);
                assertThrows(IllegalArgumentException.class,
                    () -> new DatabaseConfiguration().poolConfig(environment), name);
            }
        }
    }

    /**
     * 검증 대기시간의 라이브러리 하한과 연결 대기시간보다 작은 관계를 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void checksTimeoutBounds() {
        for (String invalid : new String[] {"249", "3000", "3001"}) {
            var environment = validEnvironment().withProperty("PAYSE_DB_VALIDATION_TIMEOUT_MS", invalid);
            assertThrows(IllegalArgumentException.class,
                () -> new DatabaseConfiguration().poolConfig(environment));
        }
    }

    /**
     * 설정 파싱 오류의 메시지·원인에 잘못 입력한 비밀 문자열을 남기지 않는다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void redactsInvalidSettings() {
        String secretMarker = "private-value-do-not-log";
        var environment = validEnvironment().withProperty("PAYSE_DB_MAX_POOL_SIZE", secretMarker);
        var failure = assertThrows(IllegalArgumentException.class,
            () -> new DatabaseConfiguration().poolConfig(environment));
        assertFalse(failure.toString().contains(secretMarker));
        assertNull(failure.getCause());
    }

    /**
     * 연결하지 않는 설정 검증에 쓸 명시적 테스트 값을 제공한다.
     * @created 2026-10-25
     * @usedBy DatabaseConfigurationTest.validEnvironment, requiresEverySetting
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @return 운영 기본값이 아닌 테스트 입력
     */
    private Map<String, String> validSettings() {
        return Map.of(
            "PAYSE_JDBC_URL", "jdbc:postgresql://localhost/unused_configuration_test",
            "PAYSE_DB_USER", "fixture-user",
            "PAYSE_DB_PASSWORD", "fixture-password",
            "PAYSE_DB_MAX_POOL_SIZE", "3",
            "PAYSE_DB_CONNECTION_TIMEOUT_MS", "3000",
            "PAYSE_DB_VALIDATION_TIMEOUT_MS", "1000");
    }

    /**
     * 검증별로 독립된 설정 원천을 만들어 변경된 입력이 다른 검사에 섞이지 않게 한다.
     * @created 2026-10-25
     * @usedBy DatabaseConfigurationTest의 설정 검증 메서드
     * @return 연결하지 않은 테스트 환경
     */
    private MockEnvironment validEnvironment() {
        var environment = new MockEnvironment();
        validSettings().forEach(environment::setProperty);
        return environment;
    }
}
