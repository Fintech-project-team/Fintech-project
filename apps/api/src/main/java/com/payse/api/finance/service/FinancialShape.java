package com.payse.api.finance.service;

import static com.payse.api.finance.service.FinancialProjection.id;
import static com.payse.api.finance.service.FinancialProjection.objectAt;
import static com.payse.api.finance.service.FinancialProjection.required;
import static com.payse.api.finance.service.FinancialProjection.rows;
import static com.payse.api.finance.service.FinancialProjection.strings;
import static com.payse.api.finance.service.FinancialProjection.text;
import static com.payse.api.finance.service.FinancialProjection.unavailable;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiFieldConstants.Finance;
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
    private static final Map<String, String> FIELDS = Map.ofEntries(
        Map.entry("institutions", "accountCount cardCount code kind name"),
        Map.entry("institutionLinks", "consentedAt disconnectedAt institutionCode linkId userId"),
        Map.entry(
            "coverage",
            "coveredRanges missingRanges requestedEnd requestedStart status targetId targetKind"
        ),
        Map.entry(
            "accounts",
            "accountId asOf balanceKRW included institutionCode maskedNumber nickname productName productType sourceRef sourceVersion userId"
        ),
        Map.entry(
            "cards",
            "cardId cardType institutionCode maskedNumber productName scheduleEvidence sourceRef sourceVersion userId withdrawalAccountId"
        ),
        Map.entry("transactions", ApiFieldConstants.Finance.TRANSACTION_FIELDS),
        Map.entry("relatedTransactions", ApiFieldConstants.Finance.TRANSACTION_FIELDS),
        Map.entry(
            "statements",
            "amountKRW cardId detailCompleteness dueDate includedTransactionRefs periodEnd periodStart sourceRef sourceVersion statementId userId"
        ),
        Map.entry(
            "obligations",
            "amountKRW dueDate label obligationId planRevisionId recurrenceKey recurringPlanId statementId status userId withdrawalAccountId"
        ),
        Map.entry("reserves", "accountId amountKRW cancelledAt label reserveId userId"),
        Map.entry(
            "allocations",
            "allocationId amountKRW obligationId releaseEvidence releasedKRW reserveId userId"
        ),
        Map.entry(
            "settlements",
            "allocatedKRW evidenceRefs invalidatedAt linkId method obligationId transactionId userId"
        ),
        Map.entry("recurringPlans", "firstOccurrenceMonth planId userId"),
        Map.entry(
            "recurringDecisions",
            "candidateKey decision decisionId evidenceTransactionIds normalizedName planId ruleVersion sourceVersion userId"
        ),
        Map.entry(
            "recurringPlanRevisions",
            "amountKRW cardId effectiveFromMonth isCurrent label monthlyDay paymentTiming planId revisionId scheduleBasis scheduleOverrides status userId withdrawalAccountId"
        ),
        Map.entry("transactionRelations", "evidenceRef fromId kind toId"),
        Map.entry(
            "occurrenceLinks",
            "evidenceRef obligationId purchaseTransactionId recurrenceKey statementId"
        ),
        Map.entry(
            "occurrenceOverrides",
            "amountKRW dueDate planRevisionId recurrenceKey status userId withdrawalAccountId"
        ),
        Map.entry("referenceResolutions", "reason status transactionId")
    );

    /**
     * 금융 배열과 중첩 공개 필드를 검사한다. 누락된 취소일만 기존 v3의 선택 필드로 허용한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection.Context 생성자
     * @modified 2026-10-30 - 계좌 원천 상태를 posted/unknown으로 제한하고 카드 상태는 유지
     * @modified 2026-10-30 - 저장 버전별 items 필수 여부와 v4 청구 원천의 전체 제약 검증
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 잔액 기준 시각과 거래 사실의 시간 경계를 공개 전에 검사
     */
    static void validate(ObjectNode source) {
        String schema = text(source, ApiFieldConstants.Finance.SCHEMA_VERSION);
        if (!Set.of(ApiConfigConstants.Finance.DRAFT_V3, ApiConfigConstants.Finance.DRAFT_V4)
            .contains(schema)) {
            throw unavailable();
        }

        boolean v4 = schema.equals(ApiConfigConstants.Finance.DRAFT_V4);
        FIELDS.forEach(
            (group, fields) -> {
                for (ObjectNode row : rows(source, group)) {
                    boolean transaction = group.equals(ApiFieldConstants.Finance.TRANSACTIONS)
                        || group.equals(ApiFieldConstants.Finance.RELATED_TRANSACTIONS);
                    String allowed = v4 && group.equals(ApiFieldConstants.Finance.STATEMENTS)
                        ? fields + ApiConfigConstants.Finance.ITEMS_SUFFIX
                        : fields;
                    keys(
                        row,
                        allowed,
                        transaction ? Set.of(ApiFieldConstants.Finance.CANCELLATION_DATE) : Set.of()
                    );
                    if (transaction && row.path(ApiFieldConstants.Finance.RECORD_KIND)
                        .asString("")
                        .equals(ApiCodeConstants.Finance.ACCOUNT_ENTRY)) {
                        JsonNode status = row.get(ApiFieldConstants.Finance.STATUS);
                        if (!status.isString() || !Set
                            .of(ApiCodeConstants.Finance.POSTED, ApiCodeConstants.Finance.UNKNOWN)
                            .contains(status.asString())) {
                            throw unavailable();
                        }
                    }
                }
            }
        );
        sourceTimes(source);
        if (v4) {
            statementItems(source);
        }
        ObjectNode settings = objectAt(source, ApiCodeConstants.Finance.SETTINGS);
        keys(settings, ApiFieldConstants.Finance.SETTINGS_FIELDS, Set.of());
        ObjectNode salary = objectAt(settings, ApiFieldConstants.Finance.SALARY);
        keys(salary, ApiFieldConstants.Finance.SALARY_FIELDS, Set.of());
        for (ObjectNode row : rows(salary, ApiFieldConstants.Finance.RECEIPT_EVIDENCE)) {
            keys(row, ApiFieldConstants.Finance.RECEIPT_FIELDS, Set.of());
        }
        for (ObjectNode row : rows(settings, ApiFieldConstants.Finance.CARD_PLANS)) {
            keys(row, ApiFieldConstants.Finance.CARD_PLAN_FIELDS, Set.of());
        }

        nested(
            source,
            ApiFieldConstants.Finance.CARDS,
            ApiFieldConstants.Finance.SCHEDULE_EVIDENCE,
            ApiFieldConstants.Finance.SCHEDULE_FIELDS
        );
        nested(
            source,
            ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS,
            ApiFieldConstants.Finance.SCHEDULE_OVERRIDES,
            ApiFieldConstants.Finance.OVERRIDE_FIELDS
        );
        nested(
            source,
            ApiFieldConstants.Finance.ALLOCATIONS,
            ApiFieldConstants.Finance.RELEASE_EVIDENCE,
            ApiFieldConstants.Finance.RELEASE_FIELDS
        );
        nested(
            source,
            ApiFieldConstants.Finance.COVERAGE,
            ApiFieldConstants.Finance.COVERED_RANGES,
            ApiFieldConstants.Finance.PERIOD_FIELDS
        );
        nested(
            source,
            ApiFieldConstants.Finance.COVERAGE,
            ApiFieldConstants.Finance.MISSING_RANGES,
            ApiFieldConstants.Finance.PERIOD_FIELDS
        );
        for (ObjectNode row : rows(source, ApiFieldConstants.Finance.SETTLEMENTS)) {
            FinancialProjection.strings(row, ApiFieldConstants.Finance.EVIDENCE_REFS);
        }
    }

    /**
     * 원천 묶음의 기준 시각과 잔액을 맞추고 실제 거래만 확보 시각 안으로 제한한다.
     * 예정일·사용자 기록 시각을 현재 거래로 바꾸거나 조회 시각을 원천에 쓰지 않는다.
     * @created 2026-11-02
     * @usedBy validate
     */
    private static void sourceTimes(ObjectNode source) {
        OffsetDateTime asOf = OffsetDateTime.parse(text(source, Finance.AS_OF));
        LocalDate businessDate = asOf
            .atZoneSameInstant(ZoneId.of(ApiConfigConstants.Finance.SEOUL_ZONE))
            .toLocalDate();
        for (ObjectNode account : rows(source, Finance.ACCOUNTS)) {
            OffsetDateTime balanceTime = OffsetDateTime.parse(text(account, Finance.AS_OF));
            if (!balanceTime.isEqual(asOf)) {
                throw unavailable();
            }
        }

        List<String> factDates = List.of(
            Finance.PURCHASE_DATE,
            Finance.WITHDRAWAL_DATE,
            Finance.REFUND_DATE,
            Finance.CANCELLATION_DATE,
            Finance.BOOKING_DATE
        );
        for (String group : List.of(Finance.TRANSACTIONS, Finance.RELATED_TRANSACTIONS)) {
            for (ObjectNode transaction : rows(source, group)) {
                for (String field : factDates) {
                    JsonNode value = transaction.get(field);
                    if (value == null || value.isNull()) {
                        continue;
                    }
                    String date = text(transaction, field);
                    if (!date.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")
                        || date.startsWith("0000")
                        || LocalDate.parse(date).isAfter(businessDate)) {
                        throw unavailable();
                    }
                }
                if (!required(transaction, Finance.OCCURRED_AT).isNull()) {
                    OffsetDateTime occurredAt = OffsetDateTime.parse(
                        text(transaction, Finance.OCCURRED_AT)
                    );
                    if (occurredAt.isAfter(asOf)) {
                        throw unavailable();
                    }
                }
            }
        }
    }

    /**
     * 청구 항목을 별도 원천으로 검증하며 거래 연결에서 금액·날짜를 복사하거나 계산하지 않는다.
     * @created 2026-10-30
     * @usedBy validate
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void statementItems(ObjectNode source) {
        String owner = id(source, ApiFieldConstants.Finance.USER_ID);
        String version = text(source, ApiFieldConstants.Finance.SOURCE_VERSION);
        if (version.isBlank()) {
            throw unavailable();
        }

        LocalDate asOf = OffsetDateTime.parse(text(source, ApiFieldConstants.Finance.AS_OF))
            .atZoneSameInstant(ZoneId.of(ApiConfigConstants.Finance.SEOUL_ZONE))
            .toLocalDate();
        Map<String, ObjectNode> transactions = new HashMap<>();
        for (String group : List.of(
            ApiFieldConstants.Finance.TRANSACTIONS,
            ApiFieldConstants.Finance.RELATED_TRANSACTIONS
        )) {
            for (ObjectNode row : rows(source, group)) {
                ObjectNode previous = transactions
                    .putIfAbsent(id(row, ApiFieldConstants.Finance.TRANSACTION_ID), row);
                if (previous != null && !previous.equals(row)) {
                    throw unavailable();
                }
            }
        }

        Set<String> identities = new HashSet<>();
        Set<String> sourceRefs = new HashSet<>();
        for (ObjectNode statement : rows(source, ApiFieldConstants.Finance.STATEMENTS)) {
            if (!owner.equals(id(statement, ApiFieldConstants.Finance.USER_ID))
                || !version.equals(text(statement, ApiFieldConstants.Finance.SOURCE_VERSION))) {
                throw unavailable();
            }

            String card = id(statement, ApiFieldConstants.Finance.CARD_ID);
            LinkedHashSet<String> references = new LinkedHashSet<>();
            for (ObjectNode item : rows(statement, ApiFieldConstants.Finance.ITEMS)) {
                keys(item, ApiFieldConstants.Finance.ITEM_FIELDS, Set.of());
                if (!identities.add(id(item, ApiFieldConstants.Finance.ITEM_ID))
                    || !owner.equals(id(item, ApiFieldConstants.Finance.USER_ID))
                    || !version.equals(text(item, ApiFieldConstants.Finance.SOURCE_VERSION))) {
                    throw unavailable();
                }

                String sourceRef = text(item, ApiFieldConstants.Finance.SOURCE_REF);
                if (sourceRef.isBlank() || !sourceRefs.add(sourceRef)) {
                    throw unavailable();
                }

                itemValues(item, asOf);
                if (!required(item, ApiFieldConstants.Finance.TRANSACTION_ID).isNull()) {
                    String transactionId = id(item, ApiFieldConstants.Finance.TRANSACTION_ID);
                    ObjectNode transaction = transactions.get(transactionId);
                    if (transaction == null
                        || !owner.equals(id(transaction, ApiFieldConstants.Finance.USER_ID))
                        || !card.equals(id(transaction, ApiFieldConstants.Finance.CARD_ID))) {
                        throw unavailable();
                    }

                    references.add(transactionId);
                }
            }

            if (!strings(statement, ApiFieldConstants.Finance.INCLUDED_TRANSACTION_REFS)
                .equals(List.copyOf(references))) {
                throw unavailable();
            }
        }
    }

    /**
     * 청구 원천의 null·부호·정수 범위·확인 이용일·할부 순서를 검사한다.
     * @created 2026-10-30
     * @usedBy statementItems
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void itemValues(ObjectNode item, LocalDate asOf) {
        for (String field : List
            .of(ApiFieldConstants.Finance.LABEL, ApiFieldConstants.Finance.MERCHANT_NAME)) {
            JsonNode value = required(item, field);
            if (!value.isNull() && !value.isString()) {
                throw unavailable();
            }
        }

        JsonNode purchase = required(item, ApiFieldConstants.Finance.PURCHASE_DATE);
        if (!purchase.isNull()) {
            String value = text(item, ApiFieldConstants.Finance.PURCHASE_DATE);
            if (!value.matches("[0-9]{4}-[0-9]{2}-[0-9]{2}")
                || value.startsWith(ApiConfigConstants.Finance.INVALID_YEAR)) {
                throw unavailable();
            }
            if (LocalDate.parse(value).isAfter(asOf)) {
                throw unavailable();
            }
        }
        amount(required(item, ApiFieldConstants.Finance.ORIGINAL_USED_AMOUNT_KRW), false);
        amount(required(item, ApiFieldConstants.Finance.BILLED_PRINCIPAL_KRW), false);
        amount(required(item, ApiFieldConstants.Finance.FEE_OR_ADJUSTMENT_AMOUNT_KRW), true);
        amount(required(item, ApiFieldConstants.Finance.BILLED_AMOUNT_KRW), true);
        JsonNode months = required(item, ApiFieldConstants.Finance.INSTALLMENT_MONTHS);
        JsonNode round = required(item, ApiFieldConstants.Finance.INSTALLMENT_ROUND);
        for (JsonNode value : List.of(months, round)) {
            if (!value.isNull()
                && (!value.isIntegralNumber() || !value.canConvertToInt() || value.asInt() <= 0)) {
                throw unavailable();
            }
        }

        if (!months.isNull() && !round.isNull() && round.asInt() > months.asInt()) {
            throw unavailable();
        }
    }

    /**
     * 확인된 원화 정수만 허용하며 음수는 호출부가 지정한 두 청구 항목 필드에만 허용한다.
     * @created 2026-10-30
     * @usedBy itemValues
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void amount(JsonNode value, boolean signed) {
        if (value.isNull()) {
            return;
        }
        if (!value.isIntegralNumber() || !value.canConvertToLong()
            || value.asLong() < (signed ? -MAX_MONEY : 0) || value.asLong() > MAX_MONEY) {
            throw unavailable();
        }
    }

    /**
     * 중첩 배열도 임의 필드를 전달하는 우회 경로로 사용하지 못하게 한다.
     * @created 2026-10-29
     * @usedBy FinancialShape.validate
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void nested(ObjectNode source, String group, String field, String fields) {
        for (ObjectNode row : rows(source, group)) {
            for (ObjectNode child : rows(row, field)) {
                keys(child, fields, Set.of());
            }
        }
    }

    /**
     * 허용 목록 밖의 필드와 필수 필드 누락을 정상 값으로 묵시 변환하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialShape.validate, nested
     * @modified 2026-10-30 - v4 청구 항목 배열도 허용 키·배열 검사에 포함
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private static void keys(ObjectNode row, String fieldNames, Set<String> optional) {
        Set<String> allowed = Set.copyOf(Arrays.asList(fieldNames.split(" ")));
        Set<String> actual = Set.copyOf(row.propertyNames());
        if (!allowed.containsAll(actual)) {
            throw unavailable();
        }

        for (String field : allowed) {
            if (!optional.contains(field) && !actual.contains(field)) {
                throw unavailable();
            }
        }

        Set<String> containers = Set.of(
            ApiFieldConstants.Finance.SALARY,
            ApiFieldConstants.Finance.CARD_PLANS,
            ApiFieldConstants.Finance.RECEIPT_EVIDENCE,
            ApiFieldConstants.Finance.COVERED_RANGES,
            ApiFieldConstants.Finance.MISSING_RANGES,
            ApiFieldConstants.Finance.SCHEDULE_EVIDENCE,
            ApiFieldConstants.Finance.INCLUDED_TRANSACTION_REFS,
            ApiFieldConstants.Finance.RELEASE_EVIDENCE,
            ApiFieldConstants.Finance.EVIDENCE_REFS,
            ApiFieldConstants.Finance.EVIDENCE_TRANSACTION_IDS,
            ApiFieldConstants.Finance.SCHEDULE_OVERRIDES,
            ApiFieldConstants.Finance.TRANSACTION_IDS,
            ApiFieldConstants.Finance.ITEMS
        );
        for (String field : actual) {
            JsonNode value = row.get(field);
            if (value.isContainer() && !containers.contains(field)) {
                throw unavailable();
            }
            if (containers.contains(field) && !field.equals(ApiFieldConstants.Finance.SALARY)
                && !value.isArray()) {
                throw unavailable();
            }
        }
    }
}
