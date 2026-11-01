package com.payse.api.finance.mapper;

import com.payse.api.finance.entity.AllocationEntity;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.validation.FinancialInput;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 보호 설정의 명시 배정을 변경하며 지급 해제 이력은 수정하지 않는다.
 * @created 2026-10-29
 * @usedBy PlanWrites
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
 */
final class AllocationWrites {
    private final WriteStore store;

    /**
     * 부모 작업과 같은 JPA 저장 도구를 사용한다.
     * @created 2026-10-29
     * @usedBy PlanWrites
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    AllocationWrites(WriteStore store) { this.store = store; }

    /**
     * 명시한 배정 생성·총액 수정·제거를 적용한다. 호출자가 이후 한도 검사를 수행한다.
     * @created 2026-10-29
     * @usedBy PlanWrites.reserve
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void change(UUID owner, UUID reserveId, JsonNode changes, WriteStore.Journal journal) {
        for (JsonNode input : changes.get("create")) {
            UUID obligationId = FinancialInput.id(input.get("obligationId"));
            active(store.obligation(owner, obligationId));
            UUID id = UUID.randomUUID();
            store.persist(new AllocationEntity(id, owner, reserveId, obligationId, input.get("amountKRW").asLong()));
            journal.add("allocation", id, null, row(owner, id));
        }
        for (JsonNode input : changes.get("update")) {
            UUID id = FinancialInput.id(input.get("allocationId"));
            ObjectNode allocation = accessible(owner, id);
            if (!reserveId.equals(store.uuid(allocation, "reserve_id"))) throw WriteStore.conflict();
            active(store.obligation(owner, store.uuid(allocation, "obligation_id")));
            long amount = input.get("amountKRW").asLong();
            if (amount < allocation.get("released_krw").asLong()) throw WriteStore.history();
            store.entity(owner, AllocationEntity.class, id).changeAmount(amount);
            journal.add("allocation", id, allocation, row(owner, id));
        }
        for (JsonNode input : changes.get("remove")) {
            UUID id = FinancialInput.id(input);
            ObjectNode allocation = accessible(owner, id);
            if (!reserveId.equals(store.uuid(allocation, "reserve_id"))) throw WriteStore.conflict();
            if (allocation.get("released_krw").asLong() != 0 || !allocation.get("release_evidence").isEmpty()) throw WriteStore.history();
            store.remove(store.entity(owner, AllocationEntity.class, id));
            journal.add("allocation", id, allocation, null);
        }
    }

    /**
     * 취소 대상의 모든 미해제 배정과 확인 목록을 대조한 뒤 해당 미해제분만 제거한다.
     * @created 2026-10-29
     * @usedBy PlanWrites.cancel
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void detach(UUID owner, UUID target, boolean obligation, JsonNode entries, WriteStore.Journal journal) {
        String column = obligation ? "obligation_id" : "reserve_id";
        Map<UUID, Long> confirmed = new HashMap<>();
        for (JsonNode entry : entries) {
            UUID id = FinancialInput.id(entry.get("allocationId"));
            ObjectNode allocation = accessible(owner, id);
            if (!target.equals(store.uuid(allocation, column))) throw WriteStore.conflict();
            long remaining = allocation.get("amount_krw").asLong() - allocation.get("released_krw").asLong();
            if (entry.get("unreleasedKRW").asLong() != remaining || remaining <= 0) throw WriteStore.conflict();
            confirmed.put(id, remaining);
        }
        List<ObjectNode> actual = store.rows("""
            SELECT to_jsonb(a) FROM payse.reserve_allocations a
            WHERE a.user_id = ? AND a.%s = ? AND a.amount_krw > a.released_krw
            ORDER BY a.id
            """.formatted(column), owner, target);
        if (actual.size() != confirmed.size()
                || actual.stream().anyMatch(row -> !confirmed.containsKey(store.uuid(row, "id")))) throw WriteStore.conflict();
        for (ObjectNode allocation : actual) {
            UUID id = store.uuid(allocation, "id");
            long released = allocation.get("released_krw").asLong();
            if (released == 0) {
                store.remove(store.entity(owner, AllocationEntity.class, id));
                journal.add("allocation", id, allocation, null);
            } else {
                store.entity(owner, AllocationEntity.class, id).changeAmount(released);
                journal.add("allocation", id, allocation, row(owner, id));
            }
        }
    }

    /**
     * 기존 DELETE 경로에서는 미해제분이 하나라도 있으면 자동 해제하지 않고 거절한다.
     * @created 2026-10-29
     * @usedBy PlanWrites.cancel
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void requireDetached(UUID owner, UUID id, boolean obligation) {
        String column = obligation ? "obligation_id" : "reserve_id";
        Boolean remaining = store.scalar("""
            SELECT EXISTS (
                SELECT 1 FROM payse.reserve_allocations
                WHERE user_id = ? AND %s = ? AND amount_krw > released_krw
            )
            """.formatted(column), Boolean.class, owner, id);
        if (!Boolean.FALSE.equals(remaining)) throw WriteStore.conflict();
    }

    /**
     * 저장 후 의무·보호액별 미해제 합계를 검증한다. U 또는 미래 잔액은 계산하지 않는다.
     * @created 2026-10-29
     * @usedBy PlanWrites.reserve, obligation
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void limits(UUID owner) {
        Boolean exceeded = store.scalar("""
            SELECT EXISTS (
                SELECT 1 FROM payse.reserve_allocations a
                JOIN payse.reserves r ON r.user_id = a.user_id AND r.id = a.reserve_id
                WHERE a.user_id = ?
                GROUP BY r.id, r.amount_krw, r.cancelled_at
                HAVING sum(a.amount_krw - a.released_krw) > r.amount_krw
                    OR (r.cancelled_at IS NOT NULL AND sum(a.amount_krw - a.released_krw) > 0)
            ) OR EXISTS (
                SELECT 1 FROM payse.reserve_allocations a
                JOIN payse.obligations o ON o.user_id = a.user_id AND o.id = a.obligation_id
                WHERE a.user_id = ?
                GROUP BY o.user_id, o.id, o.amount_krw, o.status
                HAVING sum(a.amount_krw - a.released_krw) > o.amount_krw - coalesce((
                    SELECT sum(s.allocated_krw) FROM payse.settlement_links s
                    WHERE s.user_id = o.user_id AND s.obligation_id = o.id AND s.invalidated_at IS NULL
                ), 0) OR (o.status <> 'active' AND sum(a.amount_krw - a.released_krw) > 0)
            )
            """, Boolean.class, owner, owner);
        if (Boolean.TRUE.equals(exceeded)) throw new FinancialException(422, "LIMIT_EXCEEDED");
        if (exceeded == null) throw WriteStore.unavailable();
    }

    /**
     * 배정의 두 부모 접근 권한을 확인해 숨겨진 연결을 쓰기로 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy AllocationWrites.change, detach
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private ObjectNode accessible(UUID owner, UUID id) {
        ObjectNode allocation = row(owner, id);
        if (allocation == null) throw WriteStore.forbidden();
        store.reserve(owner, store.uuid(allocation, "reserve_id"));
        store.obligation(owner, store.uuid(allocation, "obligation_id"));
        return allocation;
    }

    /**
     * 배정 한 행을 같은 사용자 범위에서 조회한다.
     * @created 2026-10-29
     * @usedBy AllocationWrites
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private ObjectNode row(UUID owner, UUID id) {
        return store.row("SELECT to_jsonb(a) FROM payse.reserve_allocations a WHERE a.user_id = ? AND a.id = ?", owner, id);
    }

    /**
     * 취소된 의무에 새로운 미해제 배정을 만들지 않는다.
     * @created 2026-10-29
     * @usedBy AllocationWrites.change
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private void active(JsonNode obligation) {
        if (!"active".equals(obligation.get("status").asString())) throw WriteStore.conflict();
    }
}
