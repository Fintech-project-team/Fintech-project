package com.payse.api.finance.service;

import static com.payse.api.finance.service.FinancialProjection.array;
import static com.payse.api.finance.service.FinancialProjection.id;
import static com.payse.api.finance.service.FinancialProjection.nullableText;
import static com.payse.api.finance.service.FinancialProjection.object;
import static com.payse.api.finance.service.FinancialProjection.objectAt;
import static com.payse.api.finance.service.FinancialProjection.required;
import static com.payse.api.finance.service.FinancialProjection.rows;
import static com.payse.api.finance.service.FinancialProjection.strings;
import static com.payse.api.finance.service.FinancialProjection.text;
import static com.payse.api.finance.service.FinancialProjection.unavailable;

import com.payse.api.finance.dto.PageSlice;
import com.payse.api.finance.error.FinancialException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 권한 투영 후 거래를 UUID 순서로 분할하고 기간 밖 관계 근거만 요청별로 조립한다.
 * @created 2026-10-29
 * @usedBy FinancialProjection.project
 */
final class FinancialPages {
    private static final int PAGE_SIZE = 100;
    private static final Set<String> PAGE_KEYS = Set.of("userId", "schemaVersion", "currency", "dataVersion",
        "sourceVersion", "ruleVersion", "asOf", "transactions", "relatedTransactions", "referenceResolutions",
        "transactionRelations", "occurrenceLinks", "coverage", "page", "accessRestrictions");
    private static final Set<String> PAGE_ARRAYS = Set.of("transactions", "relatedTransactions", "referenceResolutions",
        "transactionRelations", "occurrenceLinks", "coverage");
    private static final ZoneId SEOUL = ZoneId.of("Asia/Seoul");

    /**
     * 검증된 공개 원천을 한 페이지로 제한한다. cursor 값은 호출자가 별도로 서명한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection.project
     * @param snapshot 공개 권한·관계가 검증된 전체 v3 Snapshot
     * @param after 첫 페이지 null 또는 검증한 cursor의 마지막 거래 ID
     * @param pageOnly Snapshot 전체가 아닌 후속 페이지 여부
     * @return 마지막 ID·후속 여부와 계약에 맞는 응답
     */
    static PageSlice slice(ObjectNode snapshot, UUID after, boolean pageOnly) {
        Map<String, ObjectNode> transactions = new LinkedHashMap<>();
        Map<String, ObjectNode> coverage = new HashMap<>();
        for (ObjectNode row : rows(snapshot, "coverage")) {
            String key = text(row, "targetKind") + ":" + id(row, "targetId");
            if (coverage.putIfAbsent(key, row) != null) throw unavailable();
        }
        Set<String> withinPeriod = new HashSet<>();
        OffsetDateTime asOf = OffsetDateTime.parse(text(snapshot, "asOf"));
        for (ObjectNode transaction : rows(snapshot, "transactions")) {
            String transactionId = id(transaction, "transactionId");
            transactions.put(transactionId, transaction);
            if (inPeriod(transaction, coverage, asOf)) withinPeriod.add(transactionId);
        }
        List<String> ordered = withinPeriod.stream().sorted().toList();
        String afterId = after == null ? null : after.toString();
        if (afterId != null && !withinPeriod.contains(afterId)) throw new FinancialException(400, "INVALID_CURSOR");
        List<String> remaining = ordered.stream().filter(value -> afterId == null || value.compareTo(afterId) > 0).toList();
        List<String> pageIds = remaining.subList(0, Math.min(PAGE_SIZE, remaining.size()));
        Set<String> pageSet = new HashSet<>(pageIds);
        ArrayNode page = array();
        for (String transactionId : pageIds) page.add(transactions.get(transactionId));

        Set<String> seeds = new LinkedHashSet<>(pageIds);
        if (!pageOnly) addSnapshotSeeds(snapshot, seeds);
        Map<String, Set<String>> edges = relationEdges(snapshot, transactions);
        Set<String> reached = traverse(seeds, transactions, edges);
        List<String> relatedIds = reached.stream().filter(value -> !withinPeriod.contains(value)).sorted().toList();
        ArrayNode related = array();
        for (String transactionId : relatedIds) related.add(transactions.get(transactionId));
        Set<String> returned = new HashSet<>(pageSet);
        returned.addAll(relatedIds);

        ArrayNode relations = array();
        for (ObjectNode row : rows(snapshot, "transactionRelations")) {
            if (pageSet.contains(text(row, "fromId")) || pageSet.contains(text(row, "toId"))) relations.add(row);
        }
        ArrayNode occurrences = array();
        for (ObjectNode row : rows(snapshot, "occurrenceLinks")) {
            String purchase = nullableText(row, "purchaseTransactionId");
            if (!pageOnly || (purchase != null && pageSet.contains(purchase))) occurrences.add(row);
        }

        ObjectNode output = snapshot.deepCopy();
        if (pageOnly) {
            for (String key : new ArrayList<>(output.propertyNames())) if (!PAGE_KEYS.contains(key)) output.remove(key);
        }
        output.set("transactions", page);
        output.set("relatedTransactions", related);
        output.set("referenceResolutions", array());
        output.set("transactionRelations", relations);
        output.set("occurrenceLinks", occurrences);
        output.set("accessRestrictions", restrictions(snapshot, returned, pageOnly));
        ObjectNode pageInfo = object().putNull("nextCursor")
            .put("dataVersion", text(snapshot, "dataVersion")).put("sourceVersion", text(snapshot, "sourceVersion"));
        output.set("page", pageInfo);
        UUID lastId = pageIds.isEmpty() ? null : UUID.fromString(pageIds.get(pageIds.size() - 1));
        return new PageSlice(output, lastId, remaining.size() > PAGE_SIZE);
    }

    /**
     * 원천 종류에 맞는 업무일을 coverage의 명시 구간과 비교한다. 급여 예상일을 만들지 않는다.
     * 날짜·시각이 모두 미확인이라 소속 기간을 판정할 수 없으면 임의 생략 대신 503을 반환한다.
     * @created 2026-10-29
     * @usedBy FinancialPages.slice
     */
    private static boolean inPeriod(ObjectNode transaction, Map<String, ObjectNode> coverage, OffsetDateTime asOf) {
        String kind = text(transaction, "recordKind");
        boolean account = kind.equals("account_entry");
        String basis = switch (kind) {
            case "account_entry" -> "booking";
            case "card_purchase" -> "purchase";
            case "card_refund" -> "refund";
            case "card_cancellation" -> "cancellation";
            default -> throw unavailable();
        };
        String dateKey = basis + "Date";
        String date = transaction.has(dateKey) ? nullableText(transaction, dateKey) : null;
        String occurred = nullableText(transaction, "occurredAt");
        if (occurred != null) {
            OffsetDateTime event = OffsetDateTime.parse(occurred);
            if (event.toInstant().isAfter(asOf.toInstant())) throw unavailable();
            if (date == null && basis.equals(nullableText(transaction, "occurredAtBasis"))) {
                date = event.atZoneSameInstant(SEOUL).toLocalDate().toString();
            }
        }
        if (date == null) throw unavailable();
        LocalDate day = LocalDate.parse(date);
        if (day.isAfter(asOf.atZoneSameInstant(SEOUL).toLocalDate())) throw unavailable();
        String target = (account ? "account:" : "card:") + text(transaction, account ? "accountId" : "cardId");
        ObjectNode range = coverage.get(target);
        if (range == null) throw unavailable();
        LocalDate start = LocalDate.parse(text(range, "requestedStart"));
        LocalDate end = LocalDate.parse(text(range, "requestedEnd"));
        if (start.isAfter(end)) throw unavailable();
        if (day.isBefore(start) || day.isAfter(end)) return false;
        boolean covered = false;
        for (ObjectNode interval : rows(range, "coveredRanges")) {
            LocalDate begin = LocalDate.parse(text(interval, "start"));
            LocalDate finish = LocalDate.parse(text(interval, "end"));
            if (!day.isBefore(begin) && !day.isAfter(finish)) covered = true;
        }
        if (!covered) throw unavailable();
        return true;
    }

    /**
     * Snapshot에서 반환한 확정 객체가 직접 가리키는 거래만 참조 탐색 시작점에 추가한다.
     * @created 2026-10-29
     * @usedBy FinancialPages.slice
     */
    private static void addSnapshotSeeds(ObjectNode snapshot, Set<String> seeds) {
        for (ObjectNode statement : rows(snapshot, "statements")) seeds.addAll(strings(statement, "includedTransactionRefs"));
        for (ObjectNode settlement : rows(snapshot, "settlements")) seeds.add(text(settlement, "transactionId"));
        for (ObjectNode decision : rows(snapshot, "recurringDecisions")) seeds.addAll(strings(decision, "evidenceTransactionIds"));
        ObjectNode salary = objectAt(objectAt(snapshot, "settings"), "salary");
        if (salary.has("receiptEvidence")) {
            for (ObjectNode proof : rows(salary, "receiptEvidence")) seeds.addAll(strings(proof, "transactionIds"));
        }
        for (ObjectNode link : rows(snapshot, "occurrenceLinks")) {
            String transaction = nullableText(link, "purchaseTransactionId");
            if (transaction != null) seeds.add(transaction);
        }
    }

    /**
     * 명시된 거래 관계와 원거래 참조로만 탐색 간선을 구성한다. 같은 금액·날짜로 추정하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialPages.slice
     */
    private static Map<String, Set<String>> relationEdges(ObjectNode snapshot, Map<String, ObjectNode> transactions) {
        Map<String, Set<String>> edges = new HashMap<>();
        for (ObjectNode relation : rows(snapshot, "transactionRelations")) {
            String from = text(relation, "fromId"), to = text(relation, "toId");
            edges.computeIfAbsent(from, ignored -> new HashSet<>()).add(to);
            edges.computeIfAbsent(to, ignored -> new HashSet<>()).add(from);
        }
        for (ObjectNode transaction : transactions.values()) {
            if (!transaction.has("originalTransactionId")) continue;
            String original = nullableText(transaction, "originalTransactionId");
            if (original != null) edges.computeIfAbsent(id(transaction, "transactionId"), ignored -> new HashSet<>()).add(original);
        }
        return edges;
    }

    /**
     * 동일 거래는 한 번만 방문하여 순환 참조를 종료하고 미확보 권한을 임의 확정하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialPages.slice
     */
    private static Set<String> traverse(Set<String> seeds, Map<String, ObjectNode> transactions,
            Map<String, Set<String>> edges) {
        ArrayDeque<String> pending = new ArrayDeque<>(seeds);
        Set<String> visited = new LinkedHashSet<>();
        while (!pending.isEmpty()) {
            String current = pending.removeFirst();
            if (!visited.add(current)) continue;
            if (!transactions.containsKey(current)) throw unavailable();
            for (String next : edges.getOrDefault(current, Set.of())) if (!visited.contains(next)) pending.addLast(next);
        }
        return visited;
    }

    /**
     * 후속 응답에 없는 부모·배열의 제한 표식은 반복하지 않고 공개된 거래의 표식을 유지한다.
     * @created 2026-10-29
     * @usedBy FinancialPages.slice
     */
    private static ArrayNode restrictions(ObjectNode snapshot, Set<String> returned, boolean pageOnly) {
        ArrayNode result = array();
        for (ObjectNode mark : rows(snapshot, "accessRestrictions")) {
            String owner = text(mark, "ownerType");
            if (owner.equals("transaction") && !returned.contains(text(mark, "ownerId"))) continue;
            if (pageOnly && !owner.equals("transaction") && !owner.equals("response")) continue;
            if (pageOnly && owner.equals("response") && !PAGE_ARRAYS.contains(text(mark, "field"))) continue;
            result.add(mark);
        }
        return result;
    }
}
