package com.payse.ai.analysis.validation;

import static com.payse.ai.analysis.validation.SchemaRules.require;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.LocalDate;
import java.time.LocalTime;
import java.time.DateTimeException;
import java.util.regex.Pattern;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 공개 업무 규격·근거 관계만 검증한다. 세션·소유권·DB 원천 확인은 API 책임이다.
 * @created 2026-11-01
 * @usedBy AnalysisService, InputMapper
 */
public final class AnalysisContract {
    private static final Set<String> TASKS = Set.of("transactionMeaning", "recurringMeaning");
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final Pattern SOURCE_TIME = Pattern.compile(
        "^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})(?:(?::([0-9]{2})(?::([0-9]{2}))?)|([0-9]{2})([0-9]{2})?)?(?:[.,][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$");
    private final Map<String, ObjectNode> schemas = new HashMap<>();
    private final String instructions;

    /**
     * 운영 JAR의 공개 기준과 스키마만 읽는다. 파일 누락·미지원 스키마는 시작 시 실패한다.
     * @created 2026-11-01
     * @usedBy AnalysisService 생성자, 계약 테스트
     */
    public AnalysisContract() {
        for (String task : TASKS) {
            for (String side : new String[] {"input", "output"}) {
                String name = task + "." + side + ".schema.json";
                ObjectNode schema = (ObjectNode) JSON.readTree(resource(name));
                SchemaRules.supported(schema);
                schemas.put(name, schema);
            }
        }
        instructions = resource("instructions.txt") + "\n" + resource("criteria.json");
    }

    /**
     * 예시·정답을 포함하지 않는 고정 지침과 공개 의미 기준을 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    public String instructions() { return instructions; }

    /**
     * 호출자가 공유 기준을 바꾸지 못하도록 업무 출력 스키마 사본을 반환한다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자
     */
    public ObjectNode outputSchema(String task) { return schema(task, "output").deepCopy(); }

    /**
     * 기존 Python 계약과 같은 입력 구조·식별·원천 참조·로컬 후보 조건을 검사한다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자, output
     */
    public void input(JsonNode payload) {
        require(payload != null && payload.isObject(), "INVALID_INPUT");
        String task = payload.path("semanticTaskKind").asString("");
        SchemaRules.check(schema(task, "input"), payload);
        JsonNode context = payload.get("context");
        try {
            Long.parseLong(context.get("dataVersion").asString());
            sourceTime(context.get("asOf").asString());
        } catch (NumberFormatException | DateTimeException failure) {
            throw new ContractFailure("INVALID_CONTEXT");
        }
        ids(context.get("selectedAccountIds"));
        Map<String, JsonNode> transactions = keyed(payload.get("transactions"), "transactionId");
        Map<String, JsonNode> unavailable = keyed(payload.get("unavailableReferences"), "transactionId");
        require(java.util.Collections.disjoint(transactions.keySet(), unavailable.keySet()), "CONFLICTING_AVAILABILITY");
        Map<String, JsonNode> candidates = keyed(payload.get("candidates"), "candidateKey");
        Map<String, JsonNode> current = keyed(payload.get("currentClassifications"), "transactionId");
        require(transactions.keySet().containsAll(current.keySet()), "CLASSIFICATION_OUTSIDE_EVIDENCE");
        originals(transactions, unavailable.keySet());
        relations(payload.get("relations"), transactions);
        items(payload, task, context, transactions, unavailable.keySet(), candidates);
    }

    /**
     * 기존 Python ISO 입력의 실제 날짜·시각·오프셋만 검증한다. 원문 정밀도·시각을 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy input
     */
    private void sourceTime(String source) {
        var match = SOURCE_TIME.matcher(source);
        require(match.matches(), "INVALID_CONTEXT");
        require(LocalDate.parse(match.group(1)).getYear() >= 1, "INVALID_CONTEXT");
        String minute = match.group(3) != null ? match.group(3) : match.group(5);
        String second = match.group(4) != null ? match.group(4) : match.group(6);
        LocalTime.of(Integer.parseInt(match.group(2)), minute == null ? 0 : Integer.parseInt(minute),
            second == null ? 0 : Integer.parseInt(second));
        String offset = match.group(7);
        if (!"Z".equals(offset)) {
            int offsetMinutes = Integer.parseInt(offset.substring(1, 3)) * 60 + Integer.parseInt(offset.substring(4, 6));
            require(offsetMinutes < 24 * 60, "INVALID_CONTEXT");
        }
    }

    /**
     * 원거래가 미제공으로 표시되었는지 확인하고 순환·계좌 미지원 상태를 거절한다.
     * @created 2026-11-01
     * @usedBy input
     */
    private void originals(Map<String, JsonNode> transactions, Set<String> unavailable) {
        for (var entry : transactions.entrySet()) {
            JsonNode row = entry.getValue();
            if ("account_entry".equals(row.get("recordKind").asString())) {
                require(Set.of("posted", "unknown").contains(row.get("status").asString()), "UNSUPPORTED_ACCOUNT_STATUS");
            }
            JsonNode original = row.get("originalTransactionId");
            if (!original.isNull()) require(transactions.containsKey(original.asString()) || unavailable.contains(original.asString()), "UNRESOLVED_ORIGINAL");
            Set<String> visited = new HashSet<>();
            String cursor = entry.getKey();
            while (transactions.containsKey(cursor)) {
                require(visited.add(cursor), "CYCLIC_ORIGINAL");
                cursor = transactions.get(cursor).get("originalTransactionId").asString(null);
            }
        }
    }

    /**
     * 명시된 관계의 종류·방향·양 끝을 확인하며 관계를 추정 생성하지 않는다.
     * @created 2026-11-01
     * @usedBy input
     */
    private void relations(JsonNode rows, Map<String, JsonNode> transactions) {
        Set<String> seen = new HashSet<>();
        for (JsonNode row : rows) {
            String from = row.get("fromId").asString();
            String to = row.get("toId").asString();
            String kind = row.get("kind").asString();
            String pair = from.compareTo(to) < 0 ? from + to : to + from;
            require(!from.equals(to) && seen.add(kind + pair), "DUPLICATE_RELATION");
            require(transactions.containsKey(from) && transactions.containsKey(to), "RELATION_OUTSIDE_EVIDENCE");
            JsonNode first = transactions.get(from);
            JsonNode second = transactions.get(to);
            if ("internal_transfer".equals(kind)) {
                require("account_entry".equals(first.get("recordKind").asString())
                    && "account_entry".equals(second.get("recordKind").asString())
                    && !first.get("direction").equals(second.get("direction")), "INVALID_TRANSFER");
            } else {
                Set<String> kinds = new HashSet<>();
                kinds.add(first.get("recordKind").asString());
                kinds.add(second.get("recordKind").asString());
                require(kinds.equals(Set.of("account_entry", "card_purchase")), "INVALID_CARD_PAIR");
            }
        }
    }

    /**
     * 항목 대상과 완전한 근거 집합을 확인하고 Flutter의 후보 조건을 재계산 없이 검증한다.
     * @created 2026-11-01
     * @usedBy input
     */
    private void items(JsonNode payload, String task, JsonNode context, Map<String, JsonNode> transactions,
            Set<String> unavailable, Map<String, JsonNode> candidates) {
        Map<String, JsonNode> items = keyed(payload.get("items"), "itemKey");
        Set<String> targets = new HashSet<>();
        Set<String> evidence = new HashSet<>();
        for (JsonNode item : items.values()) {
            Set<String> refs = ids(item.get("evidenceTransactionIds"));
            evidence.addAll(refs);
            require(transactions.keySet().containsAll(refs), "ITEM_OUTSIDE_EVIDENCE");
            String target;
            if ("transactionMeaning".equals(task)) {
                target = item.get("targetTransactionId").asString();
                require(refs.contains(target) && item.get("candidateKey").isNull(), "TARGET_MISMATCH");
            } else {
                target = item.get("candidateKey").asString();
                JsonNode candidate = candidates.get(target);
                require(candidate != null && item.get("targetTransactionId").isNull(), "CANDIDATE_MISMATCH");
                require(refs.equals(ids(candidate.get("evidenceTransactionIds"))), "CANDIDATE_EVIDENCE_MISMATCH");
                require(candidate.get("ruleVersion").equals(context.get("ruleVersion"))
                    && candidate.get("sourceVersion").equals(context.get("sourceVersion")), "CANDIDATE_VERSION_MISMATCH");
                JsonNode features = candidate.get("features");
                require(features.get("occurrenceCount").bigIntegerValue().compareTo(java.math.BigInteger.valueOf(3)) >= 0
                    && ids(features.get("observedMonths")).size() >= 3
                    && features.get("dayWithinRule").asBoolean() && features.get("amountWithinRule").asBoolean()
                    && !features.get("hasUnresolvedReversal").asBoolean(), "LOCAL_CANDIDATE_NOT_READY");
            }
            require(targets.add(target), "DUPLICATE_TARGET");
        }
        if ("recurringMeaning".equals(task)) require(targets.equals(candidates.keySet()), "UNUSED_CANDIDATE");
        require(transactions.keySet().equals(evidence), "UNUSED_EVIDENCE");
        Set<String> originals = new HashSet<>();
        for (JsonNode transaction : transactions.values()) originals.add(transaction.get("originalTransactionId").asString(null));
        require(originals.containsAll(unavailable), "UNUSED_UNAVAILABLE_REFERENCE");
    }

    /**
     * 완결 출력만 허용하고 기존 분류·허용 근거·관계 경계를 보존한다.
     * @created 2026-11-01
     * @usedBy InputMapper.restore
     */
    public void output(JsonNode payload, JsonNode result) {
        input(payload);
        String task = payload.get("semanticTaskKind").asString();
        SchemaRules.check(schema(task, "output"), result);
        Map<String, JsonNode> requested = keyed(payload.get("items"), "itemKey");
        Map<String, JsonNode> received = keyed(result.get("items"), "itemKey");
        require(requested.keySet().equals(received.keySet()), "INCOMPLETE_ITEMS");
        Map<String, JsonNode> current = keyed(payload.get("currentClassifications"), "transactionId");
        for (var entry : received.entrySet()) {
            JsonNode row = entry.getValue();
            JsonNode item = requested.get(entry.getKey());
            Set<String> refs = ids(item.get("evidenceTransactionIds"));
            require(refs.containsAll(ids(row.get("evidenceTransactionIds"))), "OUTPUT_OUTSIDE_EVIDENCE");
            decision(row.get("meaning"));
            if ("recurringMeaning".equals(task)) {
                require(row.get("candidateKey").equals(item.get("candidateKey")), "INVENTED_CANDIDATE");
                continue;
            }
            decision(row.get("classification"));
            String target = item.get("targetTransactionId").asString();
            String basic = row.get("classification").get("value").asString(null);
            String existing = current.containsKey(target) ? current.get(target).get("value").asString(null) : null;
            if (basic != null && existing != null) require(basic.equals(existing), "EXISTING_CLASSIFICATION_CONFLICT");
            if ("card_payment".equals(basic)) require(basic.equals(existing), "MISSING_BILL_SETTLEMENT_EVIDENCE");
            if ("internal_transfer".equals(basic) && !basic.equals(existing)) {
                boolean linked = false;
                for (JsonNode relation : payload.get("relations")) {
                    String from = relation.get("fromId").asString();
                    String to = relation.get("toId").asString();
                    linked |= "internal_transfer".equals(relation.get("kind").asString())
                        && (target.equals(from) || target.equals(to)) && refs.contains(from) && refs.contains(to);
                }
                require(linked, "MISSING_TRANSFER_EVIDENCE");
            }
        }
    }

    /**
     * candidate·unknown 상태와 값·사유가 서로 모순되지 않는지 검사한다.
     * @created 2026-11-01
     * @usedBy output
     */
    private void decision(JsonNode decision) {
        boolean known = "candidate".equals(decision.get("status").asString());
        require(known == !decision.get("value").isNull()
            && known == "supported".equals(decision.get("reasonCode").asString()), "DECISION_MISMATCH");
    }

    /**
     * 승인된 두 업무 외의 스키마 이름·임의 리소스 접근을 거절한다.
     * @created 2026-11-01
     * @usedBy input, output, outputSchema
     */
    private ObjectNode schema(String task, String side) {
        require(TASKS.contains(task), "UNKNOWN_TASK");
        return schemas.get(task + "." + side + ".schema.json");
    }

    /**
     * 중복 식별자를 덮어쓰지 않는 인덱스를 만든다.
     * @created 2026-11-01
     * @usedBy input, items, output
     */
    private Map<String, JsonNode> keyed(JsonNode rows, String field) {
        Map<String, JsonNode> result = new LinkedHashMap<>();
        for (JsonNode row : rows) require(result.putIfAbsent(row.get(field).asString(), row) == null, "DUPLICATE_ID");
        return result;
    }

    /**
     * 참조 중복을 오류로 유지한다.
     * @created 2026-11-01
     * @usedBy input, items, output
     */
    private Set<String> ids(JsonNode values) {
        Set<String> result = new HashSet<>();
        for (JsonNode value : values) require(result.add(value.asString()), "DUPLICATE_REFERENCE");
        return result;
    }

    /**
     * 클래스 경로의 공개 리소스만 읽으며 파일 시스템·비공개 평가 자료를 탐색하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisContract 생성자
     */
    private String resource(String name) {
        try (var stream = AnalysisContract.class.getResourceAsStream("/com/payse/ai/rules/" + name)) {
            if (stream == null) throw new IllegalStateException("AI public resource missing");
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException failure) {
            throw new IllegalStateException("AI public resource unavailable");
        }
    }
}
