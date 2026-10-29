package com.payse.api.finance.mapper;

import com.payse.api.finance.error.FinancialException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.EntityManagerFactory;
import jakarta.persistence.Query;
import jakarta.persistence.Tuple;
import jakarta.persistence.TupleElement;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.orm.jpa.EntityManagerHolder;
import org.springframework.orm.jpa.EntityManagerProxy;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 인증 트랜잭션의 DB 원천·사용자 설정을 공개 투영 전 내부 JSON으로 읽는다.
 * 계좌 금액·급여 일정은 계산하지 않으며 테스트 fixture를 런타임에서 읽지 않는다.
 * @created 2026-10-29
 * @usedBy FinancialService
 * @modified 2026-10-29 - 동일 인증 JPA 문맥의 native Tuple 조회로 전환
 */
@Repository
@Profile("database & auth & finance")
public class FinancialRepository {
    private static final Set<String> JSON_FIELDS = Set.of("coverage", "receiptEvidence", "occurrenceLinks",
        "scheduleEvidence", "releaseEvidence", "evidenceRefs", "cardPlans", "scheduleOverrides", "evidenceTransactionIds");
    private static final Set<String> DATE_FIELDS = Set.of("purchaseDate", "withdrawalDate", "refundDate",
        "cancellationDate", "bookingDate", "dueDate", "periodStart", "periodEnd");
    private static final Set<String> TIME_FIELDS = Set.of("asOf", "consentedAt", "disconnectedAt", "cancelledAt",
        "invalidatedAt", "occurredAt");
    private static final Set<String> INTEGER_FIELDS = Set.of("accountCount", "cardCount", "balanceKRW", "amountKRW",
        "installmentCurrent", "installmentTotal", "salaryDay", "salaryAmountKRW", "allocatedKRW", "releasedKRW", "monthlyDay");
    private static final Set<String> BOOLEAN_FIELDS = Set.of("included", "balanceReflected", "isCurrent");
    private static final Set<String> UUID_FIELDS = Set.of("userId", "linkId", "accountId", "cardId", "transactionId",
        "statementId", "obligationId", "reserveId", "allocationId", "planId", "recurringPlanId", "planRevisionId",
        "revisionId", "decisionId", "fromId", "toId", "withdrawalAccountId", "originalTransactionId", "salaryAccountId");
    private final EntityManager entityManager;
    private final EntityManagerFactory factory;
    private final JsonMapper mapper = JsonMapper.builder().build();

    /**
     * 인증 서비스와 같은 JPA 트랜잭션의 공유 EntityManager를 받는다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입
     * @modified 2026-10-29 - 인증과 조회가 같은 영속성 문맥을 사용하도록 생성자 변경
     */
    public FinancialRepository(EntityManager entityManager) {
        if (entityManager == null || entityManager.getEntityManagerFactory() == null) {
            throw new IllegalArgumentException("Financial EntityManager is required");
        }
        this.entityManager = entityManager;
        this.factory = entityManager.getEntityManagerFactory();
    }

    /**
     * 소유자 잠금 아래 테이블별 한 번의 조회로 완전한 내부 v3 원본을 조립한다.
     * 페이지와 기관별 공개 여부는 후속 투영에서 결정하고 여기서 원천을 누락하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialService
     * @param owner AuthRepository.authorize가 같은 트랜잭션에서 확정한 사용자
     * @return 현재 DB dataVersion과 변경하지 않은 원천 사실·설정
     */
    public ObjectNode load(UUID owner) throws IllegalStateException {
        requireOwner(owner);
        try {
            ObjectNode source = one("""
                SELECT u.id AS "userId", u.data_version::text AS "dataVersion",
                  s.source_version AS "sourceVersion", s.schema_version AS "schemaVersion",
                  s.rule_version AS "ruleVersion", s.as_of AS "asOf", s.coverage,
                  s.salary_evidence AS "receiptEvidence", s.occurrence_links AS "occurrenceLinks"
                FROM payse.users u
                JOIN payse.source_contexts s ON s.user_id = u.id
                WHERE u.id = ?
                """, owner);
            if (!"PAYSE-DRAFT-3".equals(source.path("schemaVersion").asText())) {
                throw unavailable();
            }
            source.put("currency", "KRW");
            source.set("institutions", institutions(owner));
            source.set("institutionLinks", rows("""
                SELECT id AS "linkId", user_id AS "userId", institution_code AS "institutionCode",
                  consented_at AS "consentedAt", disconnected_at AS "disconnectedAt"
                FROM payse.institution_links
                WHERE user_id = ?
                ORDER BY id
                """, owner));
            source.set("accounts", accounts(owner));
            source.set("cards", cards(owner));
            source.set("transactions", transactions(owner));
            source.set("statements", statements(owner));
            source.set("settings", settings(owner, source.remove("receiptEvidence")));
            source.set("obligations", obligations(owner));
            source.set("reserves", rows("""
                SELECT id AS "reserveId", user_id AS "userId", account_id AS "accountId",
                  label, amount_krw AS "amountKRW", cancelled_at AS "cancelledAt"
                FROM payse.reserves
                WHERE user_id = ?
                ORDER BY id
                """, owner));
            source.set("allocations", rows("""
                SELECT id AS "allocationId", user_id AS "userId", reserve_id AS "reserveId",
                  obligation_id AS "obligationId", amount_krw AS "amountKRW",
                  released_krw AS "releasedKRW", release_evidence AS "releaseEvidence"
                FROM payse.reserve_allocations
                WHERE user_id = ?
                ORDER BY id
                """, owner));
            source.set("settlements", rows("""
                SELECT id AS "linkId", user_id AS "userId", obligation_id AS "obligationId",
                  transaction_id AS "transactionId", allocated_krw AS "allocatedKRW", method,
                  evidence AS "evidenceRefs", invalidated_at AS "invalidatedAt"
                FROM payse.settlement_links
                WHERE user_id = ?
                ORDER BY id
                """, owner));
            recurring(source, owner);
            source.set("relatedTransactions", mapper.createArrayNode());
            source.set("referenceResolutions", rows("""
                SELECT transaction_id AS "transactionId", resolution AS status, reason
                FROM payse.transaction_references
                WHERE user_id = ? AND resolution = 'unavailable'
                ORDER BY transaction_id
                """, owner));
            source.set("transactionRelations", rows("""
                SELECT kind, from_id AS "fromId", to_id AS "toId", evidence_ref AS "evidenceRef"
                FROM payse.transaction_relations
                WHERE user_id = ?
                ORDER BY kind, from_id, to_id
                """, owner));
            ObjectNode page = source.putObject("page");
            page.putNull("nextCursor");
            page.set("dataVersion", source.get("dataVersion"));
            page.set("sourceVersion", source.get("sourceVersion"));
            return source;
        } catch (RuntimeException failure) {
            rollbackOnly();
            throw unavailable();
        }
    }

    /**
     * 해당 사용자가 실제 보유한 원천 계좌·카드의 기관과 개수만 제공한다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private ArrayNode institutions(UUID owner) {
        return rows("""
            WITH owned AS (
              SELECT institution_code, count(*) AS accounts, 0::bigint AS cards
              FROM payse.financial_accounts
              WHERE user_id = ?
              GROUP BY institution_code
              UNION ALL
              SELECT institution_code, 0::bigint, count(*)
              FROM payse.financial_cards
              WHERE user_id = ?
              GROUP BY institution_code
            )
            SELECT i.code, i.kind, i.name, sum(o.accounts)::bigint AS "accountCount",
              sum(o.cards)::bigint AS "cardCount"
            FROM owned o
            JOIN payse.institutions i ON i.code = o.institution_code
            GROUP BY i.code, i.kind, i.name
            ORDER BY i.code
            """, owner, owner);
    }

    /**
     * 계좌 원천과 사용자 선택·별칭을 각 컬럼의 권한 구분을 유지해 읽는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private ArrayNode accounts(UUID owner) {
        return rows("""
            SELECT id AS "accountId", user_id AS "userId", institution_code AS "institutionCode",
              source_ref AS "sourceRef", source_version AS "sourceVersion", product_type AS "productType",
              product_name AS "productName", masked_number AS "maskedNumber", balance_krw AS "balanceKRW",
              as_of AS "asOf", included, nickname
            FROM payse.financial_accounts
            WHERE user_id = ?
            ORDER BY id
            """, owner);
    }

    /**
     * 카드의 확인된 일정만 읽고 반복 규칙으로 새 예정일을 만들지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private ArrayNode cards(UUID owner) {
        return rows("""
            SELECT id AS "cardId", user_id AS "userId", institution_code AS "institutionCode",
              source_ref AS "sourceRef", source_version AS "sourceVersion", product_name AS "productName",
              masked_number AS "maskedNumber", card_type AS "cardType",
              withdrawal_account_id AS "withdrawalAccountId", schedule_evidence AS "scheduleEvidence"
            FROM payse.financial_cards
            WHERE user_id = ?
            ORDER BY id
            """, owner);
    }

    /**
     * 저장된 거래와 확인된 날짜를 읽고 단일 반영 상태에서 boolean 표현만 파생한다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private ArrayNode transactions(UUID owner) {
        return rows("""
            SELECT id AS "transactionId", user_id AS "userId", source_ref AS "sourceRef",
              source_version AS "sourceVersion", account_id AS "accountId", card_id AS "cardId",
              record_kind AS "recordKind", amount_krw AS "amountKRW", direction, status,
              merchant_name AS "merchantName", description, purchase_date AS "purchaseDate",
              withdrawal_date AS "withdrawalDate", refund_date AS "refundDate",
              cancellation_date AS "cancellationDate", booking_date AS "bookingDate",
              occurred_at AS "occurredAt", occurred_at_basis AS "occurredAtBasis",
              CASE reflection_reason WHEN 'reflected' THEN true
                WHEN 'not_reflected' THEN false ELSE NULL END AS "balanceReflected",
              reflection_reason AS "reflectionReason", original_transaction_id AS "originalTransactionId",
              payse_transaction_type AS "payseTransactionType", installment_current AS "installmentCurrent",
              installment_total AS "installmentTotal"
            FROM payse.financial_transactions
            WHERE user_id = ?
            ORDER BY id
            """, owner);
    }

    /**
     * 청구와 항목 연결을 각각 한 번 읽어 기존 v3 참조 배열만 조립한다.
     * v4 항목의 금액·회차를 변경하거나 기존 청구 금액에 더하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private ArrayNode statements(UUID owner) {
        ArrayNode statements = rows("""
            SELECT id AS "statementId", user_id AS "userId", source_ref AS "sourceRef",
              source_version AS "sourceVersion", card_id AS "cardId", amount_krw AS "amountKRW",
              due_date AS "dueDate", period_start AS "periodStart", period_end AS "periodEnd",
              detail_completeness AS "detailCompleteness"
            FROM payse.card_statements
            WHERE user_id = ?
            ORDER BY id
            """, owner);
        ArrayNode items = rows("""
            SELECT statement_id AS "statementId", transaction_id AS "transactionId"
            FROM payse.statement_items
            WHERE user_id = ?
            ORDER BY statement_id, id
            """, owner);
        Map<String, LinkedHashSet<String>> refs = new LinkedHashMap<>();
        for (JsonNode item : items) {
            if (!item.get("transactionId").isNull()) {
                refs.computeIfAbsent(item.path("statementId").asText(), ignored -> new LinkedHashSet<>())
                    .add(item.path("transactionId").asText());
            }
        }
        for (JsonNode value : statements) {
            ObjectNode statement = (ObjectNode) value;
            ArrayNode included = statement.putArray("includedTransactionRefs");
            for (String reference : refs.getOrDefault(statement.path("statementId").asText(), new LinkedHashSet<>())) {
                included.add(reference);
            }
        }
        return statements;
    }

    /**
     * 사용자 급여·카드 설정과 불변 급여 원천 근거를 분리해 기존 settings 구조로 옮긴다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private ObjectNode settings(UUID owner, JsonNode evidence) {
        ObjectNode salary = one("""
            SELECT salary_day AS "salaryDay", salary_amount_krw AS "salaryAmountKRW",
              salary_account_id AS "salaryAccountId", card_plan_overrides AS "cardPlans"
            FROM payse.user_attributes
            WHERE user_id = ?
            """, owner);
        ObjectNode settings = mapper.createObjectNode();
        settings.set("cardPlans", salary.remove("cardPlans"));
        salary.set("receiptEvidence", evidence);
        settings.set("salary", salary);
        return settings;
    }

    /**
     * 확정 의무를 읽고 저장된 명목 월로만 기존 회차 키를 복원한다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private ArrayNode obligations(UUID owner) {
        return rows("""
            SELECT id AS "obligationId", user_id AS "userId", label,
              withdrawal_account_id AS "withdrawalAccountId", amount_krw AS "amountKRW", due_date AS "dueDate",
              status, statement_id AS "statementId", plan_id AS "recurringPlanId",
              plan_revision_id AS "planRevisionId",
              CASE WHEN plan_id IS NULL THEN NULL
                ELSE plan_id::text || ':' || to_char(occurrence_month, 'YYYY-MM') END AS "recurrenceKey"
            FROM payse.obligations
            WHERE user_id = ?
            ORDER BY id
            """, owner);
    }

    /**
     * 반복 계획·고정 버전·회차 정정·사용자 판단 기록을 회차 생성 없이 전달한다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     */
    private void recurring(ObjectNode source, UUID owner) {
        source.set("recurringPlans", rows("""
            SELECT id AS "planId", user_id AS "userId",
              to_char(first_occurrence_month, 'YYYY-MM') AS "firstOccurrenceMonth"
            FROM payse.recurring_plans
            WHERE user_id = ?
            ORDER BY id
            """, owner));
        source.set("recurringPlanRevisions", rows("""
            SELECT id AS "revisionId", user_id AS "userId", plan_id AS "planId",
              to_char(effective_from_month, 'YYYY-MM') AS "effectiveFromMonth", label,
              amount_krw AS "amountKRW", monthly_day AS "monthlyDay", payment_timing AS "paymentTiming",
              schedule_basis AS "scheduleBasis", withdrawal_account_id AS "withdrawalAccountId",
              card_id AS "cardId", status, schedule_overrides AS "scheduleOverrides", is_current AS "isCurrent"
            FROM payse.recurring_plan_revisions
            WHERE user_id = ?
            ORDER BY plan_id, effective_from_month, id
            """, owner));
        source.set("recurringDecisions", rows("""
            SELECT id AS "decisionId", user_id AS "userId", candidate_key AS "candidateKey",
              rule_version AS "ruleVersion", source_version AS "sourceVersion", evidence_refs AS "evidenceTransactionIds",
              normalized_name AS "normalizedName", decision, plan_id AS "planId"
            FROM payse.recurring_decisions
            WHERE user_id = ?
            ORDER BY id
            """, owner));
        source.set("occurrenceOverrides", rows("""
            SELECT user_id AS "userId", plan_id::text || ':' || to_char(occurrence_month, 'YYYY-MM') AS "recurrenceKey",
              plan_revision_id AS "planRevisionId", amount_krw AS "amountKRW", due_date AS "dueDate",
              withdrawal_account_id AS "withdrawalAccountId", status
            FROM payse.occurrence_overrides
            WHERE user_id = ?
            ORDER BY plan_id, occurrence_month
            """, owner));
    }

    /**
     * 검토된 상수 SELECT와 바인딩된 소유자만 실행해 결과를 JSON 배열로 옮긴다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load, institutions, accounts, cards, transactions, statements, obligations, recurring, one
     * @modified 2026-10-29 - 상수 native SQL을 동일 EntityManager에서 바인딩 실행
     */
    private ArrayNode rows(String sql, Object... parameters) {
        Query query = entityManager.createNativeQuery(sql, Tuple.class);
        for (int index = 0; index < parameters.length; index++) query.setParameter(index + 1, parameters[index]);
        List<?> records = query.getResultList();
        ArrayNode result = mapper.createArrayNode();
        for (Object record : records) {
            if (!(record instanceof Tuple tuple)) throw unavailable();
            result.add(mapRow(tuple));
        }
        return result;
    }

    /**
     * 필수 사용자·컨텍스트·속성의 부재나 중복을 정상 빈 상태로 숨기지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load, settings
     */
    private ObjectNode one(String sql, UUID owner) {
        ArrayNode records = rows(sql, owner);
        if (records.size() != 1) throw unavailable();
        return (ObjectNode) records.get(0);
    }

    /**
     * 명시 SELECT 별칭의 Tuple 값을 공개 JSON 타입으로 옮기며 날짜에 시각을 생성하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.rows
     * @modified 2026-10-29 - JDBC 메타데이터 대신 계약별 별칭·Tuple 실제 타입 검증
     */
    private ObjectNode mapRow(Tuple row) {
        ObjectNode result = mapper.createObjectNode();
        Set<String> aliases = new HashSet<>();
        for (TupleElement<?> element : row.getElements()) {
            String field = element.getAlias();
            if (field == null || field.isBlank() || !aliases.add(field)) throw unavailable();
            Object value = row.get(field);
            if (value == null) {
                result.putNull(field);
            } else if (JSON_FIELDS.contains(field)) {
                result.set(field, json(value));
            } else if (DATE_FIELDS.contains(field)) {
                result.put(field, date(value).toString());
            } else if (TIME_FIELDS.contains(field)) {
                result.put(field, instant(value).toString());
            } else if (BOOLEAN_FIELDS.contains(field)) {
                if (!(value instanceof Boolean flag)) throw unavailable();
                result.put(field, flag);
            } else if (INTEGER_FIELDS.contains(field)) {
                if (!(value instanceof Number number)) throw unavailable();
                result.put(field, integer(number));
            } else if (UUID_FIELDS.contains(field)) {
                if (value instanceof UUID identifier) result.put(field, identifier.toString());
                else if (value instanceof String identifier && UUID.fromString(identifier).toString().equals(identifier)) {
                    result.put(field, identifier);
                } else throw unavailable();
            } else if (value instanceof String text) {
                result.put(field, text);
            } else {
                throw unavailable();
            }
        }
        return result;
    }

    /**
     * SQL jsonb 배열을 Hibernate 반환 타입과 무관하게 같은 JSON 값으로 읽는다.
     * JDBC 드라이버는 runtimeOnly이므로 PGobject는 클래스 식별 후 공개 문자열 표현만 읽는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.mapRow
     */
    private JsonNode json(Object value) {
        JsonNode result;
        if (value instanceof JsonNode node) {
            result = node.deepCopy();
        } else if (value instanceof String text) {
            result = mapper.readTree(text);
        } else if (value.getClass().getName().equals("org.postgresql.util.PGobject")) {
            result = mapper.readTree(value.toString());
        } else {
            throw unavailable();
        }
        if (result == null || !result.isArray()) throw unavailable();
        return result;
    }

    /**
     * PostgreSQL date는 날짜로만 보존하고 시각·시간대·문자열로 묵시 변환하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.mapRow
     */
    private LocalDate date(Object value) {
        if (value instanceof LocalDate date) return date;
        if (value instanceof java.sql.Date date) return date.toLocalDate();
        throw unavailable();
    }

    /**
     * timestamptz의 실제 순간을 기존 UTC 응답으로 유지하며 시간대 없는 시각을 추정하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.mapRow
     */
    private Instant instant(Object value) {
        if (value instanceof OffsetDateTime time) return time.toInstant();
        if (value instanceof Instant time) return time;
        if (value instanceof Timestamp time) return time.toInstant();
        throw unavailable();
    }

    /**
     * SQL 정수는 정확한 long만 허용하고 부동소수점·분수·범위 초과를 잘라내지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.mapRow
     */
    private long integer(Number value) {
        if (value instanceof Byte || value instanceof Short || value instanceof Integer || value instanceof Long) {
            return value.longValue();
        }
        if (value instanceof BigInteger integer) return integer.longValueExact();
        if (value instanceof BigDecimal decimal) return decimal.longValueExact();
        throw unavailable();
    }

    /**
     * 인증과 같은 연결·격리 수준·역할·사용자 문맥 없이 원천을 읽지 못하게 한다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     * @modified 2026-10-29 - 공유 EntityManager의 실제 트랜잭션 참여와 동일 RLS 문맥 확인
     */
    private void requireOwner(UUID owner) {
        if (owner == null || !TransactionSynchronizationManager.isActualTransactionActive()
                || !(TransactionSynchronizationManager.getResource(factory) instanceof EntityManagerHolder holder)
                || TransactionSynchronizationManager.isCurrentTransactionReadOnly()
                || !Integer.valueOf(TransactionDefinition.ISOLATION_READ_COMMITTED).equals(
                    TransactionSynchronizationManager.getCurrentTransactionIsolationLevel())
                || !entityManager.isJoinedToTransaction()) {
            throw new IllegalStateException("Financial read requires the authenticated transaction");
        }
        EntityManager currentManager = entityManager instanceof EntityManagerProxy proxy
            ? proxy.getTargetEntityManager() : entityManager;
        if (currentManager != holder.getEntityManager()) {
            throw new IllegalStateException("Financial read requires the same EntityManager");
        }
        Object current = entityManager.createNativeQuery("""
            SELECT CASE WHEN current_user = 'payse_runtime'
              THEN NULLIF(current_setting('payse.user_id', true), '')::uuid END
            """).getSingleResult();
        if (!owner.equals(current)) throw new IllegalStateException("Financial owner context does not match");
    }

    /**
     * 내부 실패를 호출부에서 잡아도 같은 트랜잭션에 성공 결과가 남지 않게 한다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load
     * @modified 2026-10-29 - 실제 EntityTransaction을 rollback-only로 표시하여 잡힌 오류의 커밋 차단
     */
    private void rollbackOnly() {
        Object resource = TransactionSynchronizationManager.getResource(factory);
        if (resource instanceof EntityManagerHolder holder && holder.getEntityManager().getTransaction().isActive()) {
            holder.getEntityManager().getTransaction().setRollbackOnly();
        }
    }

    /**
     * SQL·식별자·원문을 노출하지 않는 기존 서비스 장애를 만든다.
     * @created 2026-10-29
     * @usedBy FinancialRepository.load, one, mapRow
     */
    private FinancialException unavailable() {
        return new FinancialException(503, "TEMPORARILY_UNAVAILABLE");
    }
}
