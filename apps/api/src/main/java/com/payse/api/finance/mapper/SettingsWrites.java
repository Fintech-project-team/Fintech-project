package com.payse.api.finance.mapper;

import com.payse.api.finance.entity.AccountEntity;
import com.payse.api.finance.entity.InstitutionLinkEntity;
import com.payse.api.finance.entity.UserSettingsEntity;
import com.payse.api.finance.validation.FinancialInput;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 기관 동의와 사용자 계좌·급여·카드 설정만 수정하며 금융 원천은 유지한다.
 * @created 2026-10-29
 * @usedBy FinancialWrites
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
 */
final class SettingsWrites {
    private final WriteStore store;

    /**
     * 요청 트랜잭션에서 사용하는 공통 저장 도구를 주입한다.
     * @created 2026-10-29
     * @usedBy FinancialWrites
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    SettingsWrites(WriteStore store) { this.store = store; }

    /**
     * 제공 기관 중 최종 동의 집합을 저장한다. 해제된 기관의 설정·원천은 삭제하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void link(UUID owner, JsonNode body, WriteStore.Journal journal) {
        Set<String> requested = new HashSet<>();
        body.get("institutionCodes").forEach(code -> requested.add(code.asString()));
        List<ObjectNode> offered = store.rows("""
            SELECT jsonb_build_object('code', i.code, 'has_accounts', EXISTS (
                SELECT 1 FROM payse.financial_accounts a
                WHERE a.user_id = ? AND a.institution_code = i.code
            ))
            FROM payse.institutions i
            WHERE EXISTS (
                SELECT 1 FROM payse.financial_accounts a WHERE a.user_id = ? AND a.institution_code = i.code
            ) OR EXISTS (
                SELECT 1 FROM payse.financial_cards c WHERE c.user_id = ? AND c.institution_code = i.code
            )
            """, owner, owner, owner);
        Map<String, Boolean> accounts = new HashMap<>();
        offered.forEach(row -> accounts.put(row.get("code").asString(), row.get("has_accounts").asBoolean()));
        if (!accounts.keySet().containsAll(requested)) throw WriteStore.forbidden();
        if (requested.stream().noneMatch(code -> Boolean.TRUE.equals(accounts.get(code)))) throw WriteStore.invalid();
        Map<String, ObjectNode> previous = new HashMap<>();
        for (ObjectNode link : store.rows("""
                SELECT to_jsonb(l) FROM payse.institution_links l
                WHERE l.user_id = ? AND l.disconnected_at IS NULL
                """, owner)) {
            if (previous.put(link.get("institution_code").asString(), link) != null) throw WriteStore.unavailable();
        }
        for (ObjectNode link : previous.values()) {
            if (requested.contains(link.get("institution_code").asString())) continue;
            UUID id = store.uuid(link, "id");
            store.entity(owner, InstitutionLinkEntity.class, id).disconnect(store.now());
            journal.add("institutionLink", id, link, linkRow(owner, id));
            for (ObjectNode account : store.rows("""
                    SELECT jsonb_build_object('id', a.id, 'included', a.included)
                    FROM payse.financial_accounts a
                    WHERE a.user_id = ? AND a.institution_code = ? AND a.included
                    """, owner, link.get("institution_code").asString())) {
                UUID accountId = store.uuid(account, "id");
                store.entity(owner, AccountEntity.class, accountId).select(false);
                journal.add("account", accountId, account, account.deepCopy().put("included", false));
            }
        }
        for (JsonNode code : body.get("institutionCodes")) {
            if (previous.containsKey(code.asString())) continue;
            UUID id = UUID.randomUUID();
            store.persist(new InstitutionLinkEntity(id, owner, code.asString(), store.now()));
            journal.add("institutionLink", id, null, linkRow(owner, id));
        }
    }

    /**
     * 연결된 계좌의 전체 선택 집합만 바꾸고 숨겨진 계좌의 설정은 보존한다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void selection(UUID owner, JsonNode body, WriteStore.Journal journal) {
        Set<UUID> requested = new HashSet<>();
        for (JsonNode value : body.get("accountIds")) {
            UUID id = FinancialInput.id(value);
            store.account(owner, id);
            requested.add(id);
        }
        for (ObjectNode account : store.rows("""
                SELECT jsonb_build_object('id', a.id, 'included', a.included, 'nickname', a.nickname)
                FROM payse.financial_accounts a
                WHERE a.user_id = ? AND EXISTS (
                    SELECT 1 FROM payse.institution_links l
                    WHERE l.user_id = a.user_id AND l.institution_code = a.institution_code
                      AND l.disconnected_at IS NULL
                )
                """, owner)) {
            UUID id = store.uuid(account, "id");
            boolean included = requested.contains(id);
            if (included == account.get("included").asBoolean()) continue;
            store.entity(owner, AccountEntity.class, id).select(included);
            ObjectNode after = account.deepCopy().put("included", included);
            journal.add("account", id, account, after);
        }
    }

    /**
     * 별칭만 정리해 저장한다. 같은 원천 상품명·잔액은 쓰기 대상이 아니다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void nickname(UUID owner, UUID id, JsonNode body, WriteStore.Journal journal) {
        ObjectNode account = store.account(owner, id);
        String nickname = body.get("nickname").isNull() ? null : FinancialInput.trimLabel(body.get("nickname").asString());
        ObjectNode before = store.select(account, "nickname");
        ObjectNode after = store.mapper.createObjectNode().put("nickname", nickname);
        if (!before.equals(after)) {
            store.entity(owner, AccountEntity.class, id).rename(nickname);
        }
        journal.add("account", id, before, after);
    }

    /**
     * 사용자 급여 속성과 카드 override만 바꾼다. source_contexts.salary_evidence는 건드리지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialWrites.apply
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    void settings(UUID owner, JsonNode body, WriteStore.Journal journal) {
        ObjectNode before = store.row("SELECT to_jsonb(s) FROM payse.user_attributes s WHERE s.user_id = ?", owner);
        if (before == null) throw WriteStore.unavailable();
        ObjectNode after = before.deepCopy();
        if (body.has("salary")) {
            JsonNode salary = body.get("salary");
            if (salary.has("salaryAccountId") && !salary.get("salaryAccountId").isNull()) {
                ObjectNode account = store.account(owner, FinancialInput.id(salary.get("salaryAccountId")));
                if (!account.get("included").asBoolean()) throw WriteStore.invalid();
            }
            copy(salary, "salaryDay", after, "salary_day");
            copy(salary, "salaryAmountKRW", after, "salary_amount_krw");
            copy(salary, "salaryAccountId", after, "salary_account_id");
        }
        if (body.has("cardPlans")) after.set("card_plan_overrides", cards(owner, before.get("card_plan_overrides"), body.get("cardPlans")));
        if (!before.equals(after)) {
            store.entity(owner, UserSettingsEntity.class, owner).change(
                after.get("salary_day").isNull() ? null : after.get("salary_day").asInt(),
                nullableLong(after.get("salary_amount_krw")),
                after.get("salary_account_id").isNull() ? null : store.uuid(after, "salary_account_id"),
                after.get("card_plan_overrides").toString());
        }
        journal.add("settings", owner, before, after);
    }

    /**
     * 카드 설정을 ID별로 병합하며 명시 null은 해당 사용자 override를 제거한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites.settings
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private ArrayNode cards(UUID owner, JsonNode previous, JsonNode changes) {
        Map<UUID, JsonNode> plans = new LinkedHashMap<>();
        for (JsonNode plan : previous) {
            if (plans.put(store.uuid(plan, "cardId"), plan) != null) throw WriteStore.unavailable();
        }
        for (JsonNode plan : changes) {
            UUID id = FinancialInput.id(plan.get("cardId"));
            ObjectNode card = store.row("""
                SELECT jsonb_build_object('id', c.id)
                FROM payse.financial_cards c
                WHERE c.user_id = ? AND c.id = ? AND EXISTS (
                    SELECT 1 FROM payse.institution_links l
                    WHERE l.user_id = c.user_id AND l.institution_code = c.institution_code
                      AND l.disconnected_at IS NULL
                )
                """, owner, id);
            if (card == null) throw WriteStore.forbidden();
            if (plan.get("plannedPaymentDay").isNull()) plans.remove(id);
            else plans.put(id, ((ObjectNode) plan.deepCopy()).put("cardId", id.toString()));
        }
        ArrayNode result = store.mapper.createArrayNode();
        plans.values().forEach(result::add);
        return result;
    }

    /**
     * 사용자 설정의 생략은 유지하고 명시 null만 초기화한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites.settings
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private void copy(JsonNode patch, String field, ObjectNode target, String column) {
        if (patch.has(field)) target.set(column, patch.get(field));
    }

    /**
     * 이미 검증한 nullable 정수를 JDBC 값으로 전달한다.
     * @created 2026-10-29
     * @usedBy SettingsWrites.settings
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private Long nullableLong(JsonNode value) { return value.isNull() ? null : value.asLong(); }

    /**
     * 한 연결 변경의 최소 저장 기록을 다시 읽는다.
     * @created 2026-10-29
     * @usedBy SettingsWrites.link
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    private ObjectNode linkRow(UUID owner, UUID id) {
        ObjectNode row = store.row("SELECT to_jsonb(l) FROM payse.institution_links l WHERE l.user_id = ? AND l.id = ?", owner, id);
        if (row == null) throw WriteStore.unavailable();
        return row;
    }
}
