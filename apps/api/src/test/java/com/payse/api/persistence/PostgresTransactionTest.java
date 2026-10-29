package com.payse.api.persistence;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.payse.api.config.DatabaseConfiguration;
import com.zaxxer.hikari.HikariDataSource;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.datasource.DataSourceTransactionManager;
import org.springframework.mock.env.MockEnvironment;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 별도 PostgreSQL에서 임시 테이블만 사용해 JDBC 트랜잭션과 연결 재사용을 검사한다.
 * @created 2026-10-25
 * @usedBy Gradle test의 JUnit 실행; 세 PAYSE_TEST_ DB 설정이 모두 있을 때 실행
 * @modified 2026-10-25 - 이름을 역할에 맞게 정리
 */
class PostgresTransactionTest {
    /**
     * 같은 물리 연결에서 커밋·롤백 뒤 사용자 문맥이 제거되고 저장 결과가 구분되는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     */
    @Test
    void clearsTransactionContext() {
        var environment = testEnvironment();
        try (var dataSource = (HikariDataSource) new DatabaseConfiguration().dataSource(environment)) {
            var jdbc = new JdbcTemplate(dataSource);
            var transaction = new TransactionTemplate(new DataSourceTransactionManager(dataSource));
            var role = jdbc.queryForMap(
                "SELECT rolsuper, rolbypassrls FROM pg_catalog.pg_roles WHERE rolname = current_user");
            assertEquals(false, role.get("rolsuper"), "Use a non-superuser test role");
            assertEquals(false, role.get("rolbypassrls"), "Use a test role without BYPASSRLS");
            jdbc.execute("CREATE TEMP TABLE payse_connection_probe (id uuid PRIMARY KEY) ON COMMIT PRESERVE ROWS");

            UUID committedId = UUID.randomUUID();
            UUID rolledBackId = UUID.randomUUID();
            Integer backendPid = jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class);
            assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id', true), '')", String.class));

            transaction.executeWithoutResult(status -> {
                assertEquals(backendPid, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                assertEquals(committedId.toString(), jdbc.queryForObject(
                    "SELECT set_config('payse.user_id', ?, true)", String.class, committedId.toString()));
                assertEquals(1, jdbc.update("INSERT INTO pg_temp.payse_connection_probe(id) VALUES (?)", committedId));
                assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM pg_temp.payse_connection_probe", Integer.class));
            });

            assertEquals(backendPid, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
            assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id', true), '')", String.class));
            assertEquals(1, jdbc.queryForObject(
                "SELECT count(*) FROM pg_temp.payse_connection_probe WHERE id = ?", Integer.class, committedId));

            transaction.executeWithoutResult(status -> {
                assertEquals(backendPid, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                assertEquals(rolledBackId.toString(), jdbc.queryForObject(
                    "SELECT set_config('payse.user_id', ?, true)", String.class, rolledBackId.toString()));
                assertEquals(1, jdbc.update("INSERT INTO pg_temp.payse_connection_probe(id) VALUES (?)", rolledBackId));
                assertEquals(2, jdbc.queryForObject("SELECT count(*) FROM pg_temp.payse_connection_probe", Integer.class));
                status.setRollbackOnly();
            });

            assertEquals(backendPid, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
            assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id', true), '')", String.class));
            assertEquals(0, jdbc.queryForObject(
                "SELECT count(*) FROM pg_temp.payse_connection_probe WHERE id = ?", Integer.class, rolledBackId));
            assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM pg_temp.payse_connection_probe", Integer.class));

            UUID failedId = UUID.randomUUID();
            assertThrows(DataIntegrityViolationException.class, () -> transaction.executeWithoutResult(status -> {
                assertEquals(backendPid, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
                assertEquals(failedId.toString(), jdbc.queryForObject(
                    "SELECT set_config('payse.user_id', ?, true)", String.class, failedId.toString()));
                assertEquals(1, jdbc.update("INSERT INTO pg_temp.payse_connection_probe(id) VALUES (?)", failedId));
                jdbc.update("INSERT INTO pg_temp.payse_connection_probe(id) VALUES (?)", committedId);
            }));

            assertEquals(backendPid, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
            assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id', true), '')", String.class));
            assertEquals(0, jdbc.queryForObject(
                "SELECT count(*) FROM pg_temp.payse_connection_probe WHERE id = ?", Integer.class, failedId));
            assertEquals(1, jdbc.queryForObject(
                "SELECT count(*) FROM pg_temp.payse_connection_probe WHERE id = ?", Integer.class, committedId));
            assertEquals(1, jdbc.queryForObject("SELECT count(*) FROM pg_temp.payse_connection_probe", Integer.class));
        }
    }

    /**
     * 독립 테스트 DB 자격이 전부 없으면 건너뛰고 일부만 제공되면 실패시킨다.
     * @created 2026-10-25
     * @usedBy PostgresTransactionTest.clearsTransactionContext
     * @modified 2026-10-25 - 이름을 역할에 맞게 정리
     * @return 동일 물리 연결을 검사하기 위해 풀 크기를 1로 지정한 테스트 환경
     */
    private MockEnvironment testEnvironment() {
        String url = System.getenv("PAYSE_TEST_JDBC_URL");
        String username = System.getenv("PAYSE_TEST_DB_USER");
        String password = System.getenv("PAYSE_TEST_DB_PASSWORD");
        assumeFalse(url == null && username == null && password == null,
            "PostgreSQL integration skipped: provide PAYSE_TEST_JDBC_URL, PAYSE_TEST_DB_USER and PAYSE_TEST_DB_PASSWORD");
        assertTrue(url != null && !url.isBlank(), "PAYSE_TEST_JDBC_URL is required for PostgreSQL integration");
        assertTrue(username != null && !username.isBlank(), "PAYSE_TEST_DB_USER is required for PostgreSQL integration");
        assertTrue(password != null && !password.isBlank(), "PAYSE_TEST_DB_PASSWORD is required for PostgreSQL integration");
        return new MockEnvironment()
            .withProperty("PAYSE_JDBC_URL", url)
            .withProperty("PAYSE_DB_USER", username)
            .withProperty("PAYSE_DB_PASSWORD", password)
            .withProperty("PAYSE_DB_MAX_POOL_SIZE", "1")
            .withProperty("PAYSE_DB_CONNECTION_TIMEOUT_MS", "5000")
            .withProperty("PAYSE_DB_VALIDATION_TIMEOUT_MS", "1000");
    }
}
