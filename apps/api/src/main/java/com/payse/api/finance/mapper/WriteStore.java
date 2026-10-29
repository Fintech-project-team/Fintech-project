package com.payse.api.finance.mapper;

import com.payse.api.finance.entity.OwnedEntity;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.validation.FinancialInput;
import jakarta.persistence.EntityManager;
import jakarta.persistence.FlushModeType;
import jakarta.persistence.PersistenceException;
import jakarta.persistence.Query;
import java.sql.SQLException;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.orm.jpa.EntityManagerProxy;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 금융 설정 쓰기에 필요한 소유자 행 조회와 최소 변경 이력을 같은 연결에서 처리한다.
 * @created 2026-10-29
 * @usedBy FinancialWrites, SettingsWrites, PlanWrites, AllocationWrites
 * @modified 2026-10-29 - 관리 엔티티 쓰기·명시 flush와 같은 JPA 연결의 검증 조회로 전환
 */
final class WriteStore {
    final EntityManager entityManager;
    final JsonMapper mapper = JsonMapper.builder().build();

    /**
     * AuthTransactions와 같은 JPA 영속성 문맥을 보관한다.
     * @created 2026-10-29
     * @usedBy FinancialWrites
     * @modified 2026-10-29 - 같은 트랜잭션의 EntityManager 주입
     */
    WriteStore(EntityManager entityManager) { this.entityManager = entityManager; }

    /**
     * 호출자의 활성 트랜잭션과 RLS 문맥을 확인한다. 별도 사용자 문맥을 생성하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 트랜잭션·역할·격리 수준과 RLS 소유자 재검증
     */
    void requireOwner(UUID owner) {
        Object resource = TransactionSynchronizationManager.getResource(entityManager.getEntityManagerFactory());
        if (!TransactionSynchronizationManager.isActualTransactionActive()
                || TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !(resource instanceof EntityManagerHolder holder)
                || !entityManager.isJoinedToTransaction()) throw unavailable();
        EntityManager target = entityManager instanceof EntityManagerProxy proxy ? proxy.getTargetEntityManager() : entityManager;
        if (target != holder.getEntityManager()) throw unavailable();
        String current;
        try {
            current = (String) query("""
                SELECT current_setting('payse.user_id', true) || '|' || current_user || '|' ||
                       current_setting('transaction_isolation')
                """, String.class).getSingleResult();
        } catch (PersistenceException failure) { throw storageFailure(failure); }
        if (!(owner + "|payse_runtime|read committed").equals(current)) throw unavailable();
    }

    /**
     * 코드에서 정의한 단일 JSON 행 질의를 바인딩하며 예상하지 못한 중복은 실패시킨다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites, AllocationWrites
     */
    ObjectNode row(String sql, Object... arguments) {
        List<ObjectNode> rows = rows(sql, arguments);
        if (rows.size() > 1) throw unavailable();
        return rows.isEmpty() ? null : rows.getFirst();
    }

    /**
     * DB JSON 객체를 내부 검증 자료로 읽는다. 입력 SQL이나 원문을 예외에 넣지 않는다.
     * @created 2026-10-29
     * @usedBy WriteStore.row, SettingsWrites, PlanWrites, AllocationWrites
     * @modified 2026-10-29 - 관리 엔티티 변경을 flush한 뒤 JPA native query로 검증 자료 조회
     */
    List<ObjectNode> rows(String sql, Object... arguments) {
        flush();
        try {
            Query query = query("SELECT CAST(payse_row AS text) FROM (" + sql + ") AS payse_rows(payse_row)", String.class, arguments);
            List<?> records = query.getResultList();
            List<ObjectNode> result = new ArrayList<>();
            for (Object raw : records) {
                if (!(raw instanceof String text)) throw unavailable();
                JsonNode value = mapper.readTree(text);
                if (!(value instanceof ObjectNode object)) throw unavailable();
                result.add(object);
            }
            return List.copyOf(result);
        } catch (PersistenceException failure) { throw storageFailure(failure); }
    }

    /**
     * 복잡한 저장 한도·DB 시각은 같은 JPA 연결의 scalar 조회로 확인한다.
     * @created 2026-10-29
     * @usedBy WriteStore, PlanWrites, AllocationWrites, FinancialReceipts
     * @modified 2026-10-29 - 일반 DML 도우미를 제거하고 검증용 scalar 조회로 한정
     */
    <T> T scalar(String sql, Class<T> type, Object... arguments) {
        flush();
        try { return type.cast(query(sql, type, arguments).getSingleResult()); }
        catch (PersistenceException failure) { throw storageFailure(failure); }
    }

    /**
     * 실제 저장 행을 관리 엔티티로 조회하고 1차 캐시의 값도 소유자를 다시 확인한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites, AllocationWrites
     */
    <T extends OwnedEntity> T entity(UUID owner, Class<T> type, UUID id) {
        try {
            T value = entityManager.find(type, id);
            if (value == null || !owner.equals(value.userId())) throw unavailable();
            return value;
        } catch (PersistenceException failure) { throw storageFailure(failure); }
    }

    /**
     * 원천 열이 없는 새 설정 엔티티만 생성 대상으로 등록한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites, AllocationWrites, FinancialReceipts
     */
    void persist(OwnedEntity entity) {
        try { entityManager.persist(entity); }
        catch (PersistenceException failure) { throw storageFailure(failure); }
    }

    /**
     * 지급 해제 이력이 없다고 확인한 관리 배정만 제거한다.
     * @created 2026-10-29
     * @usedBy AllocationWrites
     */
    void remove(OwnedEntity entity) {
        try { entityManager.remove(entity); }
        catch (PersistenceException failure) { throw storageFailure(failure); }
    }

    /**
     * DB 검증과 감사 자료 재조회 전에 관리 엔티티의 변경 SQL을 명시적으로 실행한다.
     * @created 2026-10-29
     * @usedBy WriteStore, FinancialReceipts
     */
    void flush() {
        try { entityManager.flush(); }
        catch (PersistenceException failure) { throw storageFailure(failure); }
    }

    /**
     * 사용자 사건 시각을 같은 DB 트랜잭션의 시각으로 기록한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites
     */
    OffsetDateTime now() { return scalar("SELECT CURRENT_TIMESTAMP", OffsetDateTime.class); }

    /**
     * 코드에 고정된 SQL의 위치 매개변수만 바인딩한다. 입력을 SQL에 삽입하지 않는다.
     * @created 2026-10-29
     * @usedBy WriteStore.rows, scalar
     */
    private Query query(String sql, Class<?> type, Object... arguments) {
        StringBuilder numbered = new StringBuilder();
        int count = 0;
        for (int index = 0; index < sql.length(); index++) {
            char token = sql.charAt(index);
            if (token == '?') numbered.append('?').append(++count);
            else numbered.append(token);
        }
        if (count != arguments.length) throw unavailable();
        Query query = entityManager.createNativeQuery(numbered.toString(), type).setFlushMode(FlushModeType.COMMIT);
        for (int index = 0; index < arguments.length; index++) query.setParameter(index + 1, arguments[index]);
        return query;
    }

    /**
     * JPA 실패를 rollback-only로 남기고 SQL·원문을 노출하지 않는 기존 오류로 변환한다.
     * @created 2026-10-29
     * @usedBy WriteStore, FinancialReceipts
     */
    FinancialException storageFailure(PersistenceException failure) {
        Object resource = TransactionSynchronizationManager.getResource(entityManager.getEntityManagerFactory());
        if (resource instanceof EntityManagerHolder holder && holder.getEntityManager().getTransaction().isActive()) {
            holder.getEntityManager().getTransaction().setRollbackOnly();
        }
        for (Throwable cause = failure; cause != null; cause = cause.getCause()) {
            if (cause instanceof SQLException sql && sql.getSQLState() != null && sql.getSQLState().startsWith("23")) {
                return conflict();
            }
        }
        return unavailable();
    }

    /**
     * 현재 연결한 계좌만 반환하고 미존재·타 사용자·미연결을 같은 오류로 처리한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites
     */
    ObjectNode account(UUID owner, UUID id) {
        ObjectNode account = row("""
            SELECT to_jsonb(a)
            FROM payse.financial_accounts a
            WHERE a.user_id = ? AND a.id = ?
              AND EXISTS (
                  SELECT 1 FROM payse.institution_links l
                  WHERE l.user_id = a.user_id AND l.institution_code = a.institution_code
                    AND l.disconnected_at IS NULL
              )
            """, owner, id);
        if (account == null) throw forbidden();
        return account;
    }

    /**
     * 의무의 필수 계좌와 고정 계획 버전까지 공개 가능한지 검증한다.
     * @created 2026-10-29
     * @usedBy PlanWrites, AllocationWrites
     */
    ObjectNode obligation(UUID owner, UUID id) {
        ObjectNode obligation = row("""
            SELECT to_jsonb(o)
            FROM payse.obligations o
            WHERE o.user_id = ? AND o.id = ?
            """, owner, id);
        if (obligation == null) throw forbidden();
        account(owner, uuid(obligation, "withdrawal_account_id"));
        if (!obligation.get("plan_revision_id").isNull()) {
            ObjectNode revision = row("""
                SELECT to_jsonb(r)
                FROM payse.recurring_plan_revisions r
                WHERE r.user_id = ? AND r.id = ?
                """, owner, uuid(obligation, "plan_revision_id"));
            if (revision == null) throw unavailable();
            account(owner, uuid(revision, "withdrawal_account_id"));
        }
        return obligation;
    }

    /**
     * 보호 설정의 소유자와 주 계좌 연결을 확인한다.
     * @created 2026-10-29
     * @usedBy PlanWrites, AllocationWrites
     */
    ObjectNode reserve(UUID owner, UUID id) {
        ObjectNode reserve = row("SELECT to_jsonb(r) FROM payse.reserves r WHERE r.user_id = ? AND r.id = ?", owner, id);
        if (reserve == null) throw forbidden();
        account(owner, uuid(reserve, "account_id"));
        return reserve;
    }

    /**
     * DB UUID 문자열을 내부 식별자로 바꾼다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites, AllocationWrites
     */
    UUID uuid(JsonNode row, String key) {
        try { return FinancialInput.id(row.get(key)); }
        catch (FinancialException failure) { throw unavailable(); }
    }

    /**
     * 지정 필드만 감사 이력에 남겨 원천 전체 복제를 피한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites, AllocationWrites
     */
    ObjectNode select(JsonNode row, String... fields) {
        ObjectNode result = mapper.createObjectNode();
        for (String field : fields) result.set(field, row.get(field));
        return result;
    }

    /**
     * 공개 참조와 서버 전용 최소 변경 근거를 요청 단위로 모은다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     */
    Journal journal() { return new Journal(mapper); }

    /**
     * 없는 대상과 비공개 대상을 구별하지 않는 오류를 만든다.
     * @created 2026-10-29
     * @usedBy WriteStore, SettingsWrites, PlanWrites, AllocationWrites
     */
    static FinancialException forbidden() { return new FinancialException(403, "RESOURCE_FORBIDDEN"); }

    /**
     * 잘못된 저장 관계를 기존 409로 전달한다.
     * @created 2026-10-29
     * @usedBy PlanWrites, AllocationWrites
     */
    static FinancialException conflict() { return new FinancialException(409, "RELATION_CONFLICT"); }

    /**
     * 보존 중인 지급·원천 이력의 수정을 거절한다.
     * @created 2026-10-29
     * @usedBy PlanWrites, AllocationWrites
     */
    static FinancialException history() { return new FinancialException(409, "HISTORY_LOCKED"); }

    /**
     * 정상 입력 범위 또는 한도를 거절한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites, PlanWrites, AllocationWrites
     */
    static FinancialException invalid() { return new FinancialException(422, "VALIDATION_FAILED"); }

    /**
     * 내부 저장 불일치를 원문 없이 실패 처리한다.
     * @created 2026-10-29
     * @usedBy WriteStore, SettingsWrites, PlanWrites
     */
    static FinancialException unavailable() { return new FinancialException(503, "TEMPORARILY_UNAVAILABLE"); }

    /**
     * 요청 밖에 보존하지 않는 변경 목록이다. 금융 서비스가 영수증과 함께 커밋한다.
     * @created 2026-10-29
     * @usedBy FinancialWrites, SettingsWrites, PlanWrites, AllocationWrites
     */
    static final class Journal {
        final ArrayNode refs;
        final ObjectNode audit;
        private final ArrayNode changes;

        /**
         * 사용자 요청마다 독립된 변경 목록을 만든다.
         * @created 2026-10-29
         * @usedBy WriteStore.journal
         */
        Journal(JsonMapper mapper) {
            refs = mapper.createArrayNode();
            audit = mapper.createObjectNode();
            changes = audit.putArray("changes");
        }

        /**
         * 같은 값 재저장은 빈 변경 목록으로 유지하고 실제 변경만 최소 이력에 추가한다.
         * @created 2026-10-29
         * @usedBy SettingsWrites, PlanWrites, AllocationWrites
         */
        void add(String resource, UUID id, JsonNode before, JsonNode after) {
            if (before != null && before.equals(after)) return;
            refs.addObject().put("resource", resource).put("id", id.toString());
            ObjectNode change = changes.addObject().put("resource", resource).put("id", id.toString());
            if (before == null) change.putNull("before"); else change.set("before", before);
            if (after == null) change.putNull("after"); else change.set("after", after);
        }
    }
}
