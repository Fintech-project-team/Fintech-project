package com.payse.api.finance.mapper;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants.Finance;
import com.payse.api.constants.ApiFieldConstants.Recurring;
import com.payse.api.finance.entity.RecurringDecisionEntity;
import com.payse.api.finance.entity.RecurringPlanEntity;
import com.payse.api.finance.entity.RecurringRevisionEntity;
import com.payse.api.finance.validation.FinancialInput;
import com.payse.api.finance.validation.RecurringInput;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 같은 사용자 잠금·RLS 안에서 승인/제외와 월간 계획을 원자 저장한다.
 * @created 2026-11-04
 * @usedBy FinancialWrites
 */
final class RecurringWrites {
    private final WriteStore store;

    /**
     * 기존 금융 쓰기와 같은 연결·영속성 문맥을 사용한다.
     * @created 2026-11-04
     * @usedBy FinancialWrites
     */
    RecurringWrites(WriteStore store) {
        this.store = store;
    }

    /**
     * 원천·근거·중복을 확인한 뒤 사용자 입력만 저장한다. AI나 반복 계산을 호출하지 않는다.
     * @created 2026-11-04
     * @usedBy FinancialWrites.apply
     */
    void decide(UUID owner, ObjectNode body, WriteStore.Journal journal) {
        ObjectNode context = store.row("""
            SELECT jsonb_build_object('sourceVersion', source_version, 'asOf', as_of)
            FROM payse.source_contexts
            WHERE user_id = ?
            """, owner);
        if (context == null || !context.get(Recurring.SOURCE_VERSION)
            .equals(body.get(Recurring.SOURCE_VERSION))) {
            throw new com.payse.api.finance.error.FinancialException(
                409, ApiCodeConstants.Finance.STALE_DATA
            );
        }
        List<String> refs = new ArrayList<>();
        for (JsonNode value : body.get(Recurring.EVIDENCE_IDS)) {
            refs.add(FinancialInput.id(value).toString());
        }
        refs.sort(String::compareTo);
        String evidence = store.mapper.writeValueAsString(refs);
        ObjectNode previous = store.row("""
            SELECT jsonb_build_object('duplicate', EXISTS (
                SELECT 1 FROM payse.recurring_decisions d
                WHERE d.user_id = ? AND d.rule_version = ?
                  AND (d.candidate_key = ? OR (
                      d.evidence_refs @> CAST(? AS jsonb)
                      AND d.evidence_refs <@ CAST(? AS jsonb)))))
            """, owner, body.get(Finance.RULE_VERSION).asString(),
            body.get(Recurring.CANDIDATE_KEY).asString(), evidence, evidence);
        if (previous.path(Recurring.DUPLICATE).asBoolean()) {
            throw WriteStore.conflict();
        }
        boolean approved = ApiCodeConstants.Recurring.APPROVED.equals(
            body.get(Recurring.DECISION).asString()
        );
        String instrument = null;
        String kind = null;
        for (String ref : refs) {
            ObjectNode transaction = transaction(owner, UUID.fromString(ref), approved);
            String currentInstrument = transaction.get(Recurring.INSTRUMENT_ID).asString();
            String currentKind = transaction.get(Recurring.RECORD_KIND).asString();
            if (instrument != null && (!instrument.equals(currentInstrument)
                || !kind.equals(currentKind))) {
                throw WriteStore.conflict();
            }
            instrument = currentInstrument;
            kind = currentKind;
        }
        UUID planId = null;
        if (approved) {
            planId = approve(owner, body.get(Recurring.PLAN), context, kind, instrument, journal);
        }
        UUID decisionId = UUID.randomUUID();
        store.persist(new RecurringDecisionEntity(
            decisionId,
            owner,
            body.get(Recurring.CANDIDATE_KEY).asString(),
            body.get(Finance.RULE_VERSION).asString(),
            body.get(Recurring.SOURCE_VERSION).asString(),
            evidence,
            FinancialInput.trimLabel(body.get(Recurring.NAME).asString()),
            body.get(Recurring.DECISION).asString(),
            planId
        ));
        journal.add(
            ApiCodeConstants.Recurring.DECISION_RESOURCE,
            decisionId,
            null,
            body.deepCopy()
        );
    }

    /**
     * 현재 연결된 실제 근거만 허용하며 승인에는 출금/구매의 명시 원천 상태를 요구한다.
     * @created 2026-11-04
     * @usedBy decide
     */
    private ObjectNode transaction(UUID owner, UUID id, boolean approved) {
        ObjectNode row = store.row("""
            SELECT jsonb_build_object('instrumentId', coalesce(t.account_id, t.card_id),
                'recordKind', t.record_kind, 'eligible',
                t.direction = 'out' AND
                ((t.record_kind = 'account_entry' AND t.status = 'posted') OR
                 (t.record_kind = 'card_purchase' AND t.status IN ('approved', 'posted'))) AND
                coalesce(t.payse_transaction_type, '') NOT IN ('internal_transfer', 'card_payment') AND
                NOT EXISTS (SELECT 1 FROM payse.transaction_relations r
                    WHERE r.user_id = t.user_id AND r.kind = 'internal_transfer'
                      AND (r.from_id = t.id OR r.to_id = t.id)) AND
                NOT EXISTS (SELECT 1 FROM payse.financial_transactions reversal
                    WHERE reversal.user_id = t.user_id AND reversal.original_transaction_id = t.id
                      AND reversal.record_kind IN ('card_cancellation', 'card_refund')))
            FROM payse.financial_transactions t
            LEFT JOIN payse.financial_accounts a ON a.user_id = t.user_id AND a.id = t.account_id
            LEFT JOIN payse.financial_cards c ON c.user_id = t.user_id AND c.id = t.card_id
            WHERE t.user_id = ? AND t.id = ? AND EXISTS (
                SELECT 1 FROM payse.institution_links l WHERE l.user_id = t.user_id
                  AND l.institution_code = coalesce(a.institution_code, c.institution_code)
                  AND l.disconnected_at IS NULL)
            """, owner, id);
        if (row == null) {
            throw WriteStore.forbidden();
        }
        if (approved && !row.path(Recurring.ELIGIBLE).asBoolean()) {
            throw WriteStore.conflict();
        }
        return row;
    }

    /**
     * 사용자 확인 계획의 시작 월·계좌·카드 관계만 검사하고 첫 버전을 함께 저장한다.
     * @created 2026-11-04
     * @usedBy decide
     */
    private UUID approve(
        UUID owner,
        JsonNode plan,
        ObjectNode context,
        String kind,
        String instrument,
        WriteStore.Journal journal
    ) {
        YearMonth first = RecurringInput.month(plan.get(Recurring.FIRST_MONTH));
        var asOf = OffsetDateTime.parse(context.get(Recurring.AS_OF).asString())
            .atZoneSameInstant(ZoneId.of(ApiConfigConstants.Finance.SEOUL_ZONE));
        if (first.isBefore(YearMonth.from(asOf))) {
            throw WriteStore.conflict();
        }
        UUID account = FinancialInput.id(plan.get(Finance.WITHDRAWAL_ACCOUNT_ID));
        store.account(owner, account);
        UUID card = plan.get(Recurring.CARD_ID).isNull() ? null
            : FinancialInput.id(plan.get(Recurring.CARD_ID));
        if (card == null) {
            if (!ApiCodeConstants.Finance.ACCOUNT_ENTRY.equals(kind)
                || !account.toString().equals(instrument)) {
                throw WriteStore.conflict();
            }
        } else {
            ObjectNode sourceCard = store.row("""
                SELECT jsonb_build_object('withdrawalAccountId', c.withdrawal_account_id,
                    'cardType', c.card_type)
                FROM payse.financial_cards c
                WHERE c.user_id = ? AND c.id = ? AND EXISTS (
                    SELECT 1 FROM payse.institution_links l WHERE l.user_id = c.user_id
                      AND l.institution_code = c.institution_code AND l.disconnected_at IS NULL)
                """, owner, card);
            if (sourceCard == null) {
                throw WriteStore.forbidden();
            }
            if (!ApiCodeConstants.Finance.CARD_PURCHASE.equals(kind)
                || !card.toString().equals(instrument)
                || !ApiCodeConstants.Recurring.CREDIT.equals(
                    sourceCard.path(Recurring.CARD_TYPE).asString())
                || !sourceCard.path(Finance.WITHDRAWAL_ACCOUNT_ID).asString("")
                    .equals(account.toString())) {
                throw WriteStore.conflict();
            }
        }
        UUID planId = UUID.randomUUID();
        UUID revision = UUID.randomUUID();
        store.persist(new RecurringPlanEntity(planId, owner, first.atDay(1)));
        store.persist(new RecurringRevisionEntity(
            revision,
            owner,
            planId,
            first.atDay(1),
            FinancialInput.trimLabel(plan.get(Finance.LABEL).asString()),
            plan.get(Finance.AMOUNT_KRW).asLong(),
            plan.get(Recurring.MONTHLY_DAY).asInt(),
            plan.get(Recurring.PAYMENT_TIMING).asString(),
            plan.get(Recurring.SCHEDULE_BASIS).asString(),
            account,
            card
        ));
        journal.add(ApiCodeConstants.Recurring.PLAN_RESOURCE, planId, null, plan.deepCopy());
        journal.add(ApiCodeConstants.Recurring.REVISION_RESOURCE, revision, null, plan.deepCopy());
        return planId;
    }
}
