package com.payse.api.auth;

import static org.junit.jupiter.api.Assertions.*;
import static org.junit.jupiter.api.Assumptions.assumeFalse;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import java.net.InetAddress;
import java.security.SecureRandom;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.support.JdbcTransactionManager;

/**
 * 폐기용 PostgreSQL에서 실제 세션 서비스·권한·경합·롤백을 검증한다.
 * @created 2026-10-26
 * @usedBy test_session_service.py가 실행하는 Gradle JUnit
 */
class SessionJdbcTest {
    private static String url;
    private static String login;
    private static String password;
    private static String adminLogin;
    private static String adminPassword;
    private HikariDataSource pool;
    private HikariDataSource adminPool;
    private JdbcTemplate jdbc;
    private JdbcTemplate admin;
    private AuthTransactions transactions;
    private AuthRepository repository;
    private AuthCrypto crypto;
    private AuthService service;
    private String application;
    private Fixture user;

    /**
     * 검사 준비 도구의 명시 UUID·합성 자격 묶음이며 표시명 조회를 대신하지 않는다.
     * @created 2026-10-26
     * @usedBy SessionJdbcTest.prepareUser, 로그인·재확인 검증
     */
    private record Fixture(UUID id, String name, String phone, String code) {
        /**
         * 실패 출력에 합성 자격 원문이 노출되지 않게 한다.
         * @created 2026-10-26
         * @usedBy Java 문자열 표현
         * @return 원문이 없는 설명
         */
        @Override public String toString() { return "Fixture[REDACTED]"; }
    }

    /**
     * 명시한 폐기용 주소·역할 형식만 허용하고 일부 환경 누락은 실패시킨다.
     * @created 2026-10-26
     * @usedBy JUnit BeforeAll
     */
    @BeforeAll
    static void readEnvironment() {
        assumeFalse(System.getenv().keySet().stream().noneMatch(key -> key.startsWith("PAYSE_SESSION_TEST_")),
            "Run test_session_service.py with PostgreSQL binaries and a new work directory");
        url = required("JDBC_URL");
        login = required("DB_USER");
        password = required("DB_PASSWORD");
        adminLogin = required("ADMIN_USER");
        adminPassword = required("ADMIN_PASSWORD");
        assertTrue(url.matches("jdbc:postgresql://127\\.0\\.0\\.1:[0-9]+/payse_auth_test_sessions"));
        assertTrue(login.matches("payse_session_[0-9a-f]{32}"));
        assertTrue(adminLogin.matches("payse_session_setup_[0-9a-f]{32}"));
    }

    /**
     * 값 출력 없이 검사 전용 환경 항목을 요구한다.
     * @created 2026-10-26
     * @usedBy SessionJdbcTest.readEnvironment
     * @param suffix 환경 키 접미사
     * @return 비어 있지 않은 값
     */
    private static String required(String suffix) {
        String value = System.getenv("PAYSE_SESSION_TEST_" + suffix);
        assertTrue(value != null && !value.isBlank(), "Missing session test input: " + suffix);
        return value;
    }

    /**
     * 제품 호출과 테스트 준비용 연결을 분리하고 매 검사 새 사용자·암호 키를 만든다.
     * @created 2026-10-26
     * @usedBy JUnit BeforeEach
     */
    @BeforeEach
    void open() {
        application = "session_test_" + UUID.randomUUID().toString().replace("-", "");
        pool = newPool(login, password, 8, application);
        adminPool = newPool(adminLogin, adminPassword, 3, application + "_setup");
        jdbc = new JdbcTemplate(pool);
        admin = new JdbcTemplate(adminPool);
        assertEquals(Boolean.TRUE, jdbc.queryForObject(
            "SELECT NOT rolsuper AND NOT rolbypassrls AND NOT rolinherit FROM pg_roles WHERE rolname=session_user",
            Boolean.class));
        repository = new AuthRepository(jdbc);
        transactions = new AuthTransactions(jdbc, new JdbcTransactionManager(pool));
        SecureRandom random = new SecureRandom();
        byte[] codeKey = new byte[32];
        byte[] limitKey = new byte[32];
        random.nextBytes(codeKey);
        random.nextBytes(limitKey);
        crypto = new AuthCrypto(new AuthSecrets("session-test", codeKey, limitKey));
        service = new AuthService(repository, transactions, crypto);
        user = prepareUser();
    }

    /**
     * 생성한 풀만 종료하며 테스트 사용자 행은 폐기용 클러스터 종료 시 폐기한다.
     * @created 2026-10-26
     * @usedBy JUnit AfterEach
     */
    @AfterEach
    void close() {
        if (pool != null) pool.close();
        if (adminPool != null) adminPool.close();
    }

    /**
     * 전달받은 검사 자격으로 작은 풀을 생성한다. 운영 기본값을 정의하지 않는다.
     * @created 2026-10-26
     * @usedBy SessionJdbcTest.open
     * @param username 검사 역할
     * @param secret 하위 프로세스 환경에서 받은 임시 비밀번호
     * @param size 동시 검증 연결 수
     * @param name 잠금 관측용 application_name
     * @return 테스트가 종료할 풀
     */
    private HikariDataSource newPool(String username, String secret, int size, String name) {
        HikariConfig config = new HikariConfig();
        config.setJdbcUrl(url);
        config.setUsername(username);
        config.setPassword(secret);
        config.setMinimumIdle(0);
        config.setMaximumPoolSize(size);
        config.setConnectionTimeout(5000);
        config.setValidationTimeout(1000);
        config.addDataSourceProperty("ApplicationName", name);
        return new HikariDataSource(config);
    }

    /**
     * 새 UUID와 합성 자격을 공통 사용자 테이블에 넣고 단일 관계·상태를 확인한다.
     * @created 2026-10-26
     * @usedBy SessionJdbcTest.open, 타 사용자 검증
     * @return 실제 준비된 사용자 입력
     */
    private Fixture prepareUser() {
        UUID id = UUID.randomUUID();
        String suffix = id.toString().replace("-", "").substring(0, 12);
        for (int digit = 0; digit < 10; digit++) suffix = suffix.replace((char) ('0' + digit), (char) ('k' + digit));
        SecureRandom random = new SecureRandom();
        Fixture fixture = new Fixture(id, "고객" + suffix,
            "010" + String.format(Locale.ROOT, "%08d", random.nextInt(100_000_000)),
            String.format(Locale.ROOT, "%06d", random.nextInt(1_000_000)));
        assertEquals(1, admin.update("""
            INSERT INTO payse.users(id, name, phone, code_verifier, data_version, created_at)
            VALUES (?, ?, ?, ?, 1, clock_timestamp())
            """, fixture.id(), fixture.name(), fixture.phone(), crypto.codeVerifier(fixture.id(), fixture.code())));
        assertEquals(1, admin.queryForObject("""
            SELECT count(*) FROM payse.users
            WHERE id=? AND name=? AND phone=? AND deactivated_at IS NULL AND data_version=1
            """, Integer.class, fixture.id(), fixture.name(), fixture.phone()));
        return fixture;
    }

    /**
     * DNS 조회 없이 검사마다 별도 IPv6 주소 바이트를 준비한다.
     * @created 2026-10-26
     * @usedBy 로그인·제한 검증
     * @return 원격 연결 주소를 대신하는 합성 주소
     */
    private InetAddress peer() throws Exception {
        byte[] address = new byte[16];
        new SecureRandom().nextBytes(address);
        address[0] = (byte) 0xfd;
        return InetAddress.getByAddress(address);
    }

    /**
     * 준비된 사용자 자격으로 로그인하고 성공 종류를 확인한다.
     * @created 2026-10-26
     * @usedBy 세션 수명주기 검증
     * @param fixture 명시적으로 생성한 사용자
     * @return 커밋 후 반환된 세션 정보
     */
    private AuthResult.Login signIn(Fixture fixture) throws Exception {
        return assertInstanceOf(AuthResult.Login.class,
            service.login(peer(), fixture.name(), fixture.phone(), fixture.code()));
    }

    /**
     * 사용자 ID로 해당 사용자 전체/활성 세션 수를 검사한다.
     * @created 2026-10-26
     * @usedBy 세션 생성·재확인·종료 검증
     * @param fixture 준비한 사용자
     * @param active 활성 행만 셀지 여부
     * @return 해당 상태의 정확한 행 수
     */
    private int sessions(Fixture fixture, boolean active) {
        String sql = "SELECT count(*) FROM payse.demo_sessions WHERE user_id=?";
        if (active) sql += " AND ended_at IS NULL";
        return admin.queryForObject(sql, Integer.class, fixture.id());
    }

    /**
     * 업무 실패 종류와 제한 시각의 유무를 함께 확인한다.
     * @created 2026-10-26
     * @usedBy 실패·제한 검증
     * @param result 서비스 결과
     * @param reason 기대 실패 종류
     * @return 검증한 실패 결과
     */
    private AuthResult.Failure failure(AuthResult result, AuthResult.Reason reason) {
        AuthResult.Failure failure = assertInstanceOf(AuthResult.Failure.class, result);
        assertEquals(reason, failure.reason());
        assertEquals(reason == AuthResult.Reason.RATE_LIMITED, failure.retryAt() != null);
        return failure;
    }

    /**
     * 제한 키로 사건 수를 읽고 없는 행은 0건으로 구분한다.
     * @created 2026-10-26
     * @usedBy 실패 기록 커밋·IP 검증
     * @param kind ip 또는 combo
     * @param key 서비스와 같은 암호 연산으로 만든 제한 키
     * @return 해당 키에 저장된 사건 수
     */
    private int events(String kind, String key) {
        return admin.queryForObject("""
            SELECT coalesce((SELECT cardinality(event_times) FROM payse.auth_rate_limits
                WHERE kind=? AND key_digest=?), 0)
            """, Integer.class, kind, key);
    }

    /**
     * 서비스가 만든 세션과 저장된 검증값·시각·소유자를 대조한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void createsSessionAfterCommit() throws Exception {
        AuthResult.Login result = assertInstanceOf(AuthResult.Login.class,
            service.login(peer(), " " + user.name() + " ", user.phone(), user.code()));
        assertEquals(user.id(), result.userId());
        assertEquals(user.name(), result.name());
        assertNotNull(result.sessionId());
        assertNotNull(result.issuedAt());
        assertEquals(1, sessions(user, true));
        assertEquals(1, admin.queryForObject("""
            SELECT count(*) FROM payse.demo_sessions
            WHERE id=? AND user_id=? AND token_digest=? AND issued_at=? AND ended_at IS NULL
            """, Integer.class, result.sessionId(), user.id(), crypto.tokenDigest(result.accessToken()),
            java.sql.Timestamp.from(result.issuedAt())));
        assertEquals(1L, admin.queryForObject("SELECT data_version FROM payse.users WHERE id=?", Long.class, user.id()));
        assertFalse(result.toString().contains(result.accessToken()));
        assertFalse(result.toString().contains(user.name()));
        assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
        assertEquals(login, jdbc.queryForObject("SELECT current_user", String.class));
    }

    /**
     * 올바른 자격의 재로그인을 거절하고 기존 세션과 실패 횟수를 유지한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void preservesExistingSession() throws Exception {
        AuthResult.Login first = signIn(user);
        failure(service.login(peer(), user.name(), user.phone(), user.code()), AuthResult.Reason.AUTH_REJECTED);
        assertEquals(1, sessions(user, true));
        assertEquals(1, sessions(user, false));
        assertEquals(0, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        AuthResult.Verified verified = assertInstanceOf(AuthResult.Verified.class,
            service.reverify(peer(), first.accessToken(), user.name(), user.phone(), user.code()));
        assertEquals(first.sessionId(), verified.sessionId());
    }

    /**
     * 같은 계정의 동시 최초 로그인은 성공 한 개와 기존 세션 보존으로 끝난다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void allowsOnlyOneConcurrentLogin() throws Exception {
        CountDownLatch start = new CountDownLatch(1);
        try (var executor = Executors.newFixedThreadPool(8)) {
            List<Future<AuthResult>> pending = new ArrayList<>();
            for (int index = 0; index < 8; index++) {
                InetAddress address = peer();
                pending.add(executor.submit(() -> {
                    assertTrue(start.await(5, TimeUnit.SECONDS));
                    return service.login(address, user.name(), user.phone(), user.code());
                }));
            }
            start.countDown();
            int successful = 0;
            for (Future<AuthResult> future : pending) {
                AuthResult result = future.get(10, TimeUnit.SECONDS);
                if (result instanceof AuthResult.Login) successful++;
                else failure(result, AuthResult.Reason.AUTH_REJECTED);
            }
            assertEquals(1, successful);
        }
        assertEquals(1, sessions(user, false));
        assertEquals(0, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
    }

    /**
     * 재확인은 같은 사용자·세션을 반환하며 새 행이나 새 토큰을 만들지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void reverifiesWithoutNewSession() throws Exception {
        AuthResult.Login first = signIn(user);
        for (int index = 0; index < 2; index++) {
            AuthResult.Verified verified = assertInstanceOf(AuthResult.Verified.class,
                service.reverify(peer(), first.accessToken(), user.name(), user.phone(), user.code()));
            assertEquals(first.userId(), verified.userId());
            assertEquals(first.sessionId(), verified.sessionId());
        }
        assertEquals(1, sessions(user, false));
        assertTrue(crypto.verifyToken(first.accessToken(), admin.queryForObject(
            "SELECT token_digest FROM payse.demo_sessions WHERE id=?", String.class, first.sessionId())));
    }

    /**
     * 다른 소유자 자격과 코드 실패는 기존 토큰을 끝내지 않고 실패만 기록한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void rejectsOtherOwnerWithoutEndingSession() throws Exception {
        Fixture other = prepareUser();
        AuthResult.Login first = signIn(user);
        failure(service.reverify(peer(), first.accessToken(), other.name(), other.phone(), other.code()),
            AuthResult.Reason.AUTH_REJECTED);
        assertEquals(1, events("combo", crypto.combinationLimitKey(other.name(), other.phone())));
        assertEquals(1, sessions(user, true));
        assertEquals(0, sessions(other, false));
        assertInstanceOf(AuthResult.Verified.class,
            service.reverify(peer(), first.accessToken(), user.name(), user.phone(), user.code()));
    }

    /**
     * 교차 소유자 재확인이 다른 사용자 행까지 잠그며 교착되지 않는지 확인한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void crossedReverificationCompletes() throws Exception {
        Fixture other = prepareUser();
        AuthResult.Login first = signIn(user);
        AuthResult.Login second = signIn(other);
        InetAddress firstPeer = peer();
        InetAddress secondPeer = peer();
        CountDownLatch start = new CountDownLatch(1);
        try (var executor = Executors.newFixedThreadPool(2)) {
            Future<AuthResult> left = executor.submit(() -> {
                assertTrue(start.await(5, TimeUnit.SECONDS));
                return service.reverify(firstPeer, first.accessToken(), other.name(), other.phone(), other.code());
            });
            Future<AuthResult> right = executor.submit(() -> {
                assertTrue(start.await(5, TimeUnit.SECONDS));
                return service.reverify(secondPeer, second.accessToken(), user.name(), user.phone(), user.code());
            });
            start.countDown();
            failure(left.get(8, TimeUnit.SECONDS), AuthResult.Reason.AUTH_REJECTED);
            failure(right.get(8, TimeUnit.SECONDS), AuthResult.Reason.AUTH_REJECTED);
        }
        assertEquals(1, sessions(user, true));
        assertEquals(1, sessions(other, true));
    }

    /**
     * 로그아웃은 현재 세션만 끝내고 재시도는 무효 토큰이며 다음 로그인은 새 세션이다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void endsSessionAndAllowsNextLogin() throws Exception {
        AuthResult.Login first = signIn(user);
        assertEquals(AuthResult.LoggedOut.INSTANCE, service.logout(first.accessToken()));
        failure(service.logout(first.accessToken()), AuthResult.Reason.SESSION_INVALID);
        failure(service.reverify(peer(), first.accessToken(), user.name(), user.phone(), user.code()),
            AuthResult.Reason.SESSION_INVALID);
        assertEquals(0, sessions(user, true));
        AuthResult.Login next = signIn(user);
        assertNotEquals(first.sessionId(), next.sessionId());
        assertNotEquals(first.accessToken(), next.accessToken());
        assertEquals(2, sessions(user, false));
        assertEquals(1, sessions(user, true));
        assertEquals(0, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
    }

    /**
     * 코드 대조 실패 네 번과 이후 성공이 실패 창을 지우지 않음을 확인한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void keepsFailuresAcrossSuccessAndBlocksFifth() throws Exception {
        String wrong = user.code().equals("000000") ? "000001" : "000000";
        for (int index = 0; index < 4; index++) {
            failure(service.login(peer(), user.name(), user.phone(), wrong), AuthResult.Reason.AUTH_REJECTED);
        }
        AuthResult.Login result = signIn(user);
        assertEquals(4, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        AuthResult.Failure blocked = failure(service.reverify(peer(), result.accessToken(), user.name(), user.phone(), wrong),
            AuthResult.Reason.RATE_LIMITED);
        AuthResult.Failure repeated = failure(service.reverify(peer(), result.accessToken(), user.name(), user.phone(), user.code()),
            AuthResult.Reason.RATE_LIMITED);
        assertEquals(blocked.retryAt(), repeated.retryAt());
        assertEquals(5, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        assertEquals(1, sessions(user, true));
    }

    /**
     * 미등록 조합도 다섯 번째 실패부터 같은 제한으로 거절한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void limitsMissingAccount() throws Exception {
        String absentName = "없는" + user.name();
        for (int index = 1; index <= 5; index++) {
            failure(service.login(peer(), absentName, user.phone(), user.code()), index < 5
                ? AuthResult.Reason.AUTH_REJECTED : AuthResult.Reason.RATE_LIMITED);
        }
        assertEquals(0, sessions(user, false));
    }

    /**
     * 비활성 정확 자격은 실패를 늘리지 않고 DISABLED 코드는 인증 실패로 기록한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void distinguishesInactiveFromWrongCodeInternally() throws Exception {
        assertEquals(1, admin.update("""
            UPDATE payse.users
            SET deactivated_at=clock_timestamp(), purge_after=clock_timestamp()+interval '1 year'
            WHERE id=?
            """, user.id()));
        failure(service.login(peer(), user.name(), user.phone(), user.code()), AuthResult.Reason.AUTH_REJECTED);
        assertEquals(0, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        Fixture disabled = prepareUser();
        assertEquals(1, admin.update("UPDATE payse.users SET code_verifier=? WHERE id=?",
            "DISABLED:isolated-session-check", disabled.id()));
        failure(service.login(peer(), disabled.name(), disabled.phone(), disabled.code()), AuthResult.Reason.AUTH_REJECTED);
        assertEquals(1, events("combo", crypto.combinationLimitKey(disabled.name(), disabled.phone())));
        assertEquals(0, sessions(user, false));
        assertEquals(0, sessions(disabled, false));
    }

    /**
     * 형식 오류·본문 파싱 실패도 IP 사건으로 기록하고 61번째부터 제한한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void countsMalformedRequestsBeforeValidation() throws Exception {
        InetAddress address = peer();
        failure(service.login(address, null, null, null), AuthResult.Reason.INVALID_INPUT);
        for (int index = 1; index < 60; index++) {
            failure(service.rejectMalformed(address), AuthResult.Reason.INVALID_INPUT);
        }
        failure(service.login(address, user.name(), user.phone(), user.code()), AuthResult.Reason.RATE_LIMITED);
        assertEquals(60, events("ip", crypto.ipLimitKey(address)));
        assertEquals(0, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        assertEquals(0, sessions(user, false));
    }

    /**
     * IP·조합 차단이 겹치면 더 늦은 종료 시각을 반환하고 실패를 더 쌓지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void returnsLaterLimitWithoutCredentialWork() throws Exception {
        String wrong = user.code().equals("000000") ? "000001" : "000000";
        AuthResult.Failure blocked = null;
        for (int index = 0; index < 5; index++) {
            AuthResult result = service.login(peer(), user.name(), user.phone(), wrong);
            if (index == 4) blocked = failure(result, AuthResult.Reason.RATE_LIMITED);
        }
        InetAddress address = peer();
        for (int index = 0; index < 60; index++) service.rejectMalformed(address);
        AuthResult.Failure combined = failure(service.login(address, user.name(), user.phone(), user.code()),
            AuthResult.Reason.RATE_LIMITED);
        assertEquals(blocked.retryAt(), combined.retryAt());
        assertEquals(5, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        assertEquals(0, sessions(user, false));
    }

    /**
     * 코드 형식 오류로 이미 차단된 이름·전화번호 조합의 제한 시각을 축소하지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void keepsBlockedCombinationForMalformedCode() throws Exception {
        String wrong = user.code().equals("000000") ? "000001" : "000000";
        AuthResult.Failure blocked = null;
        for (int index = 0; index < 5; index++) {
            AuthResult result = service.login(peer(), user.name(), user.phone(), wrong);
            if (index == 4) blocked = failure(result, AuthResult.Reason.RATE_LIMITED);
        }
        AuthResult.Failure invalidCode = failure(service.login(peer(), user.name(), user.phone(), "bad"),
            AuthResult.Reason.RATE_LIMITED);
        AuthResult.Failure missingCode = failure(service.login(peer(), user.name(), user.phone(), null),
            AuthResult.Reason.RATE_LIMITED);
        assertEquals(blocked.retryAt(), invalidCode.retryAt());
        assertEquals(blocked.retryAt(), missingCode.retryAt());

        InetAddress address = peer();
        for (int index = 0; index < 60; index++) service.rejectMalformed(address);
        AuthResult.Failure combined = failure(service.login(address, user.name(), user.phone(), "bad"),
            AuthResult.Reason.RATE_LIMITED);
        assertEquals(blocked.retryAt(), combined.retryAt());
        assertEquals(60, events("ip", crypto.ipLimitKey(address)));
        assertEquals(5, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        assertEquals(0, sessions(user, false));
    }

    /**
     * 잘못된 토큰은 세션을 생성하거나 올바른 자격 실패 횟수를 증가시키지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void rejectsInvalidTokenWithoutCredentialFailure() throws Exception {
        InetAddress address = peer();
        failure(service.reverify(address, "invalid", user.name(), user.phone(), user.code()),
            AuthResult.Reason.SESSION_INVALID);
        failure(service.logout(null), AuthResult.Reason.SESSION_INVALID);
        assertEquals(1, events("ip", crypto.ipLimitKey(address)));
        assertEquals(0, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        assertEquals(0, sessions(user, false));
    }

    /**
     * runtime은 공개 인증 함수만 사용할 수 있고 세션을 직접 읽거나 수정하지 못한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void deniesDirectSessionAccess() {
        assertThrows(AuthStoreException.class, () -> transactions.run(() -> {
            jdbc.queryForList("SELECT token_digest FROM payse.demo_sessions");
            return null;
        }));
        assertThrows(AuthStoreException.class, () -> transactions.run(() -> {
            jdbc.update("UPDATE payse.demo_sessions SET ended_at=clock_timestamp() WHERE user_id=?", user.id());
            return null;
        }));
        assertNull(jdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
    }

    /**
     * 실제 커밋 단계의 지연 오류는 세션을 롤백하고 선행 IP 기록만 남긴다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void commitFailureRollsBackSessionButKeepsIp() throws Exception {
        String name = "session_fail_" + UUID.randomUUID().toString().replace("-", "");
        // 검사 UUID만 리터럴로 전달하며 함수/트리거는 이 폐기용 DB에서만 만들고 제거한다.
        admin.execute("""
            CREATE FUNCTION payse.%s()
            RETURNS trigger
            LANGUAGE plpgsql
            AS $$
            BEGIN
              IF NEW.user_id='%s'::uuid THEN
                RAISE EXCEPTION 'Intentional isolated commit failure' USING ERRCODE='23514';
              END IF;
              RETURN NEW;
            END $$
            """.formatted(name, user.id()));
        admin.execute("""
            CREATE CONSTRAINT TRIGGER %s
              AFTER INSERT ON payse.demo_sessions
              DEFERRABLE INITIALLY DEFERRED
              FOR EACH ROW EXECUTE FUNCTION payse.%s()
            """.formatted(name, name));
        InetAddress address = peer();
        try {
            AuthStoreException error = assertThrows(AuthStoreException.class,
                () -> service.login(address, user.name(), user.phone(), user.code()));
            assertNull(error.getCause());
            assertFalse(error.toString().contains(user.phone()));
            assertEquals(0, sessions(user, false));
            assertEquals(1, events("ip", crypto.ipLimitKey(address)));
            assertEquals(0, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
        } finally {
            admin.execute("DROP TRIGGER " + name + " ON payse.demo_sessions");
            admin.execute("DROP FUNCTION payse." + name + "()");
        }
        assertInstanceOf(AuthResult.Login.class,
            service.login(peer(), user.name(), user.phone(), user.code()));
    }

    /**
     * 사용자 잠금 대기 중 verifier가 바뀌면 이전 코드로 세션을 만들지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void rechecksCodeAfterUserLock() throws Exception {
        InetAddress address = peer();
        String replacement = user.code().equals("000000") ? "000001" : "000000";
        try (Connection blocker = adminPool.getConnection(); var executor = Executors.newSingleThreadExecutor()) {
            blocker.setAutoCommit(false);
            lockUser(blocker, user.id());
            Future<AuthResult> pending = executor.submit(
                () -> service.login(address, user.name(), user.phone(), user.code()));
            awaitLock();
            try (PreparedStatement statement = blocker.prepareStatement("UPDATE payse.users SET code_verifier=? WHERE id=?")) {
                statement.setString(1, crypto.codeVerifier(user.id(), replacement));
                statement.setObject(2, user.id());
                assertEquals(1, statement.executeUpdate());
            }
            blocker.commit();
            failure(pending.get(8, TimeUnit.SECONDS), AuthResult.Reason.AUTH_REJECTED);
        }
        assertEquals(0, sessions(user, false));
        assertEquals(1, events("combo", crypto.combinationLimitKey(user.name(), user.phone())));
    }

    /**
     * 재확인이 잠금을 기다리는 동안 먼저 확정된 로그아웃을 다시 읽어 거절한다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void reverifyObservesCommittedLogout() throws Exception {
        AuthResult.Login first = signIn(user);
        InetAddress address = peer();
        try (Connection blocker = adminPool.getConnection(); var executor = Executors.newSingleThreadExecutor()) {
            blocker.setAutoCommit(false);
            lockUser(blocker, user.id());
            Future<AuthResult> pending = executor.submit(
                () -> service.reverify(address, first.accessToken(), user.name(), user.phone(), user.code()));
            awaitLock();
            try (PreparedStatement statement = blocker.prepareStatement(
                    "UPDATE payse.demo_sessions SET ended_at=clock_timestamp() WHERE id=? AND user_id=?")) {
                statement.setObject(1, first.sessionId());
                statement.setObject(2, user.id());
                assertEquals(1, statement.executeUpdate());
            }
            blocker.commit();
            failure(pending.get(8, TimeUnit.SECONDS), AuthResult.Reason.SESSION_INVALID);
        }
        assertEquals(0, sessions(user, true));
    }

    /**
     * 두 로그아웃 요청은 한 번만 종료하고 나머지는 무효 세션으로 끝난다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void concurrentLogoutChangesOneSession() throws Exception {
        AuthResult.Login first = signIn(user);
        CountDownLatch start = new CountDownLatch(1);
        try (var executor = Executors.newFixedThreadPool(2)) {
            List<Future<AuthResult>> pending = new ArrayList<>();
            for (int index = 0; index < 2; index++) pending.add(executor.submit(() -> {
                assertTrue(start.await(5, TimeUnit.SECONDS));
                return service.logout(first.accessToken());
            }));
            start.countDown();
            int ended = 0;
            for (Future<AuthResult> future : pending) {
                AuthResult result = future.get(8, TimeUnit.SECONDS);
                if (result == AuthResult.LoggedOut.INSTANCE) ended++;
                else failure(result, AuthResult.Reason.SESSION_INVALID);
            }
            assertEquals(1, ended);
        }
        assertEquals(1, sessions(user, false));
        assertEquals(0, sessions(user, true));
    }

    /**
     * 연결 하나인 풀에서도 IP 커밋·반환 후 자격 처리가 진행되고 문맥이 남지 않는다.
     * @created 2026-10-26
     * @usedBy JUnit test
     */
    @Test
    void worksWithSingleConnection() throws Exception {
        try (HikariDataSource single = newPool(login, password, 1, application + "_single")) {
            JdbcTemplate singleJdbc = new JdbcTemplate(single);
            AuthService singleService = new AuthService(new AuthRepository(singleJdbc),
                new AuthTransactions(singleJdbc, new JdbcTransactionManager(single)), crypto);
            AuthResult.Login first = assertInstanceOf(AuthResult.Login.class,
                singleService.login(peer(), user.name(), user.phone(), user.code()));
            assertInstanceOf(AuthResult.Verified.class,
                singleService.reverify(peer(), first.accessToken(), user.name(), user.phone(), user.code()));
            assertEquals(AuthResult.LoggedOut.INSTANCE, singleService.logout(first.accessToken()));
            assertEquals(0, single.getHikariPoolMXBean().getActiveConnections());
            assertEquals(login, singleJdbc.queryForObject("SELECT current_user", String.class));
            assertNull(singleJdbc.queryForObject("SELECT NULLIF(current_setting('payse.user_id',true),'')", String.class));
        }
    }

    /**
     * 준비한 사용자 한 행을 잠그고 0건/복수 행을 본 경합 전에 거절한다.
     * @created 2026-10-26
     * @usedBy 실제 잠금 대기 검증
     * @param connection 준비 전용 연결
     * @param userId 준비 단계에서 얻은 사용자 ID
     */
    private void lockUser(Connection connection, UUID userId) throws Exception {
        try (PreparedStatement statement = connection.prepareStatement("SELECT id FROM payse.users WHERE id=? FOR UPDATE")) {
            statement.setObject(1, userId);
            try (var result = statement.executeQuery()) {
                assertTrue(result.next());
                assertEquals(userId, result.getObject(1, UUID.class));
                assertFalse(result.next());
            }
        }
    }

    /**
     * 대기 시간을 임의 추측하지 않고 실제 서비스 연결의 PostgreSQL Lock 상태를 관측한다.
     * @created 2026-10-26
     * @usedBy 실제 잠금 대기 검증
     */
    private void awaitLock() throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
        while (System.nanoTime() < deadline) {
            int waiting = admin.queryForObject("""
                SELECT count(*) FROM pg_stat_activity
                WHERE application_name=? AND wait_event_type='Lock'
                """, Integer.class, application);
            if (waiting > 0) return;
            Thread.sleep(10);
        }
        fail("Session operation did not enter the expected database lock wait");
    }
}
