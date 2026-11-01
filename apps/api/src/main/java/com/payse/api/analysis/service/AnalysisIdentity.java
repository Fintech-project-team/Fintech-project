package com.payse.api.analysis.service;

import com.payse.api.finance.error.FinancialException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 임시 itemKey·묶음·화면 버전과 독립적인 기억 및 관련 의미 근거를 식별한다.
 * @created 2026-11-01
 * @usedBy AnalysisJobs, AnalysisResults
 */
public final class AnalysisIdentity {
    /**
     * 같은 의미 대상의 중복 항목을 거절하고 현재 요청의 항목 식별을 만든다.
     * @created 2026-11-01
     * @usedBy hint, AnalysisResults
     */
    public List<Item> items(ObjectNode input) {
        List<Item> result = new ArrayList<>();
        Set<String> targets = new HashSet<>();
        String kind = input.path("semanticTaskKind").asString();
        for (JsonNode item : input.path("items")) {
            Set<String> ids = new HashSet<>();
            item.path("evidenceTransactionIds").forEach(id -> ids.add(id.asString()));
            ObjectNode identity = AnalysisJson.JSON.createObjectNode().put("kind", kind);
            if (kind.equals("transactionMeaning")) {
                identity.set("target", item.get("targetTransactionId"));
            } else {
                var evidence = identity.putArray("evidence");
                ids.stream().sorted().forEach(evidence::add);
            }
            String key = AnalysisJson.digest(identity);
            if (!targets.add(key)) throw new FinancialException(422, "VALIDATION_FAILED");
            Set<String> direct = Set.copyOf(ids);
            boolean expanded;
            do {
                expanded = false;
                for (JsonNode transaction : input.path("transactions")) {
                    if (ids.contains(transaction.path("transactionId").asString())
                            && transaction.path("originalTransactionId").isString()) {
                        expanded |= ids.add(transaction.path("originalTransactionId").asString());
                    }
                }
                for (JsonNode relation : input.path("relations")) {
                    String from = relation.path("fromId").asString();
                    String to = relation.path("toId").asString();
                    if (ids.contains(from) || ids.contains(to)) {
                        expanded |= ids.add(from);
                        expanded |= ids.add(to);
                    }
                }
            } while (expanded);
            ObjectNode facts = AnalysisJson.JSON.createObjectNode();
            for (String field : List.of("transactions", "currentClassifications", "unavailableReferences")) {
                var selected = facts.putArray(field);
                List<JsonNode> rows = new ArrayList<>();
                for (JsonNode row : input.path(field)) {
                    if (ids.contains(row.path("transactionId").asString())) rows.add(row);
                }
                rows.sort(Comparator.comparing(row -> row.path("transactionId").asString()));
                rows.forEach(row -> selected.add(row.deepCopy()));
            }
            List<JsonNode> relations = new ArrayList<>();
            for (JsonNode relation : input.path("relations")) {
                if (ids.contains(relation.path("fromId").asString())
                        || ids.contains(relation.path("toId").asString())) relations.add(relation);
            }
            relations.sort(Comparator.comparing(row -> AnalysisJson.canonical(row).toString()));
            var links = facts.putArray("relations");
            relations.forEach(row -> links.add(row.deepCopy()));
            for (JsonNode candidate : input.path("candidates")) {
                if (candidate.path("candidateKey").equals(item.path("candidateKey"))) {
                    ObjectNode local = (ObjectNode) candidate.deepCopy();
                    local.remove(List.of("candidateKey", "sourceVersion", "ruleVersion"));
                    var ordered = local.putArray("evidenceTransactionIds");
                    direct.stream().sorted().forEach(ordered::add);
                    // observedMonths는 순서 없는 월 집합이며 숫자·날짜를 서버에서 재계산하지 않는다.
                    ObjectNode features = (ObjectNode) local.get("features");
                    List<String> months = new ArrayList<>();
                    features.path("observedMonths").forEach(month -> months.add(month.asString()));
                    var sorted = features.putArray("observedMonths");
                    months.stream().sorted().forEach(sorted::add);
                    facts.set("candidate", local);
                }
            }
            result.add(new Item(item.path("itemKey").asString(), key, AnalysisJson.digest(facts)));
        }
        return List.copyOf(result);
    }

    /**
     * Flutter와 대조할 입력 지문이다. 사용자 범위는 DB 검색 키로 별도 강제한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     */
    public String hint(ObjectNode input) {
        ObjectNode body = AnalysisJson.JSON.createObjectNode()
            .put("semanticTaskKind", input.path("semanticTaskKind").asString());
        var rows = body.putArray("items");
        items(input).stream().sorted(Comparator.comparing(Item::key)).forEach(item -> rows.addObject()
            .put("memoryKey", item.key()).put("evidenceHash", item.evidenceHash()));
        return AnalysisJson.digest(body);
    }

    /**
     * 같은 원천이라도 다른 승인 모델·프롬프트·정책의 결과는 캐시로 섞지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     */
    public String inputHash(ObjectNode input, ObjectNode versions) {
        ObjectNode key = AnalysisJson.JSON.createObjectNode().put("input", hint(input));
        key.set("versions", versions.deepCopy());
        key.set("contractVersion", input.get("contractVersion"));
        key.set("schemaVersion", input.path("context").get("schemaVersion"));
        key.set("ruleVersion", input.path("context").get("ruleVersion"));
        return AnalysisJson.digest(key);
    }

    /**
     * 공개 힌트와 별도로 항목별 실제 원천을 결합한다. 무관한 거래·전체 버전은 포함하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisResults의 저장·재사용·삭제 식별
     */
    public List<Item> boundItems(ObjectNode source, ObjectNode input) {
        List<Item> bound = new ArrayList<>();
        for (Item identity : items(input)) {
            JsonNode item = null;
            for (JsonNode candidate : input.path("items")) {
                if (candidate.path("itemKey").asString().equals(identity.itemKey())) item = candidate;
            }
            if (item == null) throw new IllegalStateException("Missing analysis item");
            Set<String> ids = new HashSet<>();
            item.path("evidenceTransactionIds").forEach(id -> ids.add(id.asString()));
            boolean expanded;
            do {
                expanded = false;
                for (JsonNode transaction : input.path("transactions")) {
                    if (ids.contains(transaction.path("transactionId").asString()) && transaction.path("originalTransactionId").isString()) {
                        expanded |= ids.add(transaction.path("originalTransactionId").asString());
                    }
                }
                for (JsonNode relation : input.path("relations")) {
                    String from = relation.path("fromId").asString();
                    String to = relation.path("toId").asString();
                    if (ids.contains(from) || ids.contains(to)) {
                        expanded |= ids.add(from);
                        expanded |= ids.add(to);
                    }
                }
            } while (expanded);
            ObjectNode facts = rawFacts(source, ids).put("meaningEvidence", identity.evidenceHash());
            bound.add(new Item(identity.itemKey(), identity.key(), AnalysisJson.digest(facts)));
        }
        return List.copyOf(bound);
    }

    /**
     * 서버 원천 지문을 최종 실행 식별에 추가하되 Flutter 힌트 규격은 유지한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 접수·실행 중복 확인
     */
    public String boundInputHash(ObjectNode source, ObjectNode input, ObjectNode versions) {
        ObjectNode key = AnalysisJson.JSON.createObjectNode().put("input", inputHash(input, versions));
        var facts = key.putArray("source");
        boundItems(source, input).stream().sorted(Comparator.comparing(Item::key)).forEach(item -> facts.addObject()
            .put("memoryKey", item.key()).put("evidenceHash", item.evidenceHash()));
        return AnalysisJson.digest(key);
    }

    /**
     * 관련 원천 값만 정렬하며 사용자 ID·원천 전체 버전·공급자 추적값은 기억 의미와 분리한다.
     * @created 2026-11-01
     * @usedBy boundItems, sourceHash
     */
    private ObjectNode rawFacts(ObjectNode source, Set<String> ids) {
        ObjectNode facts = AnalysisJson.JSON.createObjectNode();
        for (String field : List.of("transactions", "relatedTransactions", "referenceResolutions")) {
            List<ObjectNode> rows = new ArrayList<>();
            for (JsonNode value : source.path(field)) {
                if (!ids.contains(value.path("transactionId").asString())) continue;
                ObjectNode row = (ObjectNode) value.deepCopy();
                row.remove(List.of("userId", "sourceVersion", "sourceRef"));
                rows.add(row);
            }
            rows.sort(Comparator.comparing(row -> row.path("transactionId").asString()));
            var selected = facts.putArray(field);
            rows.forEach(selected::add);
        }
        return facts;
    }

    /**
     * 실행 중 관련 원천의 금액·날짜 변경도 감지한다. 값의 의미를 계산하거나 모델에 추가하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 전송·채택 재검증
     */
    public String sourceHash(ObjectNode source, ObjectNode input) {
        Set<String> ids = new HashSet<>();
        input.path("transactions").forEach(value -> ids.add(value.path("transactionId").asString()));
        input.path("unavailableReferences").forEach(value -> ids.add(value.path("transactionId").asString()));
        ObjectNode facts = rawFacts(source, ids);
        facts.set("ruleVersion", source.get("ruleVersion"));
        return AnalysisJson.digest(facts);
    }

    /**
     * 현재 itemKey와 묶음 밖에서도 유지되는 불변 기억 식별을 구분한다.
     * @created 2026-11-01
     * @usedBy AnalysisIdentity, AnalysisResults
     */
    public record Item(String itemKey, String key, String evidenceHash) {}
}
