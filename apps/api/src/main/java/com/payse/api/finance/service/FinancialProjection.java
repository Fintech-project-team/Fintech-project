package com.payse.api.finance.service;

import com.payse.api.finance.dto.PageSlice;
import com.payse.api.finance.error.FinancialException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * 저장 원천을 변경하지 않고 기관 권한과 해당 버전의 공개 관계를 요청별로 투영한다.
 * @created 2026-10-29
 * @usedBy FinancialService
 */
public final class FinancialProjection {
    private static final List<String> HEADERS = List.of("userId", "schemaVersion", "currency",
        "dataVersion", "sourceVersion", "ruleVersion", "asOf");
    private static final Map<String, String> IDS = Map.ofEntries(
        Map.entry("accounts", "accountId"), Map.entry("cards", "cardId"),
        Map.entry("transactions", "transactionId"), Map.entry("statements", "statementId"),
        Map.entry("obligations", "obligationId"), Map.entry("reserves", "reserveId"),
        Map.entry("allocations", "allocationId"), Map.entry("settlements", "linkId"),
        Map.entry("recurringPlans", "planId"), Map.entry("recurringPlanRevisions", "revisionId"),
        Map.entry("recurringDecisions", "decisionId"));

    /**
     * 현재 저장 상태를 새 응답에 복사하고 페이지에 필요한 근거만 제공한다.
     * 연결 전에는 금융 배열을 빈 값으로 채우지 않고 계약의 열 키만 반환한다.
     * @created 2026-10-29
     * @usedBy FinancialService의 조회 및 쓰기 후 Snapshot 조립
     * @param source 같은 인증 트랜잭션에서 읽은 전체 사용자 원천·설정
     * @param connectedCodes 현재 활성 연결 집합
     * @param dataVersion 현재 사용자 저장 버전
     * @param afterId 첫 조회는 null, 후속 조회는 검증한 cursor의 마지막 UUID
     * @param pageOnly 후속 거래 페이지 여부
     * @return cursor 서명 전 응답과 마지막 거래 ID·다음 페이지 여부
     */
    public PageSlice project(ObjectNode source, Set<String> connectedCodes, String dataVersion,
            UUID afterId, boolean pageOnly) {
        try {
            Context context = new Context(source, connectedCodes, dataVersion);
            ObjectNode visible = context.build();
            if (connectedCodes.isEmpty()) {
                if (pageOnly || afterId != null) throw unavailable();
                return new PageSlice(visible, null, false);
            }
            return FinancialPages.slice(visible, afterId, pageOnly);
        } catch (FinancialException failure) {
            throw failure;
        } catch (RuntimeException failure) {
            throw unavailable();
        }
    }

    /**
     * 요청마다 별도 인덱스·제한 목록을 만들어 사용자 간 가변 상태 공유를 막는다.
     * @created 2026-10-29
     * @usedBy FinancialProjection.project
     */
    private static final class Context {
        private final ObjectNode source;
        private final ObjectNode result;
        private final Set<String> connected;
        private final Map<String, Map<String, ObjectNode>> indexes = new HashMap<>();
        private final Map<String, Set<String>> visible = new HashMap<>();
        private final Set<String> hiddenIds = new HashSet<>();
        private final Map<String, ObjectNode> restrictions = new LinkedHashMap<>();
        private final Map<String, String> institutionKinds = new HashMap<>();
        private final String userId;
        private final boolean billingItems;

        /**
         * 원천 복사본의 사용자·버전·자원 ID와 필수 부모를 조회용 인덱스로 준비한다.
         * @created 2026-10-29
         * @usedBy FinancialProjection.project
         * @modified 2026-10-30 - 원천 v3/v4와 공개 응답 버전을 일치시켜 청구 항목 계약을 보존
         */
        private Context(ObjectNode input, Set<String> connectedCodes, String dataVersion) {
            if (input == null || connectedCodes == null || dataVersion == null
                    || !dataVersion.matches("[1-9][0-9]{0,18}")) throw unavailable();
            source = input.deepCopy();
            FinancialShape.validate(source);
            connected = Set.copyOf(connectedCodes);
            String schema = text(source, "schemaVersion");
            if (!Set.of("PAYSE-DRAFT-3", "PAYSE-DRAFT-4").contains(schema)
                    || !"KRW".equals(text(source, "currency"))) throw unavailable();
            billingItems = schema.equals("PAYSE-DRAFT-4");
            userId = id(source, "userId");
            OffsetDateTime.parse(text(source, "asOf"));
            result = object();
            for (String key : HEADERS) result.set(key, required(source, key).deepCopy());
            result.put("schemaVersion", billingItems ? "PAYSE-API-0.6-4" : "PAYSE-API-0.6-3");
            result.put("dataVersion", dataVersion);
            for (ObjectNode institution : rows(source, "institutions")) {
                String code = text(institution, "code");
                String kind = text(institution, "kind");
                if (!Set.of("bank", "card").contains(kind)
                        || institutionKinds.putIfAbsent(code, kind) != null) throw unavailable();
            }
            if (!institutionKinds.keySet().containsAll(connected)) throw unavailable();
            // DB 저장에서는 본문/보조 거래가 같은 테이블이다. 기존 fixture 입력도 한 인덱스로 합친다.
            ArrayNode transactions = array();
            Map<String, ObjectNode> merged = new LinkedHashMap<>();
            for (String key : List.of("transactions", "relatedTransactions")) {
                for (ObjectNode transaction : rows(source, key)) {
                    String transactionId = id(transaction, "transactionId");
                    ObjectNode old = merged.putIfAbsent(transactionId, transaction);
                    if (old != null && !old.equals(transaction)) throw unavailable();
                }
            }
            merged.values().forEach(transactions::add);
            source.set("transactions", transactions);
            source.set("relatedTransactions", array());
            IDS.forEach((key, idKey) -> {
                Map<String, ObjectNode> index = new LinkedHashMap<>();
                for (ObjectNode row : rows(source, key)) {
                    if (!userId.equals(id(row, "userId"))
                            || index.putIfAbsent(id(row, idKey), row) != null) throw unavailable();
                    if (Set.of("accounts", "cards", "transactions", "statements").contains(key)
                            && !text(source, "sourceVersion").equals(text(row, "sourceVersion"))) throw unavailable();
                }
                indexes.put(key, index);
                visible.put(key, new LinkedHashSet<>());
            });
            validateReferences();
        }

        /**
         * 소유권이 일치해도 잘못된 부모 관계를 정상 미연결 상태로 설명하지 않는다.
         * @created 2026-10-29
         * @usedBy Context 생성자
         */
        private void validateReferences() {
            for (ObjectNode account : all("accounts")) institution(account, "bank");
            for (ObjectNode card : all("cards")) {
                institution(card, "card");
                knownOptional(card, "withdrawalAccountId", "accounts");
            }
            for (ObjectNode transaction : all("transactions")) {
                knownOptional(transaction, "accountId", "accounts");
                knownOptional(transaction, "cardId", "cards");
                String kind = text(transaction, "recordKind");
                if (kind.equals("account_entry")) known(transaction, "accountId", "accounts");
                else if (Set.of("card_purchase", "card_refund", "card_cancellation").contains(kind)) {
                    known(transaction, "cardId", "cards");
                } else throw unavailable();
            }
            for (ObjectNode statement : all("statements")) known(statement, "cardId", "cards");
            for (ObjectNode revision : all("recurringPlanRevisions")) {
                known(revision, "planId", "recurringPlans");
                known(revision, "withdrawalAccountId", "accounts");
                knownOptional(revision, "cardId", "cards");
            }
            for (ObjectNode obligation : all("obligations")) {
                known(obligation, "withdrawalAccountId", "accounts");
                knownOptional(obligation, "statementId", "statements");
                knownOptional(obligation, "recurringPlanId", "recurringPlans");
                knownOptional(obligation, "planRevisionId", "recurringPlanRevisions");
                String plan = nullableText(obligation, "recurringPlanId");
                String revision = nullableText(obligation, "planRevisionId");
                if ((plan == null) != (revision == null)) throw unavailable();
                if (revision != null && !plan.equals(text(indexes.get("recurringPlanRevisions").get(revision), "planId"))) {
                    throw unavailable();
                }
            }
            for (ObjectNode reserve : all("reserves")) known(reserve, "accountId", "accounts");
            for (ObjectNode settlement : all("settlements")) {
                known(settlement, "obligationId", "obligations");
                known(settlement, "transactionId", "transactions");
            }
            for (ObjectNode allocation : all("allocations")) {
                known(allocation, "reserveId", "reserves");
                known(allocation, "obligationId", "obligations");
                for (ObjectNode proof : rows(allocation, "releaseEvidence")) {
                    known(proof, "settlementLinkId", "settlements");
                    ObjectNode settlement = indexes.get("settlements").get(text(proof, "settlementLinkId"));
                    if (!text(allocation, "obligationId").equals(text(settlement, "obligationId"))) throw unavailable();
                }
            }
            for (ObjectNode link : rows(source, "institutionLinks")) {
                if (!userId.equals(id(link, "userId")) || !institutionKinds.containsKey(text(link, "institutionCode"))) {
                    throw unavailable();
                }
            }
        }

        /**
         * 종속 공개 순서대로 원천·설정·관계를 조립하고 숨겨진 ID 잔류를 검사한다.
         * @created 2026-10-29
         * @usedBy FinancialProjection.project
         */
        private ObjectNode build() {
            result.set("institutions", required(source, "institutions").deepCopy());
            ArrayNode links = array();
            for (ObjectNode link : rows(source, "institutionLinks")) {
                if (link.get("disconnectedAt").isNull() && connected.contains(text(link, "institutionCode"))) links.add(link);
            }
            result.set("institutionLinks", links);
            if (connected.isEmpty()) {
                result.set("coverage", array());
                return result;
            }
            accounts();
            cards();
            transactions();
            statements();
            plans();
            obligations();
            reserves();
            settlements();
            allocations();
            overrides();
            decisions();
            relations();
            occurrenceLinks();
            settings();
            coverage();
            result.set("referenceResolutions", array());
            result.set("relatedTransactions", array());
            ArrayNode marks = array();
            restrictions.values().forEach(marks::add);
            result.set("accessRestrictions", marks);
            ensurePrivateIdsAbsent(result);
            return result;
        }

        /**
         * 원천 계좌의 은행 연결과 저장된 선택 여부를 분리하여 제공한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void accounts() {
            ArrayNode out = array();
            for (ObjectNode row : all("accounts")) {
                if (connected.contains(text(row, "institutionCode"))) keep(out, "accounts", row);
                else hide("accounts", row, "account");
            }
            result.set("accounts", out);
        }

        /**
         * 카드 연결과 출금 은행의 권한을 따로 검사하여 숨겨진 계좌 키만 생략한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void cards() {
            ArrayNode out = array();
            for (ObjectNode row : all("cards")) {
                if (!connected.contains(text(row, "institutionCode"))) { hide("cards", row, "card"); continue; }
                redact(row, "withdrawalAccountId", "accounts", "card", id(row, "cardId"), "account");
                keep(out, "cards", row);
            }
            result.set("cards", out);
        }

        /**
         * 입출금은 은행, 구매·환불·취소는 카드사를 기준으로 공개하며 원거래 권한도 검사한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void transactions() {
            ArrayNode out = array();
            for (ObjectNode row : all("transactions")) {
                boolean accountEntry = "account_entry".equals(text(row, "recordKind"));
                String parent = text(row, accountEntry ? "accountId" : "cardId");
                if (!shown(accountEntry ? "accounts" : "cards", parent)) { hide("transactions", row, "transaction"); continue; }
                redact(row, accountEntry ? "cardId" : "accountId", accountEntry ? "cards" : "accounts",
                    "transaction", id(row, "transactionId"), accountEntry ? "card" : "account");
                keep(out, "transactions", row);
            }
            for (JsonNode value : out) {
                ObjectNode row = (ObjectNode) value;
                String original = nullableText(row, "originalTransactionId");
                if (original == null) continue;
                if (!indexes.get("transactions").containsKey(original)) throw unavailable();
                redact(row, "originalTransactionId", "transactions", "transaction", id(row, "transactionId"), "transaction");
            }
            result.set("transactions", out);
        }

        /**
         * 청구 원천의 버전을 유지하고 청구 항목·포함 거래의 공개 권한을 함께 적용한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-10-30 - v4 항목의 nullable 연결·제한 표식과 숨긴 항목 ID 비노출 지원
         */
        private void statements() {
            ArrayNode out = array();
            for (ObjectNode row : all("statements")) {
                if (!shown("cards", text(row, "cardId"))) {
                    hide("statements", row, "card");
                    if (billingItems) {
                        for (ObjectNode item : rows(row, "items")) hiddenIds.add(id(item, "itemId"));
                    }
                    continue;
                }
                if (billingItems) {
                    statementItems(row);
                    keep(out, "statements", row);
                    continue;
                }
                ArrayNode refs = array();
                for (String transaction : strings(row, "includedTransactionRefs")) {
                    if (!indexes.get("transactions").containsKey(transaction)) throw unavailable();
                    if (shown("transactions", transaction)) refs.add(transaction);
                    else restrict("statement", id(row, "statementId"), "includedTransactionRefs", "transaction");
                }
                row.set("includedTransactionRefs", refs);
                keep(out, "statements", row);
            }
            result.set("statements", out);
        }

        /**
         * 공개 청구의 미연결 거래 키만 생략하고 참조 배열을 남은 항목에서 파생한다.
         * 실제 null 연결·금액·회차는 원천 그대로 유지하며 페이지 위치로 권한을 판단하지 않는다.
         * @created 2026-10-30
         * @usedBy Context.statements
         */
        private void statementItems(ObjectNode statement) {
            Set<String> references = new LinkedHashSet<>();
            boolean restricted = false;
            for (ObjectNode item : rows(statement, "items")) {
                String transaction = nullableText(item, "transactionId");
                if (transaction == null) continue;
                if (!indexes.get("transactions").containsKey(transaction)) throw unavailable();
                if (shown("transactions", transaction)) {
                    references.add(transaction);
                } else {
                    item.remove("transactionId");
                    restrict("statementItem", id(item, "itemId"), "transactionId", "transaction");
                    restricted = true;
                }
            }
            if (restricted) restrict("statement", id(statement, "statementId"), "includedTransactionRefs", "transaction");
            ArrayNode refs = array();
            references.forEach(refs::add);
            statement.set("includedTransactionRefs", refs);
        }

        /**
         * 버전의 출금 계좌를 기준으로 계획을 공개하고 숨겨진 버전의 존재만 제한 표식으로 알린다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void plans() {
            ArrayNode revisions = array();
            for (ObjectNode row : all("recurringPlanRevisions")) {
                if (!shown("accounts", text(row, "withdrawalAccountId"))) { hide("recurringPlanRevisions", row, "account"); continue; }
                redact(row, "cardId", "cards", "recurringPlanRevision", id(row, "revisionId"), "card");
                keep(revisions, "recurringPlanRevisions", row);
                visible.get("recurringPlans").add(text(row, "planId"));
            }
            ArrayNode plans = array();
            for (ObjectNode row : all("recurringPlans")) {
                String planId = id(row, "planId");
                if (!shown("recurringPlans", planId)) { hide("recurringPlans", row, "account"); continue; }
                if (!Set.of("userId", "planId", "firstOccurrenceMonth").equals(Set.copyOf(row.propertyNames()))) throw unavailable();
                keep(plans, "recurringPlans", row);
                for (ObjectNode revision : all("recurringPlanRevisions")) {
                    if (planId.equals(text(revision, "planId")) && !shown("recurringPlanRevisions", id(revision, "revisionId"))) {
                        restrict("recurringPlan", planId, "recurringPlanRevisions", "planRevision");
                    }
                }
            }
            result.set("recurringPlanRevisions", revisions);
            result.set("recurringPlans", plans);
        }

        /**
         * 의무의 필수 계좌·계획·고정 버전과 선택 청구 참조를 서로 다르게 처리한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void obligations() {
            ArrayNode out = array();
            for (ObjectNode row : all("obligations")) {
                String hidden = !shown("accounts", text(row, "withdrawalAccountId")) ? "account"
                    : hiddenPlan(nullableText(row, "recurringPlanId"), nullableText(row, "planRevisionId"));
                if (hidden != null) { hide("obligations", row, hidden); continue; }
                redact(row, "statementId", "statements", "obligation", id(row, "obligationId"), "statement");
                keep(out, "obligations", row);
            }
            result.set("obligations", out);
        }

        /**
         * 보호 계좌를 볼 수 있는 보호 설정만 공개한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void reserves() {
            ArrayNode out = array();
            for (ObjectNode row : all("reserves")) {
                if (shown("accounts", text(row, "accountId"))) keep(out, "reserves", row);
                else hide("reserves", row, "account");
            }
            result.set("reserves", out);
        }

        /**
         * 정산의 두 부모를 검사하고 공개 의무에서 숨긴 지급 근거의 제한을 명시한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void settlements() {
            ArrayNode out = array();
            for (ObjectNode row : all("settlements")) {
                String obligationId = text(row, "obligationId");
                if (!shown("obligations", obligationId)) { hide("settlements", row, "obligation"); continue; }
                if (!shown("transactions", text(row, "transactionId"))) {
                    hide("settlements", row, "transaction");
                    restrict("obligation", obligationId, "settlements", "transaction");
                    continue;
                }
                keep(out, "settlements", row);
            }
            result.set("settlements", out);
        }

        /**
         * 배정 부모를 숨기거나 해제 근거만 생략하되 확인된 해제 금액을 변경하지 않는다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void allocations() {
            ArrayNode out = array();
            for (ObjectNode row : all("allocations")) {
                String kind = !shown("reserves", text(row, "reserveId")) ? "reserve"
                    : !shown("obligations", text(row, "obligationId")) ? "obligation" : null;
                if (kind != null) { hide("allocations", row, kind); continue; }
                for (ObjectNode proof : rows(row, "releaseEvidence")) {
                    ObjectNode settlement = indexes.get("settlements").get(text(proof, "settlementLinkId"));
                    if (!shown("transactions", text(settlement, "transactionId"))) {
                        row.remove("releaseEvidence");
                        restrict("allocation", id(row, "allocationId"), "releaseEvidence", "transaction");
                        break;
                    }
                }
                keep(out, "allocations", row);
            }
            result.set("allocations", out);
        }

        /**
         * 개별 회차의 계좌와 고정 계획 버전 공개 조건을 유지한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void overrides() {
            ArrayNode out = array();
            for (ObjectNode row : rows(source, "occurrenceOverrides")) {
                owner(row);
                known(row, "withdrawalAccountId", "accounts");
                String hidden = !shown("accounts", text(row, "withdrawalAccountId")) ? "account"
                    : hiddenPlan(planFrom(row), text(row, "planRevisionId"));
                if (hidden == null) out.add(row);
                else restrict("response", null, "occurrenceOverrides", hidden);
            }
            result.set("occurrenceOverrides", out);
        }

        /**
         * 반복 결정의 계획·모든 원천 거래가 공개될 때만 그 결정을 반환한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void decisions() {
            ArrayNode out = array();
            for (ObjectNode row : all("recurringDecisions")) {
                String plan = nullableText(row, "planId");
                String hidden = hiddenPlan(plan, null) != null ? "plan" : null;
                for (String transaction : strings(row, "evidenceTransactionIds")) {
                    if (!indexes.get("transactions").containsKey(transaction)) throw unavailable();
                    if (!shown("transactions", transaction)) hidden = "transaction";
                }
                if (hidden != null) { hide("recurringDecisions", row, hidden); continue; }
                keep(out, "recurringDecisions", row);
            }
            result.set("recurringDecisions", out);
        }

        /**
         * 양 끝 거래가 모두 공개된 관계만 제공하고 숨긴 반대쪽 ID를 표식에 넣지 않는다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void relations() {
            ArrayNode out = array();
            Set<String> unique = new HashSet<>();
            for (ObjectNode row : rows(source, "transactionRelations")) {
                String from = text(row, "fromId"), to = text(row, "toId");
                known(row, "fromId", "transactions"); known(row, "toId", "transactions");
                if (shown("transactions", from) && shown("transactions", to)) {
                    String key = text(row, "kind") + "|" + from + "|" + to + "|" + text(row, "evidenceRef");
                    if (unique.add(key)) out.add(row);
                } else {
                    restrict("response", null, "transactionRelations", "transaction");
                    if (shown("transactions", from)) restrict("transaction", from, "transactionRelations", "transaction");
                    if (shown("transactions", to)) restrict("transaction", to, "transactionRelations", "transaction");
                }
            }
            result.set("transactionRelations", out);
        }

        /**
         * 계획·구매·청구·의무의 명시 참조를 모두 확인한 회차 연결만 반환한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void occurrenceLinks() {
            ArrayNode out = array();
            Set<String> unique = new HashSet<>();
            for (ObjectNode row : rows(source, "occurrenceLinks")) {
                String hidden = hiddenPlan(planFrom(row), null) != null ? "plan" : null;
                for (String field : List.of("purchaseTransactionId", "statementId", "obligationId")) {
                    String group = switch (field) {
                        case "purchaseTransactionId" -> "transactions";
                        case "statementId" -> "statements";
                        default -> "obligations";
                    };
                    knownOptional(row, field, group);
                    String reference = nullableText(row, field);
                    if (reference != null && !shown(group, reference)) {
                        hidden = switch (group) { case "transactions" -> "transaction"; case "statements" -> "statement"; default -> "obligation"; };
                    }
                }
                if (hidden != null) restrict("response", null, "occurrenceLinks", hidden);
                else {
                    String tuple = text(row, "recurrenceKey") + "|" + nullableText(row, "purchaseTransactionId")
                        + "|" + nullableText(row, "statementId") + "|" + nullableText(row, "obligationId")
                        + "|" + text(row, "evidenceRef");
                    if (unique.add(tuple)) out.add(row);
                }
            }
            result.set("occurrenceLinks", out);
        }

        /**
         * 급여 원천을 보존하고 계좌·근거·카드 계획의 미연결 슬롯만 생략한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void settings() {
            ObjectNode settings = objectAt(source, "settings");
            ObjectNode salary = objectAt(settings, "salary");
            knownOptional(salary, "salaryAccountId", "accounts");
            String account = nullableText(salary, "salaryAccountId");
            boolean accountHidden = account != null && !shown("accounts", account);
            boolean evidenceHidden = false;
            Set<String> months = new HashSet<>();
            List<ObjectNode> evidence = rows(salary, "receiptEvidence");
            for (ObjectNode proof : evidence) {
                String month = text(proof, "payMonth");
                if (!month.matches("[0-9]{4}-(0[1-9]|1[0-2])") || month.startsWith("0000") || !months.add(month)) throw unavailable();
                YearMonth.parse(month); LocalDate.parse(text(proof, "expectedPayDate"));
                String confirmation = text(proof, "confirmation");
                if (!Set.of("unknown", "partial", "confirmed").contains(confirmation)) throw unavailable();
                List<String> references = strings(proof, "transactionIds");
                if (!confirmation.equals("unknown") && references.isEmpty()) throw unavailable();
                for (String transactionId : references) {
                    ObjectNode transaction = indexes.get("transactions").get(transactionId);
                    if (transaction == null || !"account_entry".equals(text(transaction, "recordKind"))
                            || !"in".equals(text(transaction, "direction")) || !"posted".equals(text(transaction, "status"))
                            || !required(transaction, "balanceReflected").asBoolean()) throw unavailable();
                    if (!shown("transactions", transactionId)) evidenceHidden = true;
                }
            }
            if (accountHidden) {
                salary.remove("salaryAccountId");
                restrict("settings", null, "salary.salaryAccountId", "account");
            }
            if (!evidence.isEmpty() && accountHidden) {
                salary.remove("receiptEvidence");
                restrict("settings", null, "salary.receiptEvidence", "account");
            } else if (evidenceHidden) {
                salary.remove("receiptEvidence");
                restrict("settings", null, "salary.receiptEvidence", "transaction");
            }
            ArrayNode cardPlans = array();
            for (ObjectNode row : rows(settings, "cardPlans")) {
                known(row, "cardId", "cards");
                if (shown("cards", text(row, "cardId"))) cardPlans.add(row);
                else restrict("settings", null, "cardPlans", "card");
            }
            settings.set("cardPlans", cardPlans);
            result.set("settings", settings);
        }

        /**
         * 실제 확보 범위는 원천 그대로 제공하며 연결하지 않은 대상의 ID는 생략한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void coverage() {
            ArrayNode out = array();
            Set<String> keys = new HashSet<>();
            for (ObjectNode row : rows(source, "coverage")) {
                String kind = text(row, "targetKind");
                if (!Set.of("account", "card").contains(kind)) throw unavailable();
                String group = kind.equals("account") ? "accounts" : "cards";
                known(row, "targetId", group);
                if (!keys.add(kind + ":" + text(row, "targetId"))) throw unavailable();
                if (shown(group, text(row, "targetId"))) out.add(row);
                else restrict("response", null, "coverage", kind);
            }
            if (keys.size() != indexes.get("accounts").size() + indexes.get("cards").size()) throw unavailable();
            result.set("coverage", out);
        }

        /**
         * 공개 문자열 어디에도 미연결 자원의 식별자가 남아 있지 않은지 검사한다.
         * @created 2026-10-29
         * @usedBy Context.build
         */
        private void ensurePrivateIdsAbsent(JsonNode node) {
            if (node.isString()) {
                String text = node.asString().toLowerCase(java.util.Locale.ROOT);
                for (String id : hiddenIds) if (text.contains(id)) throw unavailable();
            } else if (node.isContainer()) {
                for (JsonNode child : node) ensurePrivateIdsAbsent(child);
            }
        }

        /**
         * 필수 계획 또는 고정 버전이 비공개이면 정확한 제한 종류를 반환한다.
         * @created 2026-10-29
         * @usedBy Context.obligations, overrides, decisions, occurrenceLinks
         */
        private String hiddenPlan(String plan, String revision) {
            if (plan != null && !indexes.get("recurringPlans").containsKey(plan)) throw unavailable();
            if (revision != null && !indexes.get("recurringPlanRevisions").containsKey(revision)) throw unavailable();
            if (plan != null && !shown("recurringPlans", plan)) return "plan";
            if (revision != null && !shown("recurringPlanRevisions", revision)) return "planRevision";
            return null;
        }

        /**
         * 명시 회차 키의 계획 ID만 읽고 월별 회차·급여 날짜를 계산하지 않는다.
         * @created 2026-10-29
         * @usedBy Context.overrides, occurrenceLinks
         */
        private String planFrom(ObjectNode row) {
            String key = text(row, "recurrenceKey");
            int split = key.lastIndexOf(':');
            if (split < 0) throw unavailable();
            YearMonth.parse(key.substring(split + 1));
            return UUID.fromString(key.substring(0, split)).toString();
        }

        /**
         * 자원의 기관 종류가 원천 객체와 일치하는지 확인한다.
         * @created 2026-10-29
         * @usedBy Context.validateReferences
         */
        private void institution(ObjectNode row, String kind) {
            if (!kind.equals(institutionKinds.get(text(row, "institutionCode")))) throw unavailable();
        }

        /**
         * 원천 배열에서 인덱스한 행을 순서대로 읽는다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         */
        private List<ObjectNode> all(String group) { return new ArrayList<>(indexes.get(group).values()); }

        /**
         * 공개 자원을 결과 배열과 공개 ID 집합에 함께 기록한다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         */
        private void keep(ArrayNode target, String group, ObjectNode row) {
            visible.get(group).add(id(row, IDS.get(group)));
            target.add(row);
        }

        /**
         * 비공개 행을 숨기고 배열의 제한 위치만 공개한다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         */
        private void hide(String group, ObjectNode row, String kind) {
            hiddenIds.add(id(row, IDS.get(group)));
            restrict("response", null, group, kind);
        }

        /**
         * 공개 부모의 미연결 참조는 null로 바꾸지 않고 키를 생략한다.
         * @created 2026-10-29
         * @usedBy Context.cards, transactions, statements, obligations, plans
         */
        private void redact(ObjectNode row, String field, String group, String ownerType, String ownerId, String kind) {
            String reference = nullableText(row, field);
            if (reference != null && !shown(group, reference)) {
                row.remove(field);
                restrict(ownerType, ownerId, field, kind);
            }
        }

        /**
         * 요청별 공개 ID 인덱스에서 참조 권한을 확인한다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         */
        private boolean shown(String group, String reference) { return visible.get(group).contains(reference); }

        /**
         * 동일 위치·종류의 제한은 한 번만 기록하며 숨겨진 대상 ID는 포함하지 않는다.
         * @created 2026-10-29
         * @usedBy Context.hide, redact 및 관계 투영 메서드
         */
        private void restrict(String ownerType, String ownerId, String field, String kind) {
            String key = ownerType + "|" + ownerId + "|" + field + "|" + kind;
            ObjectNode mark = object().put("ownerType", ownerType).put("ownerId", ownerId)
                .put("field", field).put("targetKind", kind).put("reason", "not_connected");
            restrictions.putIfAbsent(key, mark);
        }

        /**
         * 추가 행의 소유자가 현재 Snapshot 소유자와 같은지 확인한다.
         * @created 2026-10-29
         * @usedBy Context.overrides
         */
        private void owner(ObjectNode row) { if (!userId.equals(id(row, "userId"))) throw unavailable(); }

        /**
         * 필수 참조가 현재 사용자의 확보된 부모 집합에 존재하는지 확인한다.
         * @created 2026-10-29
         * @usedBy Context.validateReferences 및 관계 투영 메서드
         */
        private void known(ObjectNode row, String field, String group) {
            if (!indexes.get(group).containsKey(id(row, field))) throw unavailable();
        }

        /**
         * nullable 원천 참조의 null과 확보되지 않은 잘못된 ID를 구분한다.
         * @created 2026-10-29
         * @usedBy Context.validateReferences, settings, occurrenceLinks
         */
        private void knownOptional(ObjectNode row, String field, String group) {
            if (nullableText(row, field) != null) known(row, field, group);
        }
    }

    /**
     * 원천 오류 내용을 클라이언트에 노출하지 않는 기존 503을 만든다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static FinancialException unavailable() { return new FinancialException(503, "TEMPORARILY_UNAVAILABLE"); }

    /**
     * 공통 JsonNodeFactory의 새 객체를 요청 로컬에서 생성한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static ObjectNode object() { return JsonNodeFactory.instance.objectNode(); }

    /**
     * 공통 JsonNodeFactory의 새 배열을 요청 로컬에서 생성한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static ArrayNode array() { return JsonNodeFactory.instance.arrayNode(); }

    /**
     * 누락된 필수 값은 정상 null로 보충하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static JsonNode required(JsonNode row, String field) {
        JsonNode value = row.get(field);
        if (value == null || value.isMissingNode()) throw unavailable();
        return value;
    }

    /**
     * 필수 문자열의 타입을 자동 변환 없이 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static String text(JsonNode row, String field) {
        JsonNode value = required(row, field);
        if (!value.isString() || value.asString().isEmpty()) throw unavailable();
        return value.asString();
    }

    /**
     * nullable 문자열에서 원천 null과 누락을 구분한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static String nullableText(JsonNode row, String field) {
        JsonNode value = required(row, field);
        return value.isNull() ? null : text(row, field);
    }

    /**
     * 정규 UUID 형식만 받아 축약 UUID나 다른 표기를 묵시 보정하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static String id(JsonNode row, String field) {
        String value = text(row, field);
        if (!UUID.fromString(value).toString().equals(value)) throw unavailable();
        return value;
    }

    /**
     * 필수 중첩 객체의 타입을 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection.Context.settings, FinancialPages
     */
    static ObjectNode objectAt(JsonNode row, String field) {
        JsonNode value = required(row, field);
        if (!(value instanceof ObjectNode object)) throw unavailable();
        return object;
    }

    /**
     * 필수 객체 배열을 빈 배열로 대체하지 않고 모든 원소의 타입을 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static List<ObjectNode> rows(JsonNode source, String field) {
        JsonNode value = required(source, field);
        if (!value.isArray()) throw unavailable();
        List<ObjectNode> result = new ArrayList<>();
        for (JsonNode item : value) {
            if (!(item instanceof ObjectNode object)) throw unavailable();
            result.add(object);
        }
        return result;
    }

    /**
     * 참조 배열은 문자열만 허용하고 같은 ID의 중복을 거절한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static List<String> strings(JsonNode row, String field) {
        JsonNode values = required(row, field);
        if (!values.isArray()) throw unavailable();
        List<String> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (JsonNode value : values) {
            if (!value.isString() || value.asString().isEmpty() || !seen.add(value.asString())) throw unavailable();
            result.add(value.asString());
        }
        return result;
    }
}
