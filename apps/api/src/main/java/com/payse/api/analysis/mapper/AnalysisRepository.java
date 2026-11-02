package com.payse.api.analysis.mapper;

import com.payse.api.analysis.service.AnalysisJson;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants.AnalysisDb;
import com.payse.api.constants.ApiMessageConstants.Analysis;
import com.payse.api.constants.ApiMessageConstants;
import jakarta.persistence.EntityManager;
import java.time.Instant;
import java.time.ZoneOffset;
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
     * 요청 저장기간의 메타만 집계해 목록 변경을 감지한다. 암호문·키·전체 본문은 읽지 않는다.
     * @created 2026-11-01
     * @usedBy MemoryCatalog.select
     * @param start 포함 시작 시각이며 null이면 시작 제한이 없다.
     * @param end 제외 끝 시각이며 null이면 끝 제한이 없다.
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public String memoryContext(UUID owner, Instant start, Instant end, Instant now) {
        requireOwner(owner);
        if (now == null || (start != null && end != null && !start.isBefore(end))) {
            throw new IllegalArgumentException(ApiMessageConstants.Analysis.INVALID_MEMORY_PERIOD);
        }

        String sql = """
            SELECT encode(sha256(convert_to(COALESCE(string_agg(
              jsonb_build_array(
                id, metadata_version, result_id, semantic_kind, memory_key, evidence_hash,
                stored_at, normal_expires_at, active, is_reference, important, reference_policy,
                deleted_at, purge_requested_at, source_refs, source_hash,
                ciphertext IS NOT NULL, crypto_meta IS NOT NULL,
                (NOT important AND normal_expires_at <= CAST(?2 AS timestamptz))
              )::text, E'\\n' ORDER BY id
            ), ''), 'UTF8')), 'hex')
            FROM payse.analysis_items
            WHERE user_id = ?1
            """ + memoryPeriod(start, end, 3);
        var query = entityManager.createNativeQuery(sql)
            .setParameter(1, owner)
            .setParameter(2, now.atOffset(ZoneOffset.UTC));
        int parameter = 3;
        if (start != null) {
            query.setParameter(parameter++, start.atOffset(ZoneOffset.UTC));
        }
        if (end != null) {
            query.setParameter(parameter, end.atOffset(ZoneOffset.UTC));
        }
        return ApiConfigConstants.Analysis.SHA256_PREFIX + query.getSingleResult();
    }

    /**
     * 사용자·기간·마지막 ID 뒤에서 최대 limit+1개만 읽는다. 금융 원천과 플래그를 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy MemoryCatalog.select
     * @param limit 공개 페이지 크기이며 추가 한 행은 다음 페이지 존재 확인용이다.
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public List<ObjectNode> memoryPage(
        UUID owner,
        Instant start,
        Instant end,
        UUID afterId,
        int limit
    ) {
        requireOwner(owner);
        if (limit < 1 || limit > 100 || (start != null && end != null && !start.isBefore(end))) {
            throw new IllegalArgumentException(ApiMessageConstants.Analysis.INVALID_MEMORY_PAGE);
        }

        String sql = """
            SELECT to_jsonb(memory)::text
            FROM payse.analysis_items memory
            WHERE user_id = ?1
            """ + memoryPeriod(start, end, 2);
        int parameter = 2;
        if (start != null) {
            parameter++;
        }
        if (end != null) {
            parameter++;
        }
        if (afterId != null) {
            sql += " AND id > ?" + parameter++;
        }
        sql += " ORDER BY id LIMIT ?" + parameter;
        var query = entityManager.createNativeQuery(sql).setParameter(1, owner);
        int value = 2;
        if (start != null) {
            query.setParameter(value++, start.atOffset(ZoneOffset.UTC));
        }
        if (end != null) {
            query.setParameter(value++, end.atOffset(ZoneOffset.UTC));
        }
        if (afterId != null) {
            query.setParameter(value++, afterId);
        }
        query.setParameter(value, limit + 1);
        List<ObjectNode> rows = new ArrayList<>();
        for (Object record : query.getResultList()) {
            rows.add((ObjectNode) AnalysisJson.JSON.readTree((String) record));
        }

        return List.copyOf(rows);
    }

    /**
     * 선택한 기간 경계만 바인딩 조건으로 만든다. 클라이언트 문자열을 SQL에 삽입하지 않는다.
     * @created 2026-11-01
     * @usedBy memoryContext, memoryPage
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private String memoryPeriod(Instant start, Instant end, int firstParameter) {
        StringBuilder predicate = new StringBuilder();
        int parameter = firstParameter;
        if (start != null) {
            predicate.append(" AND stored_at >= CAST(?")
                .append(parameter++)
                .append(" AS timestamptz)");
        }
        if (end != null) {
            predicate.append(" AND stored_at < CAST(?")
                .append(parameter)
                .append(" AS timestamptz)");
        }
        return predicate.toString();
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
     * @modified 2026-11-02 - 기억 관리의 불변 원천 참조·지문 저장 열을 보존
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
            "id user_id result_id item_key semantic_kind memory_key evidence_hash stored_at normal_expires_at ciphertext crypto_meta active is_reference important reference_policy metadata_version policy_version policy_actor deleted_at purge_requested_at source_refs source_hash"
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
