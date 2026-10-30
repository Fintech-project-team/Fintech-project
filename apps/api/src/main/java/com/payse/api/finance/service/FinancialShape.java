package com.payse.api.finance.service;

import static com.payse.api.finance.service.FinancialProjection.objectAt;
import static com.payse.api.finance.service.FinancialProjection.rows;
import static com.payse.api.finance.service.FinancialProjection.unavailable;

import java.util.Arrays;
import java.util.Map;
import java.util.Set;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 저장소의 내부 결과라도 공개 v3 사전에 없는 필드·비밀값은 응답으로 복사하지 못하게 한다.
 * @created 2026-10-29
 * @usedBy FinancialProjection.Context
 */
final class FinancialShape {
    private static final String TRANSACTION = "accountId amountKRW balanceReflected bookingDate cancellationDate cardId description direction installmentCurrent installmentTotal merchantName occurredAt occurredAtBasis originalTransactionId payseTransactionType purchaseDate recordKind reflectionReason refundDate sourceRef sourceVersion status transactionId userId withdrawalDate";
    private static final Map<String, String> FIELDS = Map.ofEntries(
        Map.entry("institutions", "accountCount cardCount code kind name"),
        Map.entry("institutionLinks", "consentedAt disconnectedAt institutionCode linkId userId"),
        Map.entry("coverage", "coveredRanges missingRanges requestedEnd requestedStart status targetId targetKind"),
        Map.entry("accounts", "accountId asOf balanceKRW included institutionCode maskedNumber nickname productName productType sourceRef sourceVersion userId"),
        Map.entry("cards", "cardId cardType institutionCode maskedNumber productName scheduleEvidence sourceRef sourceVersion userId withdrawalAccountId"),
        Map.entry("transactions", TRANSACTION), Map.entry("relatedTransactions", TRANSACTION),
        Map.entry("statements", "amountKRW cardId detailCompleteness dueDate includedTransactionRefs periodEnd periodStart sourceRef sourceVersion statementId userId"),
        Map.entry("obligations", "amountKRW dueDate label obligationId planRevisionId recurrenceKey recurringPlanId statementId status userId withdrawalAccountId"),
        Map.entry("reserves", "accountId amountKRW cancelledAt label reserveId userId"),
        Map.entry("allocations", "allocationId amountKRW obligationId releaseEvidence releasedKRW reserveId userId"),
        Map.entry("settlements", "allocatedKRW evidenceRefs invalidatedAt linkId method obligationId transactionId userId"),
        Map.entry("recurringPlans", "firstOccurrenceMonth planId userId"),
        Map.entry("recurringDecisions", "candidateKey decision decisionId evidenceTransactionIds normalizedName planId ruleVersion sourceVersion userId"),
        Map.entry("recurringPlanRevisions", "amountKRW cardId effectiveFromMonth isCurrent label monthlyDay paymentTiming planId revisionId scheduleBasis scheduleOverrides status userId withdrawalAccountId"),
        Map.entry("transactionRelations", "evidenceRef fromId kind toId"),
        Map.entry("occurrenceLinks", "evidenceRef obligationId purchaseTransactionId recurrenceKey statementId"),
        Map.entry("occurrenceOverrides", "amountKRW dueDate planRevisionId recurrenceKey status userId withdrawalAccountId"),
        Map.entry("referenceResolutions", "reason status transactionId"));

    /**
     * 금융 배열과 중첩 공개 필드를 검사한다. 누락된 취소일만 기존 v3의 선택 필드로 허용한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection.Context 생성자
     * @modified 2026-10-30 - 계좌 원천 상태를 posted/unknown으로 제한하고 카드 상태는 유지
     */
    static void validate(ObjectNode source) {
        FIELDS.forEach((group, fields) -> {
            for (ObjectNode row : rows(source, group)) {
                boolean transaction = group.equals("transactions") || group.equals("relatedTransactions");
                keys(row, fields, transaction ? Set.of("cancellationDate") : Set.of());
                if (transaction && row.path("recordKind").asString("").equals("account_entry")) {
                    JsonNode status = row.get("status");
                    if (!status.isString() || !Set.of("posted", "unknown").contains(status.asString())) {
                        throw unavailable();
                    }
                }
            }
        });
        ObjectNode settings = objectAt(source, "settings");
        keys(settings, "salary cardPlans", Set.of());
        ObjectNode salary = objectAt(settings, "salary");
        keys(salary, "salaryDay salaryAmountKRW salaryAccountId receiptEvidence", Set.of());
        for (ObjectNode row : rows(salary, "receiptEvidence")) keys(row, "payMonth expectedPayDate transactionIds confirmation", Set.of());
        for (ObjectNode row : rows(settings, "cardPlans")) keys(row, "cardId plannedPaymentDay", Set.of());
        nested(source, "cards", "scheduleEvidence", "dueDate evidenceRef periodEnd periodStart");
        nested(source, "recurringPlanRevisions", "scheduleOverrides", "evidenceRef occurrenceMonth plannedDate");
        nested(source, "allocations", "releaseEvidence", "amountKRW settlementLinkId writeReceiptId");
        nested(source, "coverage", "coveredRanges", "end start");
        nested(source, "coverage", "missingRanges", "end start");
        for (ObjectNode row : rows(source, "settlements")) FinancialProjection.strings(row, "evidenceRefs");
    }

    /**
     * 중첩 배열도 임의 필드를 전달하는 우회 경로로 사용하지 못하게 한다.
     * @created 2026-10-29
     * @usedBy FinancialShape.validate
     */
    private static void nested(ObjectNode source, String group, String field, String fields) {
        for (ObjectNode row : rows(source, group)) {
            for (ObjectNode child : rows(row, field)) keys(child, fields, Set.of());
        }
    }

    /**
     * 허용 목록 밖의 필드와 필수 필드 누락을 정상 값으로 묵시 변환하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialShape.validate, nested
     */
    private static void keys(ObjectNode row, String fieldNames, Set<String> optional) {
        Set<String> allowed = Set.copyOf(Arrays.asList(fieldNames.split(" ")));
        Set<String> actual = Set.copyOf(row.propertyNames());
        if (!allowed.containsAll(actual)) throw unavailable();
        for (String field : allowed) if (!optional.contains(field) && !actual.contains(field)) throw unavailable();
        Set<String> containers = Set.of("salary", "cardPlans", "receiptEvidence", "coveredRanges", "missingRanges",
            "scheduleEvidence", "includedTransactionRefs", "releaseEvidence", "evidenceRefs", "evidenceTransactionIds",
            "scheduleOverrides", "transactionIds");
        for (String field : actual) {
            JsonNode value = row.get(field);
            if (value.isContainer() && !containers.contains(field)) throw unavailable();
            if (containers.contains(field) && !field.equals("salary") && !value.isArray()) throw unavailable();
        }
    }
}
