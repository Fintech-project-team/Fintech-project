package com.payse.ai.analysis.mapper;

import static com.payse.ai.analysis.validation.SchemaRules.require;

import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.SchemaRules;
import com.payse.ai.analysis.validation.StorageContract;
import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.provider.dto.TokenUsage;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.function.BiFunction;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 한 요청의 최소 투영과 짧은 ID 대응만 소유한다. 공유 상태나 영구 식별자를 만들지 않는다.
 * @created 2026-11-01
 * @usedBy AnalysisService.analyze
 */
public final class InputMapper {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private final AnalysisContract contract;
    private final ObjectNode original;
    private final ObjectNode input;
    private final ObjectNode schema;
    private final Map<String, String> aliases = new LinkedHashMap<>();
    private final Map<String, String> originals = new HashMap<>();
    private final Map<String, Integer> counts = new HashMap<>();

    /**
     * 호출 입력의 사본을 검증하고 모델용 최소 필드와 요청 내부 ID만 준비한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze, 계약 테스트
     */
    public InputMapper(ObjectNode payload, AnalysisContract contract) {
        this.contract = contract;
        require(payload != null, "INVALID_INPUT");
        original = payload.deepCopy();
        contract.input(original);
        ObjectNode projected = JSON.createObjectNode();
        for (String key : new String[] {"semanticTaskKind", "items", "transactions", "relations", "unavailableReferences"}) {
            projected.set(key, original.get(key).deepCopy());
        }
        projected.set("existingClassifications", original.get("currentClassifications").deepCopy());
        var candidates = projected.putArray("candidates");
        for (JsonNode candidate : original.get("candidates")) {
            ObjectNode row = candidates.addObject();
            for (String key : new String[] {"candidateKey", "evidenceTransactionIds", "normalizedName", "features"}) {
                row.set(key, candidate.get(key).deepCopy());
            }
        }
        input = (ObjectNode) transform(projected, null, this::shorten);
        schema = (ObjectNode) aliasSchema(contract.outputSchema(original.get("semanticTaskKind").asString()), null);
    }

    /**
     * 공급자가 요청별 ID 대응이나 원래 입력을 변경하지 못하도록 전송 사본을 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    public ObjectNode input() { return input.deepCopy(); }

    /**
     * 공급자 전용 별칭 규격이며 공개 UUID 계약을 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    public ObjectNode schema() { return schema.deepCopy(); }

    /**
     * 현재 요청의 별칭만 복원하고 공개 계약으로 재검증한다. 불완전 배치는 반환하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    public ObjectNode restore(ObjectNode response) {
        SchemaRules.check(schema, response);
        ObjectNode restored = (ObjectNode) transform(response, null, this::restoreId);
        contract.output(original, restored);
        return restored;
    }

    /**
     * 같은 요청의 의미 출력과 개별 보존 메타데이터를 감싼 공급자 전용 규격을 만든다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyzeForStorage
     */
    public ObjectNode storageSchema() {
        return StorageContract.schema(schema, original.get("items").size());
    }

    /**
     * 의미와 보존 목록을 모두 검증하고 동일한 요청별 ID 대응으로 복원한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyzeForStorage
     */
    public AnalysisResult restoreStorage(ObjectNode response, TokenUsage usage) {
        SchemaRules.check(storageSchema(), response);
        ObjectNode output = restore((ObjectNode) response.get("output"));
        JsonNode memories = transform(response.get("memories"), null, this::restoreId);
        Set<String> expected = new HashSet<>();
        for (JsonNode item : original.get("items")) expected.add(item.get("itemKey").asString());
        return new AnalysisResult(output, StorageContract.decisions(memories, expected), usage, null);
    }

    /**
     * 식별 종류와 원래 값을 묶어 같은 요청 안에서만 재사용하는 별칭을 만든다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자
     */
    private String shorten(String kind, String value) {
        String key = kind + ":" + value;
        if (!aliases.containsKey(key)) {
            String alias = kind + counts.merge(kind, 1, Integer::sum);
            aliases.put(key, alias);
            originals.put(alias, value);
        }
        return aliases.get(key);
    }

    /**
     * 미발급 별칭·다른 ID 종류·원래 UUID 직접 반환을 거절한다.
     * @created 2026-11-01
     * @usedBy restore
     */
    private String restoreId(String kind, String alias) {
        require(originals.containsKey(alias) && alias.startsWith(kind), "UNKNOWN_RESPONSE_ID");
        return originals.get(alias);
    }

    /**
     * 허용된 식별 필드만 변환하며 상호·적요 안의 같은 문자열은 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자, restore
     */
    private JsonNode transform(JsonNode value, String field, BiFunction<String, String, String> convert) {
        if (value.isObject()) {
            ObjectNode result = JSON.createObjectNode();
            for (String key : value.propertyNames()) result.set(key, transform(value.get(key), key, convert));
            return result;
        }
        if (value.isArray()) {
            var result = JSON.createArrayNode();
            for (JsonNode row : value) result.add(transform(row, field, convert));
            return result;
        }
        String kind = kind(field);
        return kind != null && !value.isNull() ? JSON.getNodeFactory().stringNode(convert.apply(kind, value.asString())) : value.deepCopy();
    }

    /**
     * 응답의 식별 필드에는 현재 요청에서 발급한 별칭만 허용한다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자
     */
    private JsonNode aliasSchema(JsonNode originalSchema, String field) {
        String kind = kind(field);
        if (kind != null) {
            ObjectNode value = JSON.createObjectNode().put("type", "string");
            var allowed = value.putArray("enum");
            originals.keySet().stream().filter(alias -> alias.startsWith(kind)).sorted().forEach(allowed::add);
            if ("array".equals(originalSchema.path("type").asString(""))) {
                ObjectNode array = (ObjectNode) originalSchema.deepCopy();
                array.set("items", value);
                return array;
            }
            return value;
        }
        ObjectNode result = (ObjectNode) originalSchema.deepCopy();
        if (result.has("properties")) {
            ObjectNode properties = result.putObject("properties");
            for (String key : originalSchema.get("properties").propertyNames()) {
                properties.set(key, aliasSchema(originalSchema.get("properties").get(key), key));
            }
        }
        if (result.has("items")) result.set("items", aliasSchema(originalSchema.get("items"), null));
        return result;
    }

    /**
     * ID의 명목 종류를 구분하며 임의의 이름을 식별자로 해석하지 않는다.
     * @created 2026-11-01
     * @usedBy transform, aliasSchema
     */
    private String kind(String field) {
        if (field == null) return null;
        return switch (field) {
            case "transactionId", "targetTransactionId", "originalTransactionId", "fromId", "toId", "evidenceTransactionIds" -> "t";
            case "itemKey" -> "i";
            case "candidateKey" -> "c";
            default -> null;
        };
    }
}
