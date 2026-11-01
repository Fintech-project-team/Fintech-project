package com.payse.api.finance.service;

import static com.payse.api.finance.service.FinancialProjection.objectAt;
import static com.payse.api.finance.service.FinancialProjection.id;
import static com.payse.api.finance.service.FinancialProjection.required;
import static com.payse.api.finance.service.FinancialProjection.rows;
import static com.payse.api.finance.service.FinancialProjection.strings;
import static com.payse.api.finance.service.FinancialProjection.text;
import static com.payse.api.finance.service.FinancialProjection.unavailable;

import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 저장소의 내부 결과라도 버전별 사전에 없는 필드·비밀값은 응답으로 복사하지 못하게 한다.
 * @created 2026-10-29
 * @usedBy FinancialProjection.Context
 * @modified 2026-10-30 - v4 청구 항목의 형식·소유권·원천·금액·참조 관계 검증 추가
 */
final class FinancialShape {
    private static final long MAX_MONEY = 9_000_000_000_000L;
    private static final String ITEM = "itemId userId sourceRef sourceVersion transactionId label merchantName purchaseDate originalUsedAmountKRW billedPrincipalKRW feeOrAdjustmentAmountKRW billedAmountKRW installmentMonths installmentRound";
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
     * @modified 2026-10-30 - 저장 버전별 items 필수 여부와 v4 청구 원천의 전체 제약 검증
     */
    static void validate(ObjectNode source) {
        String schema = text(source, "schemaVersion");
        if (!Set.of("PAYSE-DRAFT-3", "PAYSE-DRAFT-4").contains(schema)) throw unavailable();
        boolean v4 = schema.equals("PAYSE-DRAFT-4");
        FIELDS.forEach((group, fields) -> {
            for (ObjectNode row : rows(source, group)) {
                boolean transaction = group.equals("transactions") || group.equals("relatedTransactions");
                String allowed = v4 && group.equals("statements") ? fields + " items" : fields;
                keys(row, allowed, transaction ? Set.of("cancellationDate") : Set.of());
                if (transaction && row.path("recordKind").asString("").equals("account_entry")) {
                    JsonNode status = row.get("status");
                    if (!status.isString() || !Set.of("posted", "unknown").contains(status.asString())) {
                        throw unavailable();
                    }
                }
            }
        });
        if (v4) statementItems(source);
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
     * 청구 항목을 별도 원천으로 검증하며 거래 연결에서 금액·날짜를 복사하거나 계산하지 않는다.
     * @created 2026-10-30
     * @usedBy validate
     */
    private static void statementItems(ObjectNode source) {
        String owner = id(source, "userId");
        String version = text(source, "sourceVersion");
        if (version.isBlank()) throw unavailable();
        LocalDate asOf = OffsetDateTime.parse(text(source, "asOf"))
            .atZoneSameInstant(ZoneId.of("Asia/Seoul")).toLocalDate();
        Map<String, ObjectNode> transactions = new HashMap<>();
        for (String group : List.of("transactions", "relatedTransactions")) {
            for (ObjectNode row : rows(source, group)) {
                ObjectNode previous = transactions.putIfAbsent(id(row, "transactionId"), row);
                if (previous != null && !previous.equals(row)) throw unavailable();
            }
        }
        Set<String> identities = new HashSet<>();
        Set<String> sourceRefs = new HashSet<>();
        for (ObjectNode statement : rows(source, "statements")) {
            if (!owner.equals(id(statement, "userId")) || !version.equals(text(statement, "sourceVersion"))) {
                throw unavailable();
            }
            String card = id(statement, "cardId");
            LinkedHashSet<String> references = new LinkedHashSet<>();
            for (ObjectNode item : rows(statement, "items")) {
                keys(item, ITEM, Set.of());
                if (!identities.add(id(item, "itemId")) || !owner.equals(id(item, "userId"))
                        || !version.equals(text(item, "sourceVersion"))) throw unavailable();
                String sourceRef = text(item, "sourceRef");
                if (sourceRef.isBlank() || !sourceRefs.add(sourceRef)) throw unavailable();
                itemValues(item, asOf);
                if (!required(item, "transactionId").isNull()) {
                    String transactionId = id(item, "transactionId");
                    ObjectNode transaction = transactions.get(transactionId);
                    if (transaction == null || !owner.equals(id(transaction, "userId"))
                            || !card.equals(id(transaction, "cardId"))) throw unavailable();
                    references.add(transactionId);
                }
            }
            if (!strings(statement, "includedTransactionRefs").equals(List.copyOf(references))) throw unavailable();
        }
    }

    /**
     * 청구 원천의 null·부호·정수 범위·확인 이용일·할부 순서를 검사한다.
     * @created 2026-10-30
     * @usedBy statementItems
     */
    private static void itemValues(ObjectNode item, LocalDate asOf) {
        for (String field : List.of("label", "merchantName")) {
            JsonNode value = required(item, field);
            if (!value.isNull() && !value.isString()) throw unavailable();
        }
        JsonNode purchase = required(item, "purchaseDate");
        if (!purchase.isNull()) {
            String value = text(item, "purchaseDate");
            if (!value.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}") || value.startsWith("0000")) throw unavailable();
            if (LocalDate.parse(value).isAfter(asOf)) throw unavailable();
        }
        amount(required(item, "originalUsedAmountKRW"), false);
        amount(required(item, "billedPrincipalKRW"), false);
        amount(required(item, "feeOrAdjustmentAmountKRW"), true);
        amount(required(item, "billedAmountKRW"), true);
        JsonNode months = required(item, "installmentMonths");
        JsonNode round = required(item, "installmentRound");
        for (JsonNode value : List.of(months, round)) {
            if (!value.isNull() && (!value.isIntegralNumber() || !value.canConvertToInt() || value.asInt() <= 0)) {
                throw unavailable();
            }
        }
        if (!months.isNull() && !round.isNull() && round.asInt() > months.asInt()) throw unavailable();
    }

    /**
     * 확인된 원화 정수만 허용하며 음수는 호출부가 지정한 두 청구 항목 필드에만 허용한다.
     * @created 2026-10-30
     * @usedBy itemValues
     */
    private static void amount(JsonNode value, boolean signed) {
        if (value.isNull()) return;
        if (!value.isIntegralNumber() || !value.canConvertToLong()
                || value.asLong() < (signed ? -MAX_MONEY : 0) || value.asLong() > MAX_MONEY) throw unavailable();
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
     * @modified 2026-10-30 - v4 청구 항목 배열도 허용 키·배열 검사에 포함
     */
    private static void keys(ObjectNode row, String fieldNames, Set<String> optional) {
        Set<String> allowed = Set.copyOf(Arrays.asList(fieldNames.split(" ")));
        Set<String> actual = Set.copyOf(row.propertyNames());
        if (!allowed.containsAll(actual)) throw unavailable();
        for (String field : allowed) if (!optional.contains(field) && !actual.contains(field)) throw unavailable();
        Set<String> containers = Set.of("salary", "cardPlans", "receiptEvidence", "coveredRanges", "missingRanges",
            "scheduleEvidence", "includedTransactionRefs", "releaseEvidence", "evidenceRefs", "evidenceTransactionIds",
            "scheduleOverrides", "transactionIds", "items");
        for (String field : actual) {
            JsonNode value = row.get(field);
            if (value.isContainer() && !containers.contains(field)) throw unavailable();
            if (containers.contains(field) && !field.equals("salary") && !value.isArray()) throw unavailable();
        }
    }
}
