package com.payse.api.auth.mapper;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.error.AuthStoreException;
import com.payse.api.finance.mapper.TransactionRepository;
import com.payse.api.finance.vo.OriginalState;
import com.payse.api.support.JpaTestContext;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Callable;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * 폐기용 PostgreSQL의 최소 권한 역할에서 JPA 매핑·트랜잭션·격리·동시 요청을 검사한다.
 * @created 2026-10-25
 * @usedBy test_auth_jdbc.py가 실행하는 Gradle JUnit
 */
class AuthJdbcTest {
    private static String url;
    private static String login;
    private static String password;
    private static List<Fixture> fixtures;
    private HikariDataSource pool;
    private JdbcTemplate jdbc;
    private JpaTestContext jpa;
    private AuthRepository repository;
    private AuthTransactions transactions;
    private TransactionRepository links;

    /**
     * 준비 도구가 제공한 관계 입력을 보관하며 표시명이나 첫 행으로 대상을 찾지 않는다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest.loadFixture, 인증 조회·소유권 검사
     * @modified 2026-10-29 - 검증된 원거래 관계 입력 연결
     */
    private record Fixture(UUID userId, UUID sessionId, UUID accountId, String name,
            String phone, String tokenDigest, String verifier, LinkInputs links) {
        /**
         * 테스트 실패 출력에서도 토큰·verifier·합성 자격 원문을 숨긴다.
         * @created 2026-10-25
         * @usedBy JUnit 객체 표현
         * @return 원문이 없는 고정 설명
         */
        @Override public String toString() { return "Fixture[REDACTED]"; }
    }

    /**
     * 전용 환경이 없으면 건너뛰고 일부만 제공되거나 격리 주소 형식이 아니면 실패한다.
     * @created 2026-10-25
     * @usedBy JUnit BeforeAll
     */
    @BeforeAll
    static void readEnvironment() {
        String prefix = "PAYSE_AUTH_TEST_";
        assumeFalse(System.getenv().keySet().stream().noneMatch(key -> key.startsWith(prefix)),
            "Run test_auth_jdbc.py with PostgreSQL binaries and a new work directory");
        url = required("JDBC_URL");
        login = required("DB_USER");
        password = required("DB_PASSWORD");
        assertTrue(url.matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_jdbc"),
            "Only the explicit loopback test database is accepted");
        assertTrue(login.matches("payse_jdbc_[0-9a-f]{32}"), "Use the generated non-admin test login");
        fixtures = List.of(loadFixture(0), loadFixture(1));
        assertNotEquals(fixtures.get(0).userId(), fixtures.get(1).userId());
        assertNotEquals(fixtures.get(0).sessionId(), fixtures.get(1).sessionId());
        assertNotEquals(fixtures.get(0).accountId(), fixtures.get(1).accountId());
    }

    /**
     * 이름이 고정된 테스트 환경 항목을 값 노출 없이 요구한다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest.readEnvironment, AuthJdbcTest.loadFixture
     * @param suffix 전용 환경 키의 접미사
     * @return 비어 있지 않은 입력
     */
    private static String required(String suffix) {
        String value = System.getenv("PAYSE_AUTH_TEST_" + suffix);
        assertTrue(value != null && !value.isBlank(), "Missing dedicated test input: " + suffix);
        return value;
    }

    /**
     * 준비 도구가 생성한 두 관계 묶음 중 명시한 묶음을 읽는다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest.readEnvironment
     * @param index 준비 입력의 0 또는 1 슬롯이며 DB 행 순서가 아님
     * @return UUID로 연결된 사용자·세션·계좌 입력
     * @modified 2026-10-29 - 원거래 준비 ID를 입력으로 전달
     */
    private static Fixture loadFixture(int index) {
        return new Fixture(UUID.fromString(required("USER_" + index)),
            UUID.fromString(required("SESSION_" + index)), UUID.fromString(required("ACCOUNT_" + index)),
            required("NAME_" + index), required("PHONE_" + index),
            required("TOKEN_" + index), required("VERIFIER_" + index), loadLinks(index));
    }

    /**
     * 같은 물리 연결 재사용과 중첩 연결 대기 방지를 검증할 크기 1 풀을 연다.
     * @created 2026-10-25
     * @usedBy JUnit BeforeEach
     * @modified 2026-10-29 - 인증과 같은 JDBC의 원거래 저장소 추가
     * @modified 2026-10-29 - JPA 저장소·트랜잭션으로 기존 PostgreSQL 검증 유지
     */
    @BeforeEach
    void openPool() {
        pool = newPool(1);
        jdbc = new JdbcTemplate(pool);
        jpa = new JpaTestContext(pool);
        repository = new AuthRepository(jpa.entityManager());
        links = new TransactionRepository(jpa.entityManager());
        transactions = new AuthTransactions(jpa.entityManager(), jpa.manager());
        assertEquals(login, jdbc.queryForObject("SELECT session_user", String.class));
        // 테스트 로그인 자체의 관리자·RLS 우회 권한이 없는지 실제 서버에서 확인한다.
        assertEquals(Boolean.TRUE, jdbc.queryForObject(
            "SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolinherit FROM pg_roles WHERE rolname=session_user",
            Boolean.class));
    }

    /**
     * 테스트마다 소유한 연결 풀만 닫는다.
     * @created 2026-10-25
     * @usedBy JUnit AfterEach
     * @modified 2026-10-29 - JPA 저장소·트랜잭션으로 기존 PostgreSQL 검증 유지
     */
    @AfterEach
    void closePool() {
        if (jpa != null) jpa.close();
        if (pool != null) pool.close();
    }

    /**
     * 준비 도구의 자격으로 작은 검사 풀을 만들며 운영 기본값을 정의하지 않는다.
     * @created 2026-10-25
     * @usedBy AuthJdbcTest.openPool, AuthJdbcTest.serializesConcurrentLimits
     * @param size 검증에서 동시에 사용할 최대 연결 수
     * @return 테스트가 종료할 풀
     */
    private HikariDataSource newPool(int size) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(url);
        config.setUsername(login);
        config.setPassword(password);
        config.setMaximumPoolSize(size);
        config.setMinimumIdle(size);
        config.setConnectionTimeout(5000);
        config.setValidationTimeout(1000);
        return new HikariDataSource(config);
    }

    /**
     * 제한 키의 형식만 갖는 매 검사 독립 입력을 만든다. 실제 입력 HMAC 계산 검사는 별도다.
     * @created 2026-10-25
     * @usedBy 제한·롤백·동시성 검사
     * @return 64자리 소문자 hex
     */
    private String newKey() { return UUID.randomUUID().toString().replace("-", "").repeat(2); }

    /**
     * 명시 트랜잭션·역할이 같은 연결에서 적용되고 커밋 후 모두 제거되는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void scopesRoleAndConnection() {
        int backend = jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class);
        String key = newKey();
        AuthRows.IpLimit result = transactions.run(() -> {
            assertEquals(backend, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
            assertEquals("payse_runtime", jdbc.queryForObject("SELECT current_user", String.class));
            assertEquals("read committed", jdbc.queryForObject("SHOW transaction_isolation", String.class));
            assertEquals("off", jdbc.queryForObject("SHOW transaction_read_only", String.class));
            return repository.recordIp(key);
        });
        assertTrue(result.allowed());
        assertNull(result.retryAt());
        assertEquals(backend, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
        assertEquals(login, jdbc.queryForObject("SELECT current_user", String.class));
        assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
        assertEquals(0, pool.getHikariPoolMXBean().getActiveConnections());
    }

    /**
     * 자격 후보의 필드·정규화·빈 결과를 확인하고 후보 조회를 로그인 성공으로 취급하지 않는다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void mapsStoredCandidates() {
        Fixture fixture = fixtures.get(0);
        AuthRows.StoredCode candidate = transactions.run(() -> repository.findCode(
            " " + fixture.name() + " ", fixture.phone().substring(0, 3) + "-" + fixture.phone().substring(3))).orElseThrow();
        assertEquals(fixture.userId(), candidate.userId());
        assertTrue(fixture.verifier().equals(candidate.verifier()), "Stored verifier mapping differs");
        assertFalse(candidate.toString().contains(fixture.verifier()));
        assertFalse(candidate.toString().contains(fixture.phone()));
        assertTrue(transactions.run(() -> repository.findCode("미등록사용자", fixture.phone())).isEmpty());
        assertThrows(IllegalArgumentException.class,
            () -> transactions.run(() -> repository.findCode("' OR 1=1 --", fixture.phone())));
    }

    /**
     * 같은 연결에 다른 사용자·무효 토큰을 이어 넣어도 이전 사용자 금융 행이 노출되지 않는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void isolatesOwnersAndClearsInvalidToken() {
        for (Fixture fixture : fixtures) {
            transactions.run(() -> {
                AuthRows.Session session = repository.authorize(fixture.tokenDigest()).orElseThrow();
                assertEquals(fixture.userId(), session.userId());
                assertEquals(fixture.sessionId(), session.sessionId());
                // 전체 조회도 소유한 한 계좌로 제한되어야 하며 입력 ID로 필터를 대신하지 않는다.
                assertEquals(List.of(fixture.accountId()), jdbc.queryForList("SELECT id FROM payse.financial_accounts", UUID.class));
                assertTrue(repository.authorize("'; DROP TABLE payse.users; --").isEmpty());
                assertEquals(0, jdbc.queryForObject("SELECT count(*) FROM payse.financial_accounts", Integer.class));
                assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
                return null;
            });
            assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
        }
        assertTrue(transactions.run(() -> repository.authorize(null)).isEmpty());
    }

    /**
     * 허용된 실패 5회를 별도 트랜잭션으로 커밋하고 차단 종료 시각의 JDBC 변환·유지를 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void commitsFailuresAndPreservesDeadline() {
        String key = newKey();
        assertNull(transactions.run(() -> repository.retryAt(key)));
        for (int index = 0; index < 4; index++) assertNull(transactions.run(() -> repository.recordFailure(key)));
        Instant deadline = transactions.run(() -> repository.recordFailure(key));
        assertNotNull(deadline);
        assertTrue(deadline.isAfter(Instant.now()));
        assertEquals(deadline, transactions.run(() -> repository.retryAt(key)));
        assertEquals(deadline, transactions.run(() -> repository.recordFailure(key)));
    }

    /**
     * 크기 1 풀에서 IP 선행 기록을 커밋한 뒤 후속 조합 실패만 롤백되는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void preservesIpWhenFollowingWorkRollsBack() {
        String ip = newKey();
        String combination = newKey();
        assertTrue(transactions.run(() -> repository.recordIp(ip)).allowed());
        assertThrows(IllegalStateException.class, () -> transactions.run(() -> {
            repository.recordFailure(combination);
            throw new IllegalStateException("Rollback test operation");
        }));
        for (int index = 0; index < 4; index++) assertNull(transactions.run(() -> repository.recordFailure(combination)));
        assertNotNull(transactions.run(() -> repository.recordFailure(combination)));
        for (int index = 1; index < 60; index++) assertTrue(transactions.run(() -> repository.recordIp(ip)).allowed());
        AuthRows.IpLimit blocked = transactions.run(() -> repository.recordIp(ip));
        assertFalse(blocked.allowed());
        assertNotNull(blocked.retryAt());
        assertEquals(0, pool.getHikariPoolMXBean().getActiveConnections());
    }

    /**
     * DB 권한 거절을 안전한 장애로 전달하고 앞선 제한 기록·사용자 문맥을 롤백한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void rollsBackDatabaseFailureWithoutDetails() {
        String key = newKey();
        int backend = jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class);
        AuthStoreException failure = assertThrows(AuthStoreException.class, () -> transactions.run(() -> {
            repository.recordFailure(key);
            repository.authorize(fixtures.get(0).tokenDigest()).orElseThrow();
            // runtime이 직접 읽을 수 없는 verifier 열을 요청해 실제 PostgreSQL 권한 오류를 유발한다.
            jdbc.queryForList("SELECT code_verifier FROM payse.users");
            return null;
        }));
        assertNull(failure.getCause());
        assertFalse(failure.toString().contains("code_verifier"));
        assertFalse(failure.toString().contains("SELECT"));
        assertEquals(backend, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
        assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
        assertEquals(login, jdbc.queryForObject("SELECT current_user", String.class));
        for (int index = 0; index < 4; index++) assertNull(transactions.run(() -> repository.recordFailure(key)));
        assertNotNull(transactions.run(() -> repository.recordFailure(key)));
    }

    /**
     * 콜백이 DB 예외를 잡아 정상 반환해도 중단된 트랜잭션을 성공으로 반환하지 않는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void rejectsCommitAfterCaughtDatabaseFailure() {
        String key = newKey();
        assertThrows(AuthStoreException.class, () -> transactions.run(() -> {
            repository.recordFailure(key);
            try {
                // PostgreSQL 트랜잭션을 실제 오류 상태로 만들고 호출자 예외 삼킴을 재현한다.
                jdbc.queryForObject("SELECT 1/0", Integer.class);
                fail("Division by zero must fail in PostgreSQL");
            } catch (DataAccessException expected) {
                // 상위 코드의 잘못된 정상 반환을 재현하며 상세 오류는 기록하지 않는다.
            }
            return "uncommitted-result";
        }));
        for (int index = 0; index < 4; index++) assertNull(transactions.run(() -> repository.recordFailure(key)));
        assertNotNull(transactions.run(() -> repository.recordFailure(key)));
        assertEquals(0, pool.getHikariPoolMXBean().getActiveConnections());
    }

    /**
     * 콜백이 정상 종료된 후 COMMIT에서 지연 제약이 실패해도 결과·제한 기록이 확정되지 않는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void rollsBackDeferredCommitFailure() {
        String key = newKey();
        String table = "payse_commit_probe_" + UUID.randomUUID().toString().replace("-", "");
        UUID duplicate = UUID.randomUUID();
        int backend = jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class);
        AuthStoreException failure = assertThrows(AuthStoreException.class, () -> transactions.run(() -> {
            repository.recordFailure(key);
            repository.authorize(fixtures.get(0).tokenDigest()).orElseThrow();
            // 이 트랜잭션에서만 만든 임시 테이블이며 중복 제약을 COMMIT 시점까지 연기한다.
            jdbc.execute("CREATE TEMP TABLE " + table
                + " (id uuid UNIQUE DEFERRABLE INITIALLY DEFERRED) ON COMMIT DROP");
            assertEquals(2, jdbc.update("INSERT INTO pg_temp." + table + "(id) VALUES (?),(?)", duplicate, duplicate));
            assertEquals(2, jdbc.queryForObject("SELECT count(*) FROM pg_temp." + table, Integer.class));
            return "must-not-be-committed";
        }));
        assertNull(failure.getCause());
        assertFalse(failure.toString().contains(table));
        assertFalse(failure.toString().contains(duplicate.toString()));
        assertEquals(backend, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
        assertEquals(login, jdbc.queryForObject("SELECT current_user", String.class));
        assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
        assertNull(jdbc.queryForObject("SELECT to_regclass(?)", String.class, "pg_temp." + table));
        for (int index = 0; index < 4; index++) assertNull(transactions.run(() -> repository.recordFailure(key)));
        assertNotNull(transactions.run(() -> repository.recordFailure(key)));
        assertEquals(0, pool.getHikariPoolMXBean().getActiveConnections());
    }

    /**
     * autocommit·읽기 전용·다른 격리 수준에서 호출하면 SQL 실행 전에 거절한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 저장소·트랜잭션으로 기존 PostgreSQL 검증 유지
     */
    @Test
    void rejectsUnsafeTransactionBoundaries() {
        assertThrows(IllegalStateException.class, () -> repository.retryAt(newKey()));
        TransactionTemplate readOnly = new TransactionTemplate(jpa.manager());
        readOnly.setIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
        readOnly.setReadOnly(true);
        assertThrows(IllegalStateException.class, () -> readOnly.execute(status -> repository.retryAt(newKey())));
        TransactionTemplate repeatedRead = new TransactionTemplate(jpa.manager());
        repeatedRead.setIsolationLevel(TransactionDefinition.ISOLATION_REPEATABLE_READ);
        assertThrows(IllegalStateException.class, () -> repeatedRead.execute(status -> repository.retryAt(newKey())));
        assertThrows(IllegalStateException.class, () -> transactions.run(() -> transactions.run(() -> 1)));
        assertEquals(0, pool.getHikariPoolMXBean().getActiveConnections());
    }

    /**
     * JPA 동시 요청에서도 동일 제한 키의 실패 5회·IP 60회 경계가 소실되지 않는지 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @throws Exception 검사 작업이 시간 안에 완료하지 못하거나 실패한 경우
     * @modified 2026-10-29 - JPA 저장소·트랜잭션으로 기존 PostgreSQL 검증 유지
     */
    @Test
    void serializesConcurrentLimits() throws Exception {
        try (HikariDataSource concurrentPool = newPool(4); JpaTestContext concurrentJpa = new JpaTestContext(concurrentPool);
                var executor = Executors.newFixedThreadPool(4)) {
            AuthRepository concurrentRepo = new AuthRepository(concurrentJpa.entityManager());
            AuthTransactions concurrentTx = new AuthTransactions(concurrentJpa.entityManager(), concurrentJpa.manager());
            String key = newKey();
            CountDownLatch start = new CountDownLatch(1);
            List<Callable<Boolean>> failures = new ArrayList<>();
            for (int index = 0; index < 6; index++) failures.add(() -> {
                assertTrue(start.await(5, TimeUnit.SECONDS));
                return concurrentTx.run(() -> concurrentRepo.recordFailure(key)) != null;
            });
            var failureFutures = failures.stream().map(executor::submit).toList();
            start.countDown();
            int blockedFailures = 0;
            for (var future : failureFutures) if (future.get(15, TimeUnit.SECONDS)) blockedFailures++;
            assertEquals(2, blockedFailures);
            String ip = newKey();
            List<Callable<Boolean>> requests = new ArrayList<>();
            for (int index = 0; index < 65; index++) requests.add(() -> concurrentTx.run(() -> concurrentRepo.recordIp(ip)).allowed());
            int allowed = 0;
            for (var future : executor.invokeAll(requests)) if (future.get(15, TimeUnit.SECONDS)) allowed++;
            assertEquals(60, allowed);
        }
    }

    /**
     * 준비 단계에서 소유권·관계를 확인한 거래 식별자를 보관한다.
     * @created 2026-10-29
     * @usedBy AuthJdbcTest.loadLinks, 원거래 JOIN 검사
     */
    private record LinkInputs(UUID cardId, UUID purchaseId, UUID cancellationId,
            UUID unavailableId, UUID missingId, UUID unreferencedId, UUID hiddenPurchaseId) {
        /**
         * 테스트 실패 메시지에 금융 식별자를 남기지 않는다.
         * @created 2026-10-29
         * @usedBy JUnit 객체 표현
         * @return 원문 없는 고정 설명
         */
        @Override public String toString() { return "LinkInputs[REDACTED]"; }
    }

    /**
     * 준비된 원결제·취소와 미확보 참조를 명시적인 환경 키로 읽는다.
     * @created 2026-10-29
     * @usedBy AuthJdbcTest.loadFixture
     * @param index 준비 입력 슬롯; DB 행 순서가 아님
     * @return 검증된 관계 ID 입력
     */
    private static LinkInputs loadLinks(int index) {
        return new LinkInputs(UUID.fromString(required("CARD_" + index)),
            UUID.fromString(required("PURCHASE_" + index)),
            UUID.fromString(required("CANCELLATION_" + index)),
            UUID.fromString(required("UNAVAILABLE_" + index)),
            UUID.fromString(required("MISSING_" + index)),
            UUID.fromString(required("UNREFERENCED_" + index)),
            UUID.fromString(required("HIDDEN_PURCHASE_" + index)));
    }

    /**
     * 날짜만 있는 취소도 인증과 같은 연결에서 원결제 날짜·금액·버전에 연결한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void joinsOriginalPurchase() {
        for (Fixture fixture : fixtures) transactions.run(() -> {
            assertTrue(repository.authorize(fixture.tokenDigest()).isPresent());
            int backend = jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class);
            var result = links.findLink(fixture.links().cancellationId()).orElseThrow();
            assertEquals(fixture.links().cancellationId(), result.id());
            assertEquals(LocalDate.of(2026, 10, 13), result.cancellationDate());
            assertEquals(fixture.links().purchaseId(), result.originalTransactionId());
            assertEquals(OriginalState.AVAILABLE, result.originalState());
            assertEquals(fixture.links().purchaseId(), result.original().id());
            assertEquals(fixture.links().cardId(), result.original().cardId());
            assertEquals("card_purchase", result.original().recordKind());
            assertEquals(LocalDate.of(2026, 10, 12), result.original().purchaseDate());
            assertEquals(30000L, result.original().amountKRW());
            assertEquals("jdbc-source", result.original().sourceVersion());
            assertEquals("TransactionLink[REDACTED]", result.toString());
            assertEquals("Original[REDACTED]", result.original().toString());
            assertEquals(backend, jdbc.queryForObject("SELECT pg_backend_pid()", Integer.class));
            return null;
        });
    }

    /**
     * 원거래 행 미확보와 참조 미상을 구분하고 두 경우 모두 현재 취소행을 보존한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void preservesMissingOriginals() {
        for (Fixture fixture : fixtures) transactions.run(() -> {
            assertTrue(repository.authorize(fixture.tokenDigest()).isPresent());
            var unavailable = links.findLink(fixture.links().unavailableId()).orElseThrow();
            assertEquals(fixture.links().unavailableId(), unavailable.id());
            assertEquals(LocalDate.of(2026, 10, 14), unavailable.cancellationDate());
            assertEquals(fixture.links().missingId(), unavailable.originalTransactionId());
            assertEquals(OriginalState.UNAVAILABLE, unavailable.originalState());
            assertNull(unavailable.original());
            var absent = links.findLink(fixture.links().unreferencedId()).orElseThrow();
            assertEquals(fixture.links().unreferencedId(), absent.id());
            assertEquals(LocalDate.of(2026, 10, 15), absent.cancellationDate());
            assertEquals(OriginalState.ABSENT, absent.originalState());
            assertNull(absent.originalTransactionId());
            assertNull(absent.original());
            var purchase = links.findLink(fixture.links().purchaseId()).orElseThrow();
            assertNull(purchase.cancellationDate());
            assertEquals(OriginalState.ABSENT, purchase.originalState());
            return null;
        });
    }

    /**
     * 다른 사용자와 미연결 카드의 거래는 UUID를 알고 있어도 반환하지 않는다.
     * @created 2026-10-29
     * @usedBy JUnit test
     */
    @Test
    void enforcesSourceAccess() {
        for (int index = 0; index < fixtures.size(); index++) {
            Fixture fixture = fixtures.get(index);
            Fixture other = fixtures.get(1 - index);
            transactions.run(() -> {
                assertTrue(repository.authorize(fixture.tokenDigest()).isPresent());
                assertTrue(links.findLink(other.links().cancellationId()).isEmpty());
                assertTrue(links.findLink(other.links().purchaseId()).isEmpty());
                assertTrue(links.findLink(fixture.links().hiddenPurchaseId()).isEmpty());
                assertTrue(links.findLink(UUID.randomUUID()).isEmpty());
                return null;
            });
        }
    }

    /**
     * 인증 문맥 없이 자동 커밋하거나 별도 연결로 조회하는 경로를 거절한다.
     * @created 2026-10-29
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 저장소·트랜잭션으로 기존 PostgreSQL 검증 유지
     */
    @Test
    void requiresAuthenticatedTransaction() {
        Fixture fixture = fixtures.get(0);
        assertThrows(IllegalStateException.class, () -> links.findLink(fixture.links().cancellationId()));
        assertThrows(IllegalStateException.class,
            () -> transactions.run(() -> links.findLink(fixture.links().cancellationId())));
        try (HikariDataSource separatePool = newPool(1); JpaTestContext separateJpa = new JpaTestContext(separatePool)) {
            var separate = new TransactionRepository(separateJpa.entityManager());
            assertThrows(IllegalStateException.class, () -> transactions.run(() -> {
                assertTrue(repository.authorize(fixture.tokenDigest()).isPresent());
                return separate.findLink(fixture.links().cancellationId());
            }));
        }
        transactions.run(() -> {
            assertTrue(repository.authorize(fixture.tokenDigest()).isPresent());
            assertTrue(links.findLink(fixture.links().cancellationId()).isPresent());
            return null;
        });
        assertThrows(IllegalStateException.class,
            () -> transactions.run(() -> links.findLink(fixture.links().cancellationId())));
    }
}
