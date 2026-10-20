package com.payse.api;

import static org.junit.jupiter.api.Assertions.*;
import com.payse.api.bootstrap.DatabaseConfiguration;
import org.junit.jupiter.api.Test;
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
     */
    @Test
    void missingDatabaseConfigurationDoesNotFallbackToEmbeddedDatabase() {
        assertThrows(IllegalStateException.class,
            () -> new DatabaseConfiguration().dataSource(new MockEnvironment()));
    }

    /**
     * PostgreSQL 외 JDBC URL을 연결 전에 거절하는지 검사한다.
     * @created 2026-10-20
     * @usedBy JUnit test
     */
    @Test
    void wrongDriverIsRejectedBeforeConnection() {
        assertThrows(IllegalArgumentException.class,
            () -> new DatabaseConfiguration().dataSource(
                new MockEnvironment().withProperty("PAYSE_JDBC_URL", "jdbc:h2:mem:test")));
    }
}
