package com.payse.api.analysis.service;

import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.api.finance.error.FinancialException;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 인증 트랜잭션에서 읽은 금융 원천과 분석 근거를 대조한다. 계산·원천 저장은 하지 않는다.
 * @created 2026-11-01
 * @usedBy AnalysisJobs의 접수·본문·결과 재사용 검증
 */
public final class AnalysisEvidence {
    private static final List<String> TRANSACTION_FIELDS = List.of("transactionId", "recordKind", "direction",
        "status", "reflectionReason", "merchantName", "description", "originalTransactionId");
    private final AnalysisContract contract = new AnalysisContract();

    /**
     * 저장 당시 전체 근거의 현재 소유권·금융사 공개 권한을 확인한다. 입력 재사용 검사는 별도다.
     * @created 2026-11-01
     * @usedBy MemoryCatalog.entry
     */
    public void references(UUID owner, ObjectNode source, List<UUID> refs) {
        if (owner == null || !owner.toString().equals(source.path("userId").asString())) throw forbidden();
        if (refs.isEmpty()) throw unavailable();
        SourceView view = new SourceView(owner, source);
        for (UUID id : refs) view.transaction(id.toString());
    }

    /**
     * 본문 없는 접수도 현재 문맥·선택 계좌·근거 거래의 공개 권한을 확인한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.validateDescriptor
     */
    public void descriptor(UUID owner, ObjectNode source, ObjectNode descriptor) {
        if (owner == null || !owner.toString().equals(source.path("userId").asString())) throw forbidden();
        JsonNode context = descriptor.path("context");
        Set<String> fields = Set.of("schemaVersion", "dataVersion", "sourceVersion", "ruleVersion", "asOf",
            "inputRevision", "localSessionEpoch", "selectedAccountIds");
        if (!context.isObject() || !context.propertyNames().equals(fields)) throw invalid();
        for (String key : List.of("inputRevision", "localSessionEpoch")) {
            if (!context.path(key).isIntegralNumber() || context.path(key).asLong(-1) < 0) throw invalid();
        }
        if (!context.path("selectedAccountIds").isArray()) throw invalid();
        if (!"PAYSE-API-0.6-4".equals(context.path("schemaVersion").asString())) throw invalid();
        currentContext(source, context);
        SourceView view = new SourceView(owner, source);
        Set<String> selected = new HashSet<>();
        for (JsonNode id : context.path("selectedAccountIds")) {
            if (!id.isString() || !selected.add(id.asString())) throw invalid();
            if (!view.publicAccount(id.asString())) throw forbidden();
        }
        for (JsonNode item : descriptor.path("items")) {
            for (JsonNode id : item.path("evidenceTransactionIds")) view.transaction(id.asString());
        }
    }

    /**
     * 현재 소유권·문맥·공개 근거를 검증하고 호출자와 공유하지 않는 입력 사본을 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 접수·본문 제출·결과 조회
     * @param owner 인증 함수가 확정한 사용자이며 요청 본문의 ID로 대체하지 않는다.
     * @param source 같은 인증 트랜잭션에서 FinancialRepository.load로 읽은 전체 자료
     * @param input 현재 분석 입력; verified·원천 확정 출처를 클라이언트에게서 받지 않는다.
     * @return 검증된 독립 사본. 원천·입력 및 금융 dataVersion은 변경하지 않는다.
     */
    public ObjectNode verify(UUID owner, ObjectNode source, ObjectNode input) {
        if (owner == null || source == null || !owner.toString().equals(source.path("userId").asString())) {
            throw forbidden();
        }
        if (input == null) throw invalid();
        ObjectNode verified = input.deepCopy();
        try { contract.input(verified); }
        catch (ContractFailure failure) { throw invalid(); }

        currentContext(source, verified.get("context"));
        SourceView view = new SourceView(owner, source);
        for (JsonNode id : verified.get("context").get("selectedAccountIds")) {
            if (!view.publicAccount(id.asString())) throw forbidden();
        }
        Map<String, JsonNode> supplied = index(verified, "transactions", "transactionId");
        Map<String, JsonNode> missing = index(verified, "unavailableReferences", "transactionId");
        Map<String, JsonNode> classifications = index(verified, "currentClassifications", "transactionId");
        for (var entry : supplied.entrySet()) {
            JsonNode stored = view.transaction(entry.getKey());
            for (String field : TRANSACTION_FIELDS) {
                if (!entry.getValue().get(field).equals(required(stored, field))) throw invalid();
            }
            verifyOriginal(stored, supplied, missing, view);
            verifyClassification(stored, classifications.get(entry.getKey()));
        }
        verifyRelations(verified, supplied.keySet(), view);
        return verified;
    }

    /**
     * 같은 Snapshot의 버전·원천 시각을 요구하고 Flutter epoch·revision은 계약 검사에 맡긴다.
     * @created 2026-11-01
     * @usedBy verify
     */
    private void currentContext(ObjectNode source, JsonNode context) {
        if (!"PAYSE-API-0.6-4".equals(context.path("schemaVersion").asString())) throw invalid();
        if (!context.get("ruleVersion").equals(required(source, "ruleVersion"))) {
            throw new FinancialException(409, "RULE_VERSION_MISMATCH");
        }
        if (!"PAYSE-DRAFT-4".equals(required(source, "schemaVersion").asString())) {
            throw new FinancialException(409, "STALE_DATA");
        }
        for (String field : List.of("dataVersion", "sourceVersion", "asOf")) {
            if (!context.get(field).equals(required(source, field))) {
                throw new FinancialException(409, "STALE_DATA");
            }
        }
    }

    /**
     * 공개 원거래는 입력에 포함한다. 미확보 사유만으로 기관 공개 권한을 추정하지 않는다.
     * @created 2026-11-01
     * @usedBy verify
     */
    private void verifyOriginal(JsonNode row, Map<String, JsonNode> supplied, Map<String, JsonNode> missing,
            SourceView view) {
        JsonNode original = required(row, "originalTransactionId");
        if (original.isNull()) return;
        String id = original.asString();
        if (view.transactions.containsKey(id)) {
            view.transaction(id);
            if (!supplied.containsKey(id)) throw invalid();
            return;
        }
        JsonNode unavailable = missing.get(id);
        JsonNode resolution = view.resolutions.get(id);
        if (unavailable == null || resolution == null
                || !"unavailable".equals(required(resolution, "status").asString())) throw invalid();
        String reason = required(resolution, "reason").asString();
        if ("not_connected".equals(reason)) throw forbidden();
        if (!Set.of("outside_retention", "not_provided").contains(reason)
                || !unavailable.get("reason").equals(resolution.get("reason"))) throw invalid();
        // 현재 저장된 미확보 표식에는 원거래의 소유·기관 권한 근거가 없다.
        throw unavailable();
    }

    /**
     * 저장된 비null 분류의 누락·변조를 거절한다. 분류 출처나 사용자 확인 상태는 만들지 않는다.
     * @created 2026-11-01
     * @usedBy verify
     */
    private void verifyClassification(JsonNode stored, JsonNode submitted) {
        JsonNode current = required(stored, "payseTransactionType");
        if (submitted == null) {
            if (!current.isNull()) throw invalid();
        } else if (!current.equals(submitted.get("value"))) throw invalid();
    }

    /**
     * 제출 근거에 닿는 공개 관계를 빠짐없이 대조하고 위조·방향 변경·근거 누락을 거절한다.
     * @created 2026-11-01
     * @usedBy verify
     */
    private void verifyRelations(ObjectNode input, Set<String> supplied, SourceView view) {
        Set<String> expected = new HashSet<>();
        for (JsonNode relation : array(view.source, "transactionRelations")) {
            String from = required(relation, "fromId").asString();
            String to = required(relation, "toId").asString();
            if (!supplied.contains(from) && !supplied.contains(to)) continue;
            view.transaction(from);
            view.transaction(to);
            if (!supplied.contains(from) || !supplied.contains(to)) throw invalid();
            JsonNode evidence = required(relation, "evidenceRef");
            if (!evidence.isString() || evidence.asString().isBlank()) throw unavailable();
            expected.add(relationKey(relation));
        }
        Set<String> actual = new HashSet<>();
        for (JsonNode relation : input.get("relations")) actual.add(relationKey(relation));
        if (!expected.equals(actual)) throw invalid();
    }

    /**
     * 관계의 저장 방향을 포함한 내부 비교 키만 만든다. 공개·재사용 지문으로 쓰지 않는다.
     * @created 2026-11-01
     * @usedBy verifyRelations
     */
    private String relationKey(JsonNode row) {
        return required(row, "kind").asString() + ":" + required(row, "fromId").asString()
            + ":" + required(row, "toId").asString();
    }

    /**
     * 요청 하나의 소유 자료와 활성 기관만 인덱스한다. 첫 거래 페이지와 무관하게 검사한다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidence.verify
     */
    private static final class SourceView {
        private final ObjectNode source;
        private final UUID owner;
        private final Set<String> connected = new HashSet<>();
        private final Map<String, JsonNode> accounts;
        private final Map<String, JsonNode> cards;
        private final Map<String, JsonNode> transactions;
        private final Map<String, JsonNode> resolutions;

        /**
         * 전체 자료의 중복·소유권을 확인하고 본문/보조 거래를 동일 기준으로 합친다.
         * @created 2026-11-01
         * @usedBy AnalysisEvidence.verify
         */
        private SourceView(UUID owner, ObjectNode source) {
            this.owner = owner;
            this.source = source;
            accounts = index(source, "accounts", "accountId");
            cards = index(source, "cards", "cardId");
            transactions = index(source, "transactions", "transactionId");
            for (var entry : index(source, "relatedTransactions", "transactionId").entrySet()) {
                JsonNode previous = transactions.putIfAbsent(entry.getKey(), entry.getValue());
                if (previous != null && !previous.equals(entry.getValue())) throw unavailable();
            }
            resolutions = index(source, "referenceResolutions", "transactionId");
            for (JsonNode link : array(source, "institutionLinks")) {
                owned(link);
                if (required(link, "disconnectedAt").isNull()) {
                    connected.add(required(link, "institutionCode").asString());
                }
            }
        }

        /**
         * 선택 계좌는 같은 사용자이면서 현재 연결된 은행 소속일 때만 허용한다.
         * @created 2026-11-01
         * @usedBy AnalysisEvidence.verify
         */
        private boolean publicAccount(String id) { return visible(accounts.get(id)); }

        /**
         * 거래 원천 종류별 은행/카드사 권한을 검사하며 반대쪽 부모로 권한을 확대하지 않는다.
         * @created 2026-11-01
         * @usedBy AnalysisEvidence.verify, verifyOriginal, verifyRelations
         */
        private JsonNode transaction(String id) {
            JsonNode row = transactions.get(id);
            if (row == null) throw forbidden();
            owned(row);
            if (!required(source, "sourceVersion").equals(required(row, "sourceVersion"))) throw unavailable();
            boolean accountEntry = "account_entry".equals(required(row, "recordKind").asString());
            JsonNode parent = (accountEntry ? accounts : cards)
                .get(required(row, accountEntry ? "accountId" : "cardId").asString());
            if (!visible(parent)) throw forbidden();
            return row;
        }

        /**
         * 부모 소유권과 현재 연결만 확인하고 포함 계좌 여부를 접근 권한으로 쓰지 않는다.
         * @created 2026-11-01
         * @usedBy publicAccount, transaction
         */
        private boolean visible(JsonNode row) {
            if (row == null) return false;
            owned(row);
            return connected.contains(required(row, "institutionCode").asString());
        }

        /**
         * DB에서 확보된 행도 인증 사용자가 다르면 동일한 권한 오류로 거절한다.
         * @created 2026-11-01
         * @usedBy SourceView, visible, transaction
         */
        private void owned(JsonNode row) {
            if (!owner.toString().equals(required(row, "userId").asString())) throw forbidden();
        }
    }

    /**
     * 저장 배열의 실제 ID를 인덱스하고 중복 행을 조용히 덮어쓰지 않는다.
     * @created 2026-11-01
     * @usedBy verify, SourceView
     */
    private static Map<String, JsonNode> index(JsonNode source, String field, String key) {
        Map<String, JsonNode> result = new LinkedHashMap<>();
        for (JsonNode row : array(source, field)) {
            if (result.putIfAbsent(required(row, key).asString(), row) != null) throw unavailable();
        }
        return result;
    }

    /**
     * 원천 필드가 없으면 정상 null·빈 값으로 보충하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidence와 SourceView의 원천 대조
     */
    private static JsonNode required(JsonNode row, String field) {
        JsonNode value = row.get(field);
        if (value == null || value.isMissingNode()) throw unavailable();
        return value;
    }

    /**
     * 원천 필수 배열을 확인하고 미확보 자료를 빈 배열로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy index, verifyRelations, SourceView
     */
    private static JsonNode array(JsonNode source, String field) {
        JsonNode result = required(source, field);
        if (!result.isArray()) throw unavailable();
        return result;
    }

    /**
     * 입력·DB 근거 불일치를 민감 본문 없는 기존 검증 오류로 전달한다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidence의 검증 단계
     */
    private static FinancialException invalid() { return new FinancialException(422, "VALIDATION_FAILED"); }

    /**
     * 외부 사용자·미연결·존재하지 않는 자원의 차이를 공개하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidence와 SourceView의 권한 검사
     */
    private static FinancialException forbidden() { return new FinancialException(403, "RESOURCE_FORBIDDEN"); }

    /**
     * 저장 원천의 구조 오류를 정상 입력이나 미확보로 숨기지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidence의 원천 구조 검사
     */
    private static FinancialException unavailable() { return new FinancialException(503, "TEMPORARILY_UNAVAILABLE"); }
}
