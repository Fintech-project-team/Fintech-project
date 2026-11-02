package com.payse.api.analysis.service;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiFieldConstants.Analysis;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
import com.payse.api.finance.error.FinancialException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 임시 itemKey·묶음·화면 버전과 독립적인 기억 및 관련 의미 근거를 식별한다.
 * @created 2026-11-01
 * @usedBy AnalysisJobs, AnalysisResults
 */
public final class AnalysisIdentity {

    /**
     * 모델이 선택한 일부 증거가 아닌 검증 입력의 전체 관계 연결을 항목별로 보존한다.
     * @created 2026-11-01
     * @usedBy AnalysisResults.save
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public List<UUID> sourceRefs(ObjectNode input, String itemKey) {
        JsonNode item = null;
        for (JsonNode candidate : input.path(Analysis.ITEMS)) {
            if (candidate.path(Analysis.ITEM_KEY)
                .asString()
                .equals(itemKey)) {
                item = candidate;
            }
        }

        if (item == null) {
            throw new IllegalStateException(ApiMessageConstants.Analysis.MISSING_ITEM);
        }

        Set<String> ids = new HashSet<>();
        item.path(Analysis.EVIDENCE_TRANSACTION_IDS).forEach(id -> ids.add(id.asString()));
        if (item.path(Analysis.TARGET_TRANSACTION_ID).isString()) {
            ids.add(item.path(Analysis.TARGET_TRANSACTION_ID).asString());
        }
        boolean expanded;
        do {
            expanded = false;
            for (JsonNode transaction : input.path(Analysis.TRANSACTIONS)) {
                if (ids.contains(transaction.path(Analysis.TRANSACTION_ID).asString())
                    && transaction.path(Analysis.ORIGINAL_TRANSACTION_ID).isString()) {
                    expanded |= ids
                        .add(transaction.path(Analysis.ORIGINAL_TRANSACTION_ID).asString());
                }
            }
            for (JsonNode relation : input.path(Analysis.RELATIONS)) {
                String from = relation.path(Analysis.FROM_ID).asString();
                String to = relation.path(Analysis.TO_ID).asString();
                if (ids.contains(from) || ids.contains(to)) {
                    expanded |= ids.add(from);
                    expanded |= ids.add(to);
                }
            }
        } while (expanded);
        return ids.stream()
            .sorted()
            .map(UUID::fromString)
            .toList();
    }

    /**
     * 관리 목록에 원천 변경 사실만 표시할 지문이며 실제 재사용 적격 판정을 대신하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisResults.save, MemoryCatalog.entry
     */
    public String referenceHash(ObjectNode source, List<UUID> refs) {
        Set<String> ids = new HashSet<>();
        refs.forEach(id -> ids.add(id.toString()));
        ObjectNode facts = rawFacts(source, ids);
        facts.set(Analysis.RULE_VERSION, source.get(Analysis.RULE_VERSION));
        List<JsonNode> relations = new ArrayList<>();
        for (JsonNode relation : source.path(Analysis.TRANSACTION_RELATIONS)) {
            if (ids.contains(relation.path(Analysis.FROM_ID).asString())
                || ids.contains(relation.path(Analysis.TO_ID).asString())) {
                ObjectNode value = (ObjectNode) relation.deepCopy();
                value.remove(
                    List.of(
                        Analysis.USER_ID,
                        Analysis.SOURCE_VERSION,
                        Analysis.SOURCE_REF
                    )
                );
                relations.add(value);
            }
        }

        relations.sort(Comparator.comparing(row -> AnalysisJson.canonical(row).toString()));
        var links = facts.putArray(Analysis.RELATIONS);
        relations.forEach(links::add);
        return AnalysisJson.digest(facts);
    }

    /**
     * 같은 의미 대상의 중복 항목을 거절하고 현재 요청의 항목 식별을 만든다.
     * @created 2026-11-01
     * @usedBy hint, AnalysisResults
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 단일 제어문 본문 중괄호 명시
     */
    public List<Item> items(ObjectNode input) {
        List<Item> result = new ArrayList<>();
        Set<String> targets = new HashSet<>();
        String kind = input.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND).asString();
        for (JsonNode item : input.path(ApiFieldConstants.Analysis.ITEMS)) {
            Set<String> ids = new HashSet<>();
            item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS)
                .forEach(id -> ids.add(id.asString()));
            ObjectNode identity = AnalysisJson.JSON.createObjectNode()
                .put(ApiFieldConstants.Analysis.KIND, kind);
            if (kind.equals(ApiCodeConstants.Analysis.TRANSACTION_MEANING)) {
                identity.set(
                    ApiFieldConstants.Analysis.TARGET,
                    item.get(ApiFieldConstants.Analysis.TARGET_TRANSACTION_ID)
                );
            } else {
                var evidence = identity.putArray(ApiFieldConstants.Analysis.EVIDENCE);
                ids.stream()
                    .sorted()
                    .forEach(evidence::add);
            }
            String key = AnalysisJson.digest(identity);
            if (!targets.add(key)) {
                throw new FinancialException(422, ApiCodeConstants.Analysis.VALIDATION_FAILED);
            }

            Set<String> direct = Set.copyOf(ids);
            boolean expanded;
            do {
                expanded = false;
                for (JsonNode transaction : input.path(ApiFieldConstants.Analysis.TRANSACTIONS)) {
                    if (ids.contains(
                        transaction.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString()
                    )
                        && transaction.path(ApiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID)
                            .isString()) {
                        expanded |= ids.add(
                            transaction.path(ApiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID)
                                .asString()
                        );
                    }
                }
                for (JsonNode relation : input.path(ApiFieldConstants.Analysis.RELATIONS)) {
                    String from = relation.path(ApiFieldConstants.Analysis.FROM_ID).asString();
                    String to = relation.path(ApiFieldConstants.Analysis.TO_ID).asString();
                    if (ids.contains(from) || ids.contains(to)) {
                        expanded |= ids.add(from);
                        expanded |= ids.add(to);
                    }
                }
            } while (expanded);
            ObjectNode facts = AnalysisJson.JSON.createObjectNode();
            var evidenceGroups = List.of(
                ApiFieldConstants.Analysis.TRANSACTIONS,
                ApiFieldConstants.Analysis.CURRENT_CLASSIFICATIONS,
                ApiFieldConstants.Analysis.UNAVAILABLE_REFERENCES
            );
            for (String field : evidenceGroups) {
                var selected = facts.putArray(field);
                List<JsonNode> rows = new ArrayList<>();
                for (JsonNode row : input.path(field)) {
                    if (ids
                        .contains(row.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString())) {
                        rows.add(row);
                    }
                }

                rows.sort(
                    Comparator.comparing(
                        row -> row.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString()
                    )
                );
                rows.forEach(row -> selected.add(row.deepCopy()));
            }

            List<JsonNode> relations = new ArrayList<>();
            for (JsonNode relation : input.path(ApiFieldConstants.Analysis.RELATIONS)) {
                if (ids.contains(relation.path(ApiFieldConstants.Analysis.FROM_ID).asString())
                    || ids.contains(relation.path(ApiFieldConstants.Analysis.TO_ID).asString())) {
                    relations.add(relation);
                }
            }

            relations.sort(Comparator.comparing(row -> AnalysisJson.canonical(row).toString()));
            var links = facts.putArray(ApiFieldConstants.Analysis.RELATIONS);
            relations.forEach(row -> links.add(row.deepCopy()));
            for (JsonNode candidate : input.path(ApiFieldConstants.Analysis.CANDIDATES)) {
                if (candidate.path(ApiFieldConstants.Analysis.CANDIDATE_KEY)
                    .equals(item.path(ApiFieldConstants.Analysis.CANDIDATE_KEY))) {
                    ObjectNode local = (ObjectNode) candidate.deepCopy();
                    local.remove(
                        List.of(
                            ApiFieldConstants.Analysis.CANDIDATE_KEY,
                            ApiFieldConstants.Analysis.SOURCE_VERSION,
                            ApiFieldConstants.Analysis.RULE_VERSION
                        )
                    );
                    var ordered = local
                        .putArray(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS);
                    direct.stream()
                        .sorted()
                        .forEach(ordered::add);
                    // observedMonths는 순서 없는 월 집합이며 숫자·날짜를 서버에서 재계산하지 않는다.
                    ObjectNode features = (ObjectNode) local
                        .get(ApiFieldConstants.Analysis.FEATURES);
                    List<String> months = new ArrayList<>();
                    features.path(ApiFieldConstants.Analysis.OBSERVED_MONTHS)
                        .forEach(month -> months.add(month.asString()));
                    var sorted = features.putArray(ApiFieldConstants.Analysis.OBSERVED_MONTHS);
                    months.stream()
                        .sorted()
                        .forEach(sorted::add);
                    facts.set(ApiFieldConstants.Analysis.CANDIDATE, local);
                }
            }

            result.add(
                new Item(
                    item.path(ApiFieldConstants.Analysis.ITEM_KEY).asString(),
                    key,
                    AnalysisJson.digest(facts)
                )
            );
        }

        return List.copyOf(result);
    }

    /**
     * Flutter와 대조할 입력 지문이다. 사용자 범위는 DB 검색 키로 별도 강제한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 키 접근 의미를 유지하며 null 수신자 메서드 참조 경고 해소
     */
    public String hint(ObjectNode input) {
        ObjectNode body = AnalysisJson.JSON.createObjectNode()
            .put(
                ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND,
                input.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND).asString()
            );
        var rows = body.putArray(ApiFieldConstants.Analysis.ITEMS);
        List<Item> ordered = items(input)
            .stream()
            .sorted(Comparator.comparing(item -> item.key()))
            .toList();
        ordered.forEach(
            item -> rows.addObject()
                .put(ApiFieldConstants.Analysis.MEMORY_KEY, item.key())
                .put(ApiFieldConstants.Analysis.EVIDENCE_HASH, item.evidenceHash())
        );
        return AnalysisJson.digest(body);
    }

    /**
     * 같은 원천이라도 다른 승인 모델·프롬프트·정책의 결과는 캐시로 섞지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs, AnalysisResults
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    public String inputHash(ObjectNode input, ObjectNode versions) {
        ObjectNode key = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.INPUT, hint(input));
        key.set(ApiFieldConstants.Analysis.VERSIONS, versions.deepCopy());
        key.set(
            ApiFieldConstants.Analysis.CONTRACT_VERSION,
            input.get(ApiFieldConstants.Analysis.CONTRACT_VERSION)
        );
        key.set(
            ApiFieldConstants.Analysis.SCHEMA_VERSION,
            input.path(ApiFieldConstants.Analysis.CONTEXT)
                .get(ApiFieldConstants.Analysis.SCHEMA_VERSION)
        );
        key.set(
            ApiFieldConstants.Analysis.RULE_VERSION,
            input.path(ApiFieldConstants.Analysis.CONTEXT)
                .get(ApiFieldConstants.Analysis.RULE_VERSION)
        );
        return AnalysisJson.digest(key);
    }

    /**
     * 공개 힌트와 별도로 항목별 실제 원천을 결합한다. 무관한 거래·전체 버전은 포함하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisResults의 저장·재사용·삭제 식별
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    public List<Item> boundItems(ObjectNode source, ObjectNode input) {
        List<Item> bound = new ArrayList<>();
        for (Item identity : items(input)) {
            JsonNode item = null;
            for (JsonNode candidate : input.path(ApiFieldConstants.Analysis.ITEMS)) {
                if (candidate.path(ApiFieldConstants.Analysis.ITEM_KEY)
                    .asString()
                    .equals(identity.itemKey())) {
                    item = candidate;
                }
            }

            if (item == null) {
                throw new IllegalStateException(ApiMessageConstants.Analysis.MISSING_ITEM);
            }

            Set<String> ids = new HashSet<>();
            item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS)
                .forEach(id -> ids.add(id.asString()));
            boolean expanded;
            do {
                expanded = false;
                for (JsonNode transaction : input.path(ApiFieldConstants.Analysis.TRANSACTIONS)) {
                    if (ids
                        .contains(
                            transaction.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString()
                        )
                        && transaction.path(ApiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID)
                            .isString()) {
                        expanded |= ids.add(
                            transaction.path(ApiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID)
                                .asString()
                        );
                    }
                }
                for (JsonNode relation : input.path(ApiFieldConstants.Analysis.RELATIONS)) {
                    String from = relation.path(ApiFieldConstants.Analysis.FROM_ID).asString();
                    String to = relation.path(ApiFieldConstants.Analysis.TO_ID).asString();
                    if (ids.contains(from) || ids.contains(to)) {
                        expanded |= ids.add(from);
                        expanded |= ids.add(to);
                    }
                }
            } while (expanded);
            ObjectNode facts = rawFacts(source, ids)
                .put(ApiFieldConstants.Analysis.MEANING_EVIDENCE, identity.evidenceHash());
            bound.add(new Item(identity.itemKey(), identity.key(), AnalysisJson.digest(facts)));
        }

        return List.copyOf(bound);
    }

    /**
     * 서버 원천 지문을 최종 실행 식별에 추가하되 Flutter 힌트 규격은 유지한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 접수·실행 중복 확인
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 키 접근 의미를 유지하며 null 수신자 메서드 참조 경고 해소
     */
    public String boundInputHash(ObjectNode source, ObjectNode input, ObjectNode versions) {
        ObjectNode key = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.INPUT, inputHash(input, versions));
        var facts = key.putArray(ApiFieldConstants.Analysis.SOURCE);
        List<Item> ordered = boundItems(source, input)
            .stream()
            .sorted(Comparator.comparing(item -> item.key()))
            .toList();
        ordered.forEach(
            item -> facts.addObject()
                .put(ApiFieldConstants.Analysis.MEMORY_KEY, item.key())
                .put(ApiFieldConstants.Analysis.EVIDENCE_HASH, item.evidenceHash())
        );
        return AnalysisJson.digest(key);
    }

    /**
     * 관련 원천 값만 정렬하며 사용자 ID·원천 전체 버전·공급자 추적값은 기억 의미와 분리한다.
     * @created 2026-11-01
     * @usedBy boundItems, sourceHash
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode rawFacts(ObjectNode source, Set<String> ids) {
        ObjectNode facts = AnalysisJson.JSON.createObjectNode();
        var sourceGroups = List.of(
            ApiFieldConstants.Analysis.TRANSACTIONS,
            ApiFieldConstants.Analysis.RELATED_TRANSACTIONS,
            ApiFieldConstants.Analysis.REFERENCE_RESOLUTIONS
        );
        for (String field : sourceGroups) {
            List<ObjectNode> rows = new ArrayList<>();
            for (JsonNode value : source.path(field)) {
                if (!ids
                    .contains(value.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString())) {
                    continue;
                }

                ObjectNode row = (ObjectNode) value.deepCopy();
                row.remove(
                    List.of(
                        ApiFieldConstants.Analysis.USER_ID,
                        ApiFieldConstants.Analysis.SOURCE_VERSION,
                        ApiFieldConstants.Analysis.SOURCE_REF
                    )
                );
                rows.add(row);
            }

            rows.sort(
                Comparator.comparing(
                    row -> row.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString()
                )
            );
            var selected = facts.putArray(field);
            rows.forEach(selected::add);
        }

        return facts;
    }

    /**
     * 실행 중 관련 원천의 금액·날짜 변경도 감지한다. 값의 의미를 계산하거나 모델에 추가하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 전송·채택 재검증
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    public String sourceHash(ObjectNode source, ObjectNode input) {
        Set<String> ids = new HashSet<>();
        input.path(ApiFieldConstants.Analysis.TRANSACTIONS)
            .forEach(
                value -> ids.add(value.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString())
            );
        input.path(ApiFieldConstants.Analysis.UNAVAILABLE_REFERENCES)
            .forEach(
                value -> ids.add(value.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString())
            );
        ObjectNode facts = rawFacts(source, ids);
        facts.set(
            ApiFieldConstants.Analysis.RULE_VERSION,
            source.get(ApiFieldConstants.Analysis.RULE_VERSION)
        );
        return AnalysisJson.digest(facts);
    }

    /**
     * 현재 itemKey와 묶음 밖에서도 유지되는 불변 기억 식별을 구분한다.
     * @created 2026-11-01
     * @usedBy AnalysisIdentity, AnalysisResults
     */
    public record Item(String itemKey, String key, String evidenceHash) {
    }
}
