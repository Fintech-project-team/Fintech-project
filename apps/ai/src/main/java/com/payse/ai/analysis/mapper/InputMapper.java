package com.payse.ai.analysis.mapper;

import static com.payse.ai.analysis.validation.SchemaRules.require;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.SchemaRules;
import com.payse.ai.analysis.validation.StorageContract;
import com.payse.ai.constants.AiCodeConstants;
import com.payse.ai.constants.AiConfigConstants;
import com.payse.ai.constants.AiFieldConstants.Schema;
import com.payse.ai.constants.AiFieldConstants;
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
     * @modified 2026-11-03 - 내부 원천 보충 투영과 생성 경로 공유
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public InputMapper(ObjectNode payload, AnalysisContract contract) {
        this(payload, contract, null);
    }

    /**
     * 공개 입력을 바꾸지 않고 서버 전용 금액·날짜 근거를 최소 투영에 결합한다.
     * @created 2026-11-03
     * @usedBy AnalysisService.analyzeForStorage, InputMapper
     */
    public InputMapper(ObjectNode payload, AnalysisContract contract, ObjectNode facts) {
        this.contract = contract;
        require(payload != null, AiCodeConstants.Analysis.INVALID_INPUT);
        original = payload.deepCopy();
        contract.input(original);

        ObjectNode projected = JSON.createObjectNode();
        String[] projectedFields = {
            AiFieldConstants.Analysis.SEMANTIC_TASK_KIND,
            AiFieldConstants.Analysis.ITEMS,
            AiFieldConstants.Analysis.TRANSACTIONS,
            AiFieldConstants.Analysis.RELATIONS,
            AiFieldConstants.Analysis.UNAVAILABLE_REFERENCES
        };
        for (String key : projectedFields) {
            projected.set(key, original.get(key).deepCopy());
        }
        projected.set(
            AiFieldConstants.Analysis.EXISTING_CLASSIFICATIONS,
            original.get(AiFieldConstants.Analysis.CURRENT_CLASSIFICATIONS)
                .deepCopy()
        );

        var candidates = projected.putArray(AiFieldConstants.Analysis.CANDIDATES);
        for (JsonNode candidate : original.get(AiFieldConstants.Analysis.CANDIDATES)) {
            ObjectNode row = candidates.addObject();
            String[] candidateFields = {
                AiFieldConstants.Analysis.CANDIDATE_KEY,
                AiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS,
                AiFieldConstants.Analysis.NORMALIZED_NAME,
                AiFieldConstants.Analysis.FEATURES
            };
            for (String key : candidateFields) {
                row.set(key, candidate.get(key).deepCopy());
            }
        }

        if (facts != null) {
            enrich(projected, facts);
        }
        input = (ObjectNode) transform(projected, null, this::shorten);
        String task = original.get(AiFieldConstants.Analysis.SEMANTIC_TASK_KIND).asString();
        ObjectNode outputSchema = contract.outputSchema(task);
        schema = (ObjectNode) aliasSchema(outputSchema, null);
    }

    /**
     * 요청에 있던 거래만 보충한다. 다른 거래·정답·민감 추가 필드는 외부 전송 전에 거절한다.
     * @created 2026-11-03
     * @usedBy InputMapper
     */
    private void enrich(ObjectNode projected, ObjectNode facts) {
        require(
            facts.propertyNames().equals(Set.of(
                AiFieldConstants.Analysis.AS_OF,
                AiFieldConstants.Analysis.TRANSACTIONS
            ))
                && facts.path(AiFieldConstants.Analysis.AS_OF).equals(
                    original.path(AiFieldConstants.Analysis.CONTEXT)
                        .path(AiFieldConstants.Analysis.AS_OF)
                )
                && facts.path(AiFieldConstants.Analysis.TRANSACTIONS).isArray(),
            AiCodeConstants.Analysis.INVALID_INPUT
        );
        Set<String> fields = Set.of(
            AiFieldConstants.Analysis.TRANSACTION_ID,
            AiFieldConstants.Analysis.ACCOUNT_ID,
            AiFieldConstants.Analysis.CARD_ID,
            AiFieldConstants.Analysis.AMOUNT_KRW,
            AiFieldConstants.Analysis.PURCHASE_DATE,
            AiFieldConstants.Analysis.WITHDRAWAL_DATE,
            AiFieldConstants.Analysis.REFUND_DATE,
            AiFieldConstants.Analysis.CANCELLATION_DATE,
            AiFieldConstants.Analysis.BOOKING_DATE,
            AiFieldConstants.Analysis.OCCURRED_AT,
            AiFieldConstants.Analysis.OCCURRED_AT_BASIS
        );
        Map<String, JsonNode> byId = new HashMap<>();
        for (JsonNode row : facts.path(AiFieldConstants.Analysis.TRANSACTIONS)) {
            require(
                row.isObject() && row.propertyNames().equals(fields)
                    && row.path(AiFieldConstants.Analysis.TRANSACTION_ID).isString()
                    && row.path(AiFieldConstants.Analysis.AMOUNT_KRW).isIntegralNumber()
                    && row.path(AiFieldConstants.Analysis.AMOUNT_KRW).canConvertToLong()
                    && row.path(AiFieldConstants.Analysis.AMOUNT_KRW).asLong() >= 0,
                AiCodeConstants.Analysis.INVALID_INPUT
            );
            for (String field : fields) {
                JsonNode value = row.path(field);
                require(
                    value.isNull() || value.isString()
                        || field.equals(AiFieldConstants.Analysis.AMOUNT_KRW),
                    AiCodeConstants.Analysis.INVALID_INPUT
                );
            }
            JsonNode previous = byId.put(
                row.path(AiFieldConstants.Analysis.TRANSACTION_ID).asString(),
                row
            );
            require(previous == null, AiCodeConstants.Analysis.INVALID_INPUT);
        }
        for (JsonNode transaction : projected.path(AiFieldConstants.Analysis.TRANSACTIONS)) {
            JsonNode row = byId.remove(
                transaction.path(AiFieldConstants.Analysis.TRANSACTION_ID).asString()
            );
            require(row != null, AiCodeConstants.Analysis.INVALID_INPUT);
            for (String field : fields) {
                ((ObjectNode) transaction).set(field, row.get(field).deepCopy());
            }
        }
        require(byId.isEmpty(), AiCodeConstants.Analysis.INVALID_INPUT);
        projected.set(
            AiFieldConstants.Analysis.AS_OF,
            facts.get(AiFieldConstants.Analysis.AS_OF).deepCopy()
        );
    }

    /**
     * 공급자가 요청별 ID 대응이나 원래 입력을 변경하지 못하도록 전송 사본을 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    public ObjectNode input() {
        return input.deepCopy();
    }

    /**
     * 공급자 전용 별칭 규격이며 공개 UUID 계약을 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    public ObjectNode schema() {
        return schema.deepCopy();
    }

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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public ObjectNode storageSchema() {
        return StorageContract.schema(schema, original.get(AiFieldConstants.Analysis.ITEMS).size());
    }

    /**
     * 의미와 보존 목록을 모두 검증하고 동일한 요청별 ID 대응으로 복원한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyzeForStorage
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    public AnalysisResult restoreStorage(ObjectNode response, TokenUsage usage) {
        SchemaRules.check(storageSchema(), response);
        ObjectNode output = restore((ObjectNode) response.get(AiFieldConstants.Analysis.OUTPUT));
        JsonNode memories = transform(
            response.get(AiFieldConstants.Analysis.MEMORIES),
            null,
            this::restoreId
        );

        Set<String> expected = new HashSet<>();
        for (JsonNode item : original.get(AiFieldConstants.Analysis.ITEMS)) {
            expected.add(item.get(AiFieldConstants.Analysis.ITEM_KEY).asString());
        }
        return new AnalysisResult(
            output,
            StorageContract.decisions(memories, expected),
            usage,
            null
        );
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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private String restoreId(String kind, String alias) {
        require(
            originals.containsKey(alias) && alias.startsWith(kind),
            AiCodeConstants.Analysis.UNKNOWN_RESPONSE_ID
        );
        return originals.get(alias);
    }

    /**
     * 허용된 식별 필드만 변환하며 상호·적요 안의 같은 문자열은 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자, restore
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     */
    private JsonNode transform(
        JsonNode value,
        String field,
        BiFunction<String, String, String> convert
    ) {
        if (value.isObject()) {
            ObjectNode result = JSON.createObjectNode();
            for (String key : value.propertyNames()) {
                JsonNode transformed = transform(value.get(key), key, convert);
                result.set(key, transformed);
            }
            return result;
        }

        if (value.isArray()) {
            var result = JSON.createArrayNode();
            for (JsonNode row : value) {
                JsonNode transformed = transform(row, field, convert);
                result.add(transformed);
            }
            return result;
        }

        String kind = kind(field);
        if (kind != null && !value.isNull()) {
            var nodes = JSON.getNodeFactory();
            String converted = convert.apply(kind, value.asString());
            return nodes.stringNode(converted);
        }

        return value.deepCopy();
    }

    /**
     * 응답의 식별 필드에는 현재 요청에서 발급한 별칭만 허용한다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private JsonNode aliasSchema(JsonNode originalSchema, String field) {
        String kind = kind(field);
        if (kind != null) {
            ObjectNode value = JSON.createObjectNode().put(Schema.TYPE_KEY, Schema.STRING_TYPE);
            var allowed = value.putArray(Schema.ENUM);
            originals.keySet()
                .stream()
                .filter(alias -> alias.startsWith(kind))
                .sorted()
                .forEach(allowed::add);
            if (Schema.ARRAY_TYPE.equals(originalSchema.path(Schema.TYPE_KEY).asString(""))) {
                ObjectNode array = (ObjectNode) originalSchema.deepCopy();
                array.set(Schema.ITEMS, value);
                return array;
            }
            return value;
        }

        ObjectNode result = (ObjectNode) originalSchema.deepCopy();
        if (result.has(Schema.PROPERTIES)) {
            ObjectNode properties = result.putObject(Schema.PROPERTIES);
            JsonNode sourceProperties = originalSchema.get(Schema.PROPERTIES);
            for (String key : sourceProperties.propertyNames()) {
                JsonNode aliased = aliasSchema(sourceProperties.get(key), key);
                properties.set(key, aliased);
            }
        }
        if (result.has(Schema.ITEMS)) {
            result.set(Schema.ITEMS, aliasSchema(originalSchema.get(Schema.ITEMS), null));
        }
        return result;
    }

    /**
     * ID의 명목 종류를 구분하며 임의의 이름을 식별자로 해석하지 않는다.
     * @created 2026-11-01
     * @usedBy transform, aliasSchema
     * @modified 2026-11-03 - 원천 계좌·카드 ID를 요청별 대체 ID로만 전송
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    private String kind(String field) {
        if (field == null) {
            return null;
        }
        return switch (field) {
        case AiFieldConstants.Analysis.TRANSACTION_ID,
            AiFieldConstants.Analysis.TARGET_TRANSACTION_ID,
            AiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID, AiFieldConstants.Analysis.FROM_ID,
            AiFieldConstants.Analysis.TO_ID,
            AiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS ->
            AiConfigConstants.Analysis.TRANSACTION_PREFIX;
        case AiFieldConstants.Analysis.ITEM_KEY -> AiConfigConstants.Analysis.ITEM_PREFIX;
        case AiFieldConstants.Analysis.ACCOUNT_ID -> AiConfigConstants.Analysis.ACCOUNT_PREFIX;
        case AiFieldConstants.Analysis.CARD_ID -> AiConfigConstants.Analysis.CARD_PREFIX;
        case AiFieldConstants.Analysis.CANDIDATE_KEY -> AiConfigConstants.Analysis.CANDIDATE_PREFIX;
        default -> null;
        };
    }
}
