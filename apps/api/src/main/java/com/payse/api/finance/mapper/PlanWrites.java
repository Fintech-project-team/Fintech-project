package com.payse.api.finance.mapper;

import com.payse.api.finance.entity.ObligationEntity;
import com.payse.api.finance.entity.ReserveEntity;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.validation.FinancialInput;
import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 단건 의무·저장된 개별 회차·보호 설정을 저장하고 지급 이력과 원천 청구를 보존한다.
 * @created 2026-10-29
 * @usedBy FinancialWrites
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
 */
final class PlanWrites {
    private final WriteStore store;
    private final AllocationWrites allocations;

    /**
     * 부모 설정과 배정을 동일 트랜잭션에서 처리할 저장 도구를 주입한다.
     * @created 2026-10-29
     * @usedBy FinancialWrites
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    PlanWrites(WriteStore store) {
        this.store = store;
        this.allocations = new AllocationWrites(store);
    }

    /**
     * 허용된 의무 필드만 생성·변경한다. 기존 계획·버전·회차 키와 정산 행은 유지한다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void obligation(UUID owner, UUID existingId, JsonNode body, WriteStore.Journal journal) {
        UUID id = existingId == null ? UUID.randomUUID() : existingId;
        ObjectNode before = existingId == null ? null : store.obligation(owner, id);
        if (before != null) mutableObligation(before, body);
        UUID account = body.has("withdrawalAccountId") ? FinancialInput.id(body.get("withdrawalAccountId"))
            : store.uuid(before, "withdrawal_account_id");
        store.account(owner, account);
        long amount = body.has("amountKRW") ? body.get("amountKRW").asLong() : before.get("amount_krw").asLong();
        String label = body.has("label") ? FinancialInput.trimLabel(body.get("label").asString()) : before.get("label").asString();
        LocalDate dueDate = LocalDate.parse(body.has("dueDate") ? body.get("dueDate").asString() : before.get("due_date").asString());
        long paid = before == null ? 0 : paid(owner, id);
        if (amount < paid || (paid > 0 && !account.equals(store.uuid(before, "withdrawal_account_id")))) throw WriteStore.history();
        if (before == null) {
            store.persist(new ObligationEntity(id, owner, label, account, amount, dueDate));
        } else if (!before.get("statement_id").isNull()) {
            store.entity(owner, ObligationEntity.class, id).rename(label);
        } else {
            store.entity(owner, ObligationEntity.class, id).change(label, account, amount, dueDate);
        }
        allocations.limits(owner);
        ObjectNode after = store.obligation(owner, id);
        journal.add("obligation", id, obligationFields(before), obligationFields(after));
    }

    /**
     * 보호 설정과 명시 배정을 원자 변경하고 신규·증액만 현재 잔액 상한을 적용한다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void reserve(UUID owner, UUID existingId, JsonNode body, WriteStore.Journal journal) {
        UUID id = existingId == null ? UUID.randomUUID() : existingId;
        ObjectNode before = existingId == null ? null : store.reserve(owner, id);
        if (before != null && !before.get("cancelled_at").isNull()) throw WriteStore.conflict();
        UUID account = body.has("accountId") ? FinancialInput.id(body.get("accountId")) : store.uuid(before, "account_id");
        ObjectNode accountRow = store.account(owner, account);
        long amount = body.has("amountKRW") ? body.get("amountKRW").asLong() : before.get("amount_krw").asLong();
        String label = body.has("label") ? FinancialInput.trimLabel(body.get("label").asString()) : before.get("label").asString();
        boolean increased = before == null || !account.equals(store.uuid(before, "account_id")) || amount > before.get("amount_krw").asLong();
        if (increased && !accountRow.get("included").asBoolean()) throw WriteStore.invalid();
        if (before == null) {
            store.persist(new ReserveEntity(id, owner, account, label, amount));
        } else {
            store.entity(owner, ReserveEntity.class, id).change(account, label, amount);
        }
        if (body.has("allocationChanges")) allocations.change(owner, id, body.get("allocationChanges"), journal);
        allocations.limits(owner);
        if (increased) reserveLimits(owner, account, accountRow.get("balance_krw").asLong());
        journal.add("reserve", id, reserveFields(before), reserveFields(store.reserve(owner, id)));
    }

    /**
     * 확인된 미해제 배정 목록과 대상 취소를 함께 처리하며 지급에 의한 해제로 기록하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void cancel(UUID owner, UUID id, boolean obligation, JsonNode body, boolean explicit, WriteStore.Journal journal) {
        ObjectNode before = obligation ? store.obligation(owner, id) : store.reserve(owner, id);
        if (obligation && (!before.get("statement_id").isNull() || paid(owner, id) > 0)) throw WriteStore.history();
        if (explicit) allocations.detach(owner, id, obligation, body.get("detachAllocations"), journal);
        else allocations.requireDetached(owner, id, obligation);
        if (obligation) {
            if ("active".equals(before.get("status").asString())) {
                store.entity(owner, ObligationEntity.class, id).cancel();
            }
            journal.add("obligation", id, obligationFields(before), obligationFields(store.obligation(owner, id)));
        } else {
            if (before.get("cancelled_at").isNull()) {
                store.entity(owner, ReserveEntity.class, id).cancel(store.now());
            }
            journal.add("reserve", id, reserveFields(before), reserveFields(store.reserve(owner, id)));
        }
    }

    /**
     * 보호 신규·증액의 계좌별 상한과 선택 계좌 전체 상한을 모두 검사한다.
     * @created 2026-10-29
     * @usedBy PlanWrites.reserve
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private void reserveLimits(UUID owner, UUID account, long balance) {
        BigDecimal perAccount = store.scalar("""
            SELECT coalesce(sum(amount_krw), 0) FROM payse.reserves
            WHERE user_id = ? AND account_id = ? AND cancelled_at IS NULL
            """, BigDecimal.class, owner, account);
        BigDecimal selectedBalance = store.scalar("""
            SELECT coalesce(sum(a.balance_krw), 0)
            FROM payse.financial_accounts a
            WHERE a.user_id = ? AND a.included AND EXISTS (
                SELECT 1 FROM payse.institution_links l
                WHERE l.user_id = a.user_id AND l.institution_code = a.institution_code
                  AND l.disconnected_at IS NULL
            )
            """, BigDecimal.class, owner);
        BigDecimal selectedReserve = store.scalar("""
            SELECT coalesce(sum(r.amount_krw), 0)
            FROM payse.reserves r
            JOIN payse.financial_accounts a ON a.user_id = r.user_id AND a.id = r.account_id
            WHERE r.user_id = ? AND r.cancelled_at IS NULL AND a.included AND EXISTS (
                SELECT 1 FROM payse.institution_links l
                WHERE l.user_id = a.user_id AND l.institution_code = a.institution_code
                  AND l.disconnected_at IS NULL
            )
            """, BigDecimal.class, owner);
        if (perAccount == null || selectedBalance == null || selectedReserve == null) throw WriteStore.unavailable();
        BigDecimal maximum = BigDecimal.valueOf(FinancialInput.MAX_MONEY);
        if (perAccount.compareTo(BigDecimal.valueOf(Math.max(0, balance))) > 0
                || selectedReserve.compareTo(selectedBalance.max(BigDecimal.ZERO)) > 0
                || perAccount.compareTo(maximum) > 0 || selectedReserve.compareTo(maximum) > 0
                || selectedBalance.abs().compareTo(maximum) > 0) throw new FinancialException(422, "LIMIT_EXCEEDED");
    }

    /**
     * 유효 지급액만 읽어 총 의무액·계좌·취소의 이력 보존 검증에 사용한다.
     * @created 2026-10-29
     * @usedBy PlanWrites.obligation, cancel
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private long paid(UUID owner, UUID id) {
        BigDecimal amount = store.scalar("""
            SELECT coalesce(sum(allocated_krw), 0) FROM payse.settlement_links
            WHERE user_id = ? AND obligation_id = ? AND invalidated_at IS NULL
            """, BigDecimal.class, owner, id);
        if (amount == null || amount.signum() < 0 || amount.compareTo(BigDecimal.valueOf(FinancialInput.MAX_MONEY)) > 0) throw WriteStore.unavailable();
        return amount.longValueExact();
    }

    /**
     * 원천 청구와 취소된 의무를 사용자 편집 대상으로 취급하지 않는다.
     * @created 2026-10-29
     * @usedBy PlanWrites.obligation
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private void mutableObligation(JsonNode obligation, JsonNode body) {
        if (!obligation.get("statement_id").isNull()
                && (body.has("amountKRW") || body.has("dueDate") || body.has("withdrawalAccountId"))) throw WriteStore.history();
        if (!"active".equals(obligation.get("status").asString())) throw WriteStore.conflict();
    }

    /**
     * 의무의 사용자 수정값만 감사 이력에 보관한다.
     * @created 2026-10-29
     * @usedBy PlanWrites.obligation, cancel
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private ObjectNode obligationFields(JsonNode row) {
        return row == null ? null : store.select(row, "label", "withdrawal_account_id", "amount_krw", "due_date", "status");
    }

    /**
     * 보호 설정의 사용자 수정값만 감사 이력에 보관한다.
     * @created 2026-10-29
     * @usedBy PlanWrites.reserve, cancel
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private ObjectNode reserveFields(JsonNode row) {
        return row == null ? null : store.select(row, "account_id", "label", "amount_krw", "cancelled_at");
    }
}
