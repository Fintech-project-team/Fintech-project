package com.payse.api.auth.mapper;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.error.AuthStoreException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.EntityTransaction;
import jakarta.persistence.PersistenceException;
import jakarta.persistence.Query;
import jakarta.persistence.Tuple;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicBoolean;
import javax.sql.DataSource;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.aop.support.AopUtils;
import org.springframework.context.annotation.AnnotationConfigApplicationContext;
import org.springframework.dao.annotation.PersistenceExceptionTranslationPostProcessor;
import org.springframework.orm.jpa.EntityManagerFactoryInfo;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.orm.jpa.JpaTransactionManager;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;

/**
 * DB 결과 건수·타입·바인딩·오류 노출과 Spring 구성 경계를 검사한다. 실제 SQL 검사는 AuthJdbcTest가 담당한다.
 * @created 2026-10-25
 * @usedBy Gradle JUnit
 */
class AuthRepositoryTest {
    private DataSource dataSource;
    private EntityManager entityManager;
    private EntityManagerFactory factory;
    private EntityTransaction transaction;
    private AuthRepository repository;
    private EntityManagerHolder holder;
    private List<Map<String, Object>> rows;
    private List<String> statements;
    private List<List<Object>> bindings;

    /**
     * 행 매핑을 직접 실행하는 JPA 대역과 명시된 트랜잭션 문맥을 준비한다.
     * @created 2026-10-25
     * @usedBy JUnit BeforeEach
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @BeforeEach
    void prepare() {
        dataSource = mock(DataSource.class);
        factory = mock(EntityManagerFactory.class, withSettings().extraInterfaces(EntityManagerFactoryInfo.class));
        when(((EntityManagerFactoryInfo) factory).getDataSource()).thenReturn(dataSource);
        entityManager = mock(EntityManager.class);
        transaction = mock(EntityTransaction.class);
        when(entityManager.getEntityManagerFactory()).thenReturn(factory);
        when(entityManager.getDelegate()).thenReturn(entityManager);
        when(entityManager.isJoinedToTransaction()).thenReturn(true);
        when(entityManager.getTransaction()).thenReturn(transaction);
        when(transaction.isActive()).thenReturn(true);
        AtomicBoolean rollback = new AtomicBoolean();
        doAnswer(call -> { rollback.set(true); return null; }).when(transaction).setRollbackOnly();
        when(transaction.getRollbackOnly()).thenAnswer(call -> rollback.get());
        repository = new AuthRepository(entityManager);
        holder = new EntityManagerHolder(entityManager);
        TransactionSynchronizationManager.bindResource(factory, holder);
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
        rows = List.of();
        statements = new ArrayList<>();
        bindings = new ArrayList<>();
        when(entityManager.createNativeQuery(anyString(), eq(Tuple.class))).thenAnswer(call -> {
            statements.add(call.getArgument(0));
            List<Object> values = new ArrayList<>();
            bindings.add(values);
            Query query = mock(Query.class);
            when(query.setParameter(anyInt(), any())).thenAnswer(binding -> {
                int index = binding.getArgument(0);
                while (values.size() < index) values.add(null);
                values.set(index - 1, binding.getArgument(1));
                return query;
            });
            when(query.getResultList()).thenAnswer(result -> rows.stream().map(this::result).toList());
            return query;
        });
    }

    /**
     * 테스트가 연결한 스레드 문맥만 제거해 다음 검사에 전달하지 않는다.
     * @created 2026-10-25
     * @usedBy JUnit AfterEach
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @AfterEach
    void clearContext() {
        TransactionSynchronizationManager.unbindResourceIfPossible(factory);
        TransactionSynchronizationManager.clear();
    }

    /**
     * Tuple의 명시 타입 조회를 독립 행 값에 연결한다.
     * @created 2026-10-25
     * @usedBy AuthRepositoryTest.prepare의 Tuple 매핑
     * @param values 기대 형식의 필드 값 또는 잘못된 결과 시나리오
     * @return 실제 행 변환 코드를 실행할 대역
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @SuppressWarnings("unchecked")
    private Tuple result(Map<String, Object> values) {
        Tuple row = mock(Tuple.class);
        when(row.get(anyString(), any(Class.class))).thenAnswer(call -> {
            Class<?> type = call.getArgument(1);
            return type.cast(values.get(call.getArgument(0)));
        });
        when(row.get(anyString())).thenAnswer(call -> values.get(call.getArgument(0)));
        return row;
    }

    /**
     * nullable 시각을 포함하는 행을 만든다. 기대 시각은 구현에서 계산하지 않는다.
     * @created 2026-10-25
     * @usedBy 제한 결과 매핑 검사
     * @param retryAt 명시된 DB 시각 또는 SQL null
     * @return 단일 시각 행
     */
    private Map<String, Object> timeRow(OffsetDateTime retryAt) {
        Map<String, Object> row = new HashMap<>();
        row.put("retry_at", retryAt);
        return row;
    }

    /**
     * scalar 한 행의 null과 시간대가 있는 실제 시각을 구별하고 외부 입력을 바인딩한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @Test
    void preservesNullAndTimestampMapping() {
        String key = "key';SELECT pg_sleep(1);--";
        rows = List.of(timeRow(null));
        assertNull(repository.retryAt(key));
        assertEquals(List.of(key), bindings.getFirst());
        assertFalse(statements.getFirst().contains(key));
        OffsetDateTime stored = OffsetDateTime.of(2026, 10, 25, 12, 34, 56, 123456000, ZoneOffset.ofHours(9));
        rows = List.of(timeRow(stored));
        assertEquals(Instant.parse("2026-10-25T03:34:56.123456Z"), repository.recordFailure("f".repeat(64)));
        assertFalse(transaction.getRollbackOnly());
    }

    /**
     * IP 허용/재시도 조합과 0~1행 후보의 필드를 검증한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void mapsValidRowsAndEmptyCandidates() {
        Map<String, Object> allowed = timeRow(null);
        allowed.put("allowed", true);
        rows = List.of(allowed);
        assertTrue(repository.recordIp("a".repeat(64)).allowed());
        UUID user = UUID.randomUUID();
        rows = List.of(Map.of("user_id", user, "code_verifier", "DISABLED:private-marker"));
        var candidate = repository.findCode(" 데모알파 ", "010-1234-5678").orElseThrow();
        assertEquals(user, candidate.userId());
        assertFalse(candidate.toString().contains("private-marker"));
        assertEquals(List.of("데모알파", "01012345678"), bindings.getLast());
        UUID session = UUID.randomUUID();
        rows = List.of(Map.of("user_id", user, "session_id", session));
        assertEquals(new AuthRows.Session(user, session), repository.authorize("sha256:" + "b".repeat(64)).orElseThrow());
        rows = List.of();
        assertTrue(repository.findCode("데모알파", "01012345678").isEmpty());
        assertTrue(repository.authorize(null).isEmpty());
        assertEquals(1, bindings.getLast().size());
        assertNull(bindings.getLast().getFirst());
    }

    /**
     * 함수의 예상 건수가 틀리면 정상 부재/첫 행으로 축소하지 않고 롤백 표시한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @Test
    void rejectsMissingOrDuplicateRows() {
        assertThrows(AuthStoreException.class, () -> repository.retryAt("a".repeat(64)));
        assertTrue(transaction.getRollbackOnly());
        rows = List.of(timeRow(null), timeRow(null));
        assertThrows(AuthStoreException.class, () -> repository.recordFailure("b".repeat(64)));
        UUID user = UUID.randomUUID();
        Map<String, Object> stored = Map.of("user_id", user, "code_verifier", "DISABLED:unit");
        rows = List.of(stored, stored);
        assertThrows(AuthStoreException.class, () -> repository.findCode("데모알파", "01012345678"));
        rows = List.of(Map.of("user_id", user, "session_id", UUID.randomUUID()),
            Map.of("user_id", user, "session_id", UUID.randomUUID()));
        assertThrows(AuthStoreException.class, () -> repository.authorize("sha256:" + "c".repeat(64)));
    }

    /**
     * null 식별자·verifier·모순된 IP 결과를 저장 장애로 거절한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     */
    @Test
    void rejectsIncompleteOrContradictoryResults() {
        rows = List.of(Map.of("code_verifier", "DISABLED:unit"));
        assertThrows(AuthStoreException.class, () -> repository.findCode("데모알파", "01012345678"));
        rows = List.of(Map.of("user_id", UUID.randomUUID()));
        assertThrows(AuthStoreException.class, () -> repository.findCode("데모알파", "01012345678"));
        assertThrows(AuthStoreException.class, () -> repository.authorize("sha256:" + "d".repeat(64)));
        rows = List.of(Map.of("allowed", true, "retry_at", OffsetDateTime.now()));
        assertThrows(AuthStoreException.class, () -> repository.recordIp("e".repeat(64)));
        rows = List.of(Map.of("allowed", false));
        assertThrows(AuthStoreException.class, () -> repository.recordIp("f".repeat(64)));
        rows = List.of(timeRow(null));
        assertThrows(AuthStoreException.class, () -> repository.recordIp("a".repeat(64)));
    }

    /**
     * SQL·원인 메시지·민감 입력을 담은 원래 JPA 예외가 안전한 장애 밖으로 전달되지 않게 확인한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @Test
    @SuppressWarnings("unchecked")
    void sanitizesDatabaseFailureAndMarksRollback() {
        doThrow(new PersistenceException("SELECT credential=private-input",
            new IllegalStateException("secret-value")))
            .when(entityManager).createNativeQuery(anyString(), eq(Tuple.class));
        AuthStoreException failure = assertThrows(AuthStoreException.class, () -> repository.retryAt("a".repeat(64)));
        assertNull(failure.getCause());
        assertFalse(failure.toString().contains("private-input"));
        assertFalse(failure.toString().contains("secret-value"));
        assertTrue(transaction.getRollbackOnly());
    }

    /**
     * 같은 EntityManager·명시 격리·읽기/쓰기·실제 트랜잭션 조건이 모두 있어야 SQL에 도달한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @Test
    void rejectsIncompleteTransactionContext() {
        TransactionSynchronizationManager.setActualTransactionActive(false);
        assertThrows(IllegalStateException.class, () -> repository.retryAt("a".repeat(64)));
        TransactionSynchronizationManager.setActualTransactionActive(true);
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(true);
        assertThrows(IllegalStateException.class, () -> repository.retryAt("a".repeat(64)));
        TransactionSynchronizationManager.setCurrentTransactionReadOnly(false);
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(TransactionDefinition.ISOLATION_SERIALIZABLE);
        assertThrows(IllegalStateException.class, () -> repository.retryAt("a".repeat(64)));
        TransactionSynchronizationManager.setCurrentTransactionIsolationLevel(TransactionDefinition.ISOLATION_READ_COMMITTED);
        when(entityManager.isJoinedToTransaction()).thenReturn(false);
        assertThrows(IllegalStateException.class, () -> repository.retryAt("a".repeat(64)));
        when(entityManager.isJoinedToTransaction()).thenReturn(true);
        EntityManager other = mock(EntityManager.class);
        when(other.getDelegate()).thenReturn(other);
        TransactionSynchronizationManager.unbindResource(factory);
        TransactionSynchronizationManager.bindResource(factory, new EntityManagerHolder(other));
        assertThrows(IllegalStateException.class, () -> repository.retryAt("a".repeat(64)));
        TransactionSynchronizationManager.unbindResource(factory);
        assertThrows(IllegalStateException.class, () -> repository.retryAt("a".repeat(64)));
        assertTrue(statements.isEmpty());
    }

    /**
     * 빈/다른 EntityManagerFactory 구성과 외부 트랜잭션/연결 중첩을 새 연결 획득 전에 거절한다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @Test
    void rejectsInvalidConfigurationAndNestedWork() {
        assertThrows(IllegalArgumentException.class, () -> new AuthRepository(null));
        assertThrows(IllegalArgumentException.class, () -> new AuthRepository(mock(EntityManager.class)));
        assertThrows(IllegalArgumentException.class, () -> new AuthTransactions(entityManager, mock(PlatformTransactionManager.class)));
        assertThrows(IllegalArgumentException.class,
            () -> new AuthTransactions(entityManager, manager(mock(EntityManagerFactory.class))));
        JpaTransactionManager wrongSource = manager(factory);
        when(wrongSource.getDataSource()).thenReturn(mock(DataSource.class));
        assertThrows(IllegalArgumentException.class, () -> new AuthTransactions(entityManager, wrongSource));
        AuthTransactions transactions = new AuthTransactions(entityManager, manager(factory));
        assertThrows(IllegalArgumentException.class, () -> transactions.run(null));
        assertThrows(IllegalStateException.class, () -> transactions.run(() -> 1));
        TransactionSynchronizationManager.setActualTransactionActive(false);
        assertThrows(IllegalStateException.class, () -> transactions.run(() -> 1));
        TransactionSynchronizationManager.unbindResource(factory);
        TransactionSynchronizationManager.initSynchronization();
        assertThrows(IllegalStateException.class, () -> transactions.run(() -> 1));
        assertTrue(statements.isEmpty());
    }

    /**
     * 기본 프로필에는 DB bean이 생기지 않고 database 프로필에는 실제 Spring 예외변환 프록시로 등록된다.
     * @created 2026-10-25
     * @usedBy JUnit test
     * @modified 2026-10-29 - JPA 생성자·Tuple·실제 EntityTransaction 롤백 및 연결 문맥 검사
     */
    @Test
    void registersOnlyWithDatabaseProfile() {
        clearContext();
        try (AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext()) {
            context.register(AuthRepository.class, AuthTransactions.class);
            context.refresh();
            assertTrue(context.getBeansOfType(AuthRepository.class).isEmpty());
            assertTrue(context.getBeansOfType(AuthTransactions.class).isEmpty());
        }
        try (AnnotationConfigApplicationContext context = new AnnotationConfigApplicationContext()) {
            context.getEnvironment().setActiveProfiles("database");
            context.registerBean(EntityManager.class, () -> entityManager);
            context.registerBean(PlatformTransactionManager.class, () -> manager(factory));
            context.registerBean(PersistenceExceptionTranslationPostProcessor.class);
            context.register(AuthRepository.class, AuthTransactions.class);
            context.refresh();
            AuthRepository bean = context.getBean(AuthRepository.class);
            assertTrue(AopUtils.isAopProxy(bean), "Repository must work through Spring's actual exception-translation proxy");
            assertNotNull(context.getBean(AuthTransactions.class));
            assertThrows(IllegalStateException.class, () -> bean.retryAt("a".repeat(64)));
        }
    }

    /**
     * 생성자 검증 전용 JPA 관리자 대역을 같은 factory·DataSource에 연결한다.
     * @created 2026-10-29
     * @usedBy rejectsInvalidConfigurationAndNestedWork, registersOnlyWithDatabaseProfile
     */
    private JpaTransactionManager manager(EntityManagerFactory expectedFactory) {
        JpaTransactionManager manager = mock(JpaTransactionManager.class);
        when(manager.getEntityManagerFactory()).thenReturn(expectedFactory);
        when(manager.getDataSource()).thenReturn(dataSource);
        return manager;
    }
}
