package com.payse.api.analysis.mapper;

import com.payse.api.analysis.service.AnalysisJson;
import com.payse.api.constants.ApiFieldConstants.AnalysisDb;
import com.payse.api.constants.ApiMessageConstants.Analysis;
import jakarta.persistence.EntityManager;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import tools.jackson.databind.node.ObjectNode;

/**
 * 인증 JPA 트랜잭션 안에서 분석 전용 행을 읽고 쓴다. 금융 테이블을 변경하지 않는다.
 * @created 2026-11-01
 * @usedBy AnalysisJobs, AnalysisResults
 */
@Repository
@Profile(
    "database & auth & finance & analysis"
)
public class AnalysisRepository {

    private final EntityManager entityManager;

    /**
     * 기존 인증과 같은 공유 JPA 문맥을 사용한다.
     * @created 2026-11-01
     * @usedBy Spring 생성자 주입
     */
    public AnalysisRepository(EntityManager entityManager) {
        this.entityManager = entityManager;
    }

    /**
     * 명시한 사용자와 검증된 필드 조건으로만 조회한다. 조건값은 바인딩한다.
     * @created 2026-11-01
     * @usedBy one, AnalysisJobs, AnalysisResults
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public List<ObjectNode> find(Table table, UUID owner, Map<String, ?> filters) {
        requireOwner(owner);
        StringBuilder sql = new StringBuilder("SELECT to_jsonb(t)::text FROM payse.")
            .append(table.sqlName)
            .append(" t WHERE user_id = ?1");
        List<Object> values = new ArrayList<>();
        for (var filter : filters.entrySet()) {
            field(table, filter.getKey());
            sql.append(" AND ")
                .append(filter.getKey())
                .append(" = ?")
                .append(values.size() + 2);
            values.add(filter.getValue());
        }

        var query = entityManager.createNativeQuery(sql.toString()).setParameter(1, owner);
        for (int index = 0; index < values.size(); index++) {
            query.setParameter(index + 2, values.get(index));
        }

        List<ObjectNode> rows = new ArrayList<>();
        for (Object value : query.getResultList()) {
            rows.add((ObjectNode) AnalysisJson.JSON.readTree((String) value));
        }

        return rows;
    }

    /**
     * PK 조건이 여러 행을 반환하는 오류를 숨기지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    public Optional<ObjectNode> one(Table table, UUID owner, Map<String, ?> filters) {
        List<ObjectNode> rows = find(table, owner, filters);
        if (rows.size() > 1) {
            throw new IllegalStateException(Analysis.DUPLICATE_IDENTITY);
        }

        return rows.stream().findFirst();
    }

    /**
     * 요청 기억의 인덱스로 관련 결과 헤더만 찾는다. 모든 사용자 결과를 메모리로 읽지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisResults.select
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public List<ObjectNode> results(UUID owner, String kind, List<String> memoryKeys) {
        requireOwner(owner);
        if (memoryKeys.isEmpty()) {
            return List.of();
        }

        List<String> parameters = new ArrayList<>();
        for (int index = 0; index < memoryKeys.size(); index++) {
            parameters.add("?" + (index + 3));
        }

        String sql = "SELECT to_jsonb(r)::text FROM payse.analysis_results r"
            + " WHERE r.user_id = ?1 AND r.semantic_kind = ?2 AND EXISTS ("
            + "SELECT 1 FROM payse.analysis_items i WHERE i.user_id = r.user_id AND i.result_id = r.id"
            + " AND i.memory_key IN (" + String.join(", ", parameters)
            + ")) ORDER BY r.committed_at DESC";
        var query = entityManager.createNativeQuery(sql)
            .setParameter(1, owner)
            .setParameter(2, kind);
        for (int index = 0; index < memoryKeys.size(); index++) {
            query.setParameter(index + 3, memoryKeys.get(index));
        }

        List<ObjectNode> rows = new ArrayList<>();
        for (Object value : query.getResultList()) {
            rows.add((ObjectNode) AnalysisJson.JSON.readTree((String) value));
        }

        return rows;
    }

    /**
     * 요청한 기억들의 삭제 차단을 한 번에 읽어 항목마다 SQL을 실행하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisResults.select
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public List<ObjectNode> suppressions(UUID owner, String kind, List<String> memoryKeys) {
        requireOwner(owner);
        if (memoryKeys.isEmpty()) {
            return List.of();
        }

        List<String> parameters = new ArrayList<>();
        for (int index = 0; index < memoryKeys.size(); index++) {
            parameters.add("?" + (index + 3));
        }

        String sql = "SELECT to_jsonb(s)::text FROM payse.analysis_suppressions s"
            + " WHERE s.user_id = ?1 AND s.semantic_kind = ?2 AND s.memory_key IN ("
            + String.join(", ", parameters) + ")";
        var query = entityManager.createNativeQuery(sql)
            .setParameter(1, owner)
            .setParameter(2, kind);
        for (int index = 0; index < memoryKeys.size(); index++) {
            query.setParameter(index + 3, memoryKeys.get(index));
        }

        List<ObjectNode> rows = new ArrayList<>();
        for (Object value : query.getResultList()) {
            rows.add((ObjectNode) AnalysisJson.JSON.readTree((String) value));
        }

        return rows;
    }

    /**
     * 서버가 만든 행만 typed PostgreSQL record로 삽입한다. 본문을 SQL 문자열에 넣지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    public void insert(Table table, UUID owner, ObjectNode row) {
        requireOwner(owner);
        if (!owner.toString().equals(row.path(AnalysisDb.USER_ID).asString())) {
            throw new IllegalArgumentException(Analysis.OWNER_MISMATCH);
        }

        List<String> names = row.propertyNames()
            .stream()
            .sorted()
            .toList();
        names.forEach(name -> field(table, name));
        String columns = String.join(", ", names);
        String sql = "INSERT INTO payse." + table.sqlName + " (" + columns + ") SELECT " + columns
            + " FROM jsonb_populate_record(NULL::payse." + table.sqlName + ", CAST(?1 AS jsonb))";
        int count = entityManager.createNativeQuery(sql)
            .setParameter(1, row.toString())
            .executeUpdate();
        if (count != 1) {
            throw new IllegalStateException(Analysis.INSERT_FAILED);
        }
    }

    /**
     * 인증 사용자 행의 허용 변경 열만 갱신한다. 불변 열은 DB 열 권한에서도 차단한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    public void update(Table table, UUID owner, UUID id, ObjectNode changes) {
        requireOwner(owner);
        List<String> names = changes.propertyNames()
            .stream()
            .sorted()
            .toList();
        if (names.isEmpty()) {
            throw new IllegalArgumentException(Analysis.MISSING_CHANGES);
        }

        names.forEach(name -> field(table, name));
        if (names.stream().anyMatch(Set.of(AnalysisDb.USER_ID, AnalysisDb.ID)::contains)) {
            throw new IllegalArgumentException(Analysis.IMMUTABLE_IDENTITY);
        }

        List<String> updates = names.stream()
            .map(name -> name + " = p." + name)
            .toList();
        String assignments = String.join(", ", updates);
        String sql = "UPDATE payse." + table.sqlName + " t SET " + assignments
            + " FROM jsonb_populate_record(NULL::payse." + table.sqlName + ", CAST(?1 AS jsonb)) p"
            + " WHERE t.user_id = ?2 AND t.id = ?3";
        int count = entityManager.createNativeQuery(sql)
            .setParameter(1, changes.toString())
            .setParameter(2, owner)
            .setParameter(3, id)
            .executeUpdate();
        if (count != 1) {
            throw new IllegalStateException(Analysis.UPDATE_FAILED);
        }
    }

    /**
     * 전체 대기/실행 개수는 전용 함수에서 잠금 아래 확인하며 다른 사용자 정보는 읽지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public long[] capacity(UUID owner) {
        requireOwner(owner);
        Object[] row = (Object[]) entityManager
            .createNativeQuery("SELECT * FROM payse.analysis_capacity()")
            .getSingleResult();
        long[] counts = new long[row.length];
        for (int index = 0; index < row.length; index++) {
            counts[index] = ((Number) row[index]).longValue();
        }

        return counts;
    }

    /**
     * 문자열 테이블·열을 요청에서 받을 수 없게 고정 저장 사전만 허용한다.
     * @created 2026-11-01
     * @usedBy find, insert, update
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private void field(Table table, String name) {
        if (!table.columns.contains(name)) {
            throw new IllegalArgumentException(Analysis.UNKNOWN_COLUMN);
        }
    }

    /**
     * 인증 함수가 설정한 같은 JPA 연결·역할·사용자 문맥 없이 저장소를 호출하지 못한다.
     * @created 2026-11-01
     * @usedBy find, insert, update, capacity
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private void requireOwner(UUID owner) {
        if (owner == null || !TransactionSynchronizationManager.isActualTransactionActive()
            || !Integer.valueOf(TransactionDefinition.ISOLATION_READ_COMMITTED)
                .equals(TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())
            || !entityManager.isJoinedToTransaction()) {
            throw new IllegalStateException(Analysis.AUTH_TRANSACTION_REQUIRED);
        }

        Object identity = entityManager.createNativeQuery(
            """
            SELECT CASE WHEN current_user = 'payse_runtime'
              THEN NULLIF(current_setting('payse.user_id', true), '')::uuid END
            """
        ).getSingleResult();
        if (!owner.equals(identity)) {
            throw new IllegalStateException(Analysis.OWNER_MISMATCH);
        }
    }

    /**
     * 동적 SQL 식별자는 이 내부 목록으로만 생성하며 값은 항상 바인딩한다.
     * @created 2026-11-01
     * @usedBy AnalysisRepository, AnalysisJobs, AnalysisResults
     */
    public enum Table {
        JOBS(
            "analysis_jobs",
            "id user_id semantic_kind trigger_kind descriptor_hash input_hash accepted_at guard_expires_at state attempt_count selected_result_id canonical_job_id execution_session_id finished_at permit_expires_at permit_hash execution_expires_at detail"
        ),
        ATTEMPTS(
            "analysis_attempts",
            "id user_id job_id attempt_no dispatch_state created_at finished_at detail"
        ),
        COMMANDS(
            "analysis_commands",
            "user_id request_key operation request_hash job_id attempt_id item_id created_at expires_at"
        ),
        RESULTS(
            "analysis_results",
            "id user_id semantic_kind input_hash provenance accepted_manifest committed_at"
        ),
        ITEMS(
            "analysis_items",
            "id user_id result_id item_key semantic_kind memory_key evidence_hash stored_at normal_expires_at ciphertext crypto_meta active is_reference important reference_policy metadata_version policy_version policy_actor deleted_at purge_requested_at"
        ),
        SUPPRESSIONS(
            "analysis_suppressions",
            "user_id semantic_kind memory_key evidence_hash blocked_at"
        );

        private final String sqlName;
        private final Set<String> columns;

        /**
         * 고정 테이블과 열 목록만 보관한다.
         * @created 2026-11-01
         * @usedBy enum 초기화
         */
        Table(String sqlName, String columns) {
            this.sqlName = sqlName;
            this.columns = Set.of(columns.split(" "));
        }
    }
}
