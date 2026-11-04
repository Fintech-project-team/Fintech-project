package com.payse.ai.analysis.mapper;

import com.payse.ai.analysis.validation.SchemaRules;
import com.payse.ai.constants.AiConfigConstants;
import com.payse.ai.constants.AiFieldConstants.Analysis;
import com.payse.ai.constants.AiFieldConstants.Compact;
import com.payse.ai.constants.AiFieldConstants.Schema;
import java.util.LinkedHashMap;
import java.util.Map;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 모델의 의미·보존 결정을 짧게 전송하고 원래 규격으로 복원한다. 금융 판단은 하지 않는다.
 * @created 2026-11-04
 * @usedBy CompactModel
 */
public final class CompactOutput {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private final ObjectNode original;
    private final ObjectNode schema;
    private final JsonNode version;
    private final boolean storage;
    private final Map<String, String> fields = new LinkedHashMap<>();

    /**
     * 검증된 현재 요청의 별칭·허용 값·개수 제한을 복사한다.
     * @created 2026-11-04
     * @usedBy CompactModel.factory, CompactOutputTest
     */
    public CompactOutput(ObjectNode original) {
        this.original = original.deepCopy();
        SchemaRules.supported(original);
        storage = original.path(Schema.PROPERTIES).has(Analysis.OUTPUT);
        JsonNode output = storage ? original.path(Schema.PROPERTIES).get(Analysis.OUTPUT) : original;
        JsonNode properties = output.get(Schema.PROPERTIES);
        version = properties.get(Compact.POLICY_VERSION).get(Schema.ENUM).get(0).deepCopy();
        JsonNode items = properties.get(Analysis.ITEMS);
        JsonNode itemFields = items.get(Schema.ITEMS).get(Schema.PROPERTIES);
        fields.put(Compact.ITEM, Analysis.ITEM_KEY);
        fields.put(Compact.MEANING, Analysis.MEANING);
        if (itemFields.has(Analysis.CLASSIFICATION)) {
            fields.put(Compact.CLASSIFICATION, Analysis.CLASSIFICATION);
        } else {
            fields.put(Compact.CANDIDATE, Analysis.CANDIDATE_KEY);
            fields.put(Compact.NAME, Compact.PUBLIC_NAME);
        }
        fields.put(Compact.REASON, Analysis.REASON);
        fields.put(Compact.EVIDENCE, Analysis.EVIDENCE_TRANSACTION_IDS);
        schema = object();
        ObjectNode rows = (ObjectNode) items.deepCopy();
        ObjectNode row = object();
        rows.set(Schema.ITEMS, row);
        add(schema, Compact.ROWS, rows);
        for (var field : fields.entrySet()) {
            JsonNode full = itemFields.get(field.getValue());
            boolean decision = Analysis.MEANING.equals(field.getValue())
                || Analysis.CLASSIFICATION.equals(field.getValue());
            ObjectNode bounded = (ObjectNode) full.deepCopy();
            if (Analysis.REASON.equals(field.getValue())) {
                bounded.put(Schema.MAX_LENGTH, 24);
            }
            add(row, field.getKey(), decision ? decisionSchema(full) : bounded);
        }
        if (storage) {
            ObjectNode retention = JSON.createObjectNode().put(Schema.TYPE_KEY, Schema.STRING_TYPE);
            var choices = retention.putArray(Schema.ENUM);
            for (int bits = 0; bits < 16; bits++) {
                if ((bits & 2) == 0 || (bits & 4) != 0) {
                    choices.add(String.format("%4s", Integer.toBinaryString(bits)).replace(' ', '0'));
                }
            }
            add(row, Compact.RETENTION, retention);
            JsonNode reason = original.path(Schema.PROPERTIES)
                .path(Analysis.MEMORIES)
                .path(Schema.ITEMS)
                .path(Schema.PROPERTIES)
                .get(Analysis.REASON);
            ObjectNode shortReason = (ObjectNode) reason.deepCopy();
            shortReason.put(Schema.MAX_LENGTH, 16);
            add(row, Compact.RETENTION_REASON, shortReason);
            rows.put(Schema.MIN_ITEMS, original.path(Schema.PROPERTIES)
                .path(Analysis.MEMORIES).path(Schema.MIN_ITEMS).asInt());
            rows.put(Schema.MAX_ITEMS, original.path(Schema.PROPERTIES)
                .path(Analysis.MEMORIES).path(Schema.MAX_ITEMS).asInt());
        }
        SchemaRules.supported(schema);
    }

    /**
     * 공급자가 규격 객체를 변경해도 요청의 복원 기준은 보존한다.
     * @created 2026-11-04
     * @usedBy CompactModel.factory
     */
    public ObjectNode schema() {
        return schema.deepCopy();
    }

    /**
     * 출력 형식만 복원하고 기존 스키마를 재검증한다. ID·관계 검증은 원래 서비스가 수행한다.
     * @created 2026-11-04
     * @usedBy CompactModel.generate, CompactOutputTest
     */
    public ObjectNode restore(JsonNode response) {
        SchemaRules.check(schema, response);
        ObjectNode root = JSON.createObjectNode();
        ObjectNode output = storage ? root.putObject(Analysis.OUTPUT) : root;
        output.set(Compact.POLICY_VERSION, version.deepCopy());
        var items = output.putArray(Analysis.ITEMS);
        var memories = storage ? root.putArray(Analysis.MEMORIES) : null;
        for (JsonNode row : response.get(Compact.ROWS)) {
            ObjectNode item = items.addObject();
            for (var field : fields.entrySet()) {
                JsonNode value = row.get(field.getKey());
                boolean decision = Analysis.MEANING.equals(field.getValue())
                    || Analysis.CLASSIFICATION.equals(field.getValue());
                item.set(field.getValue(), decision ? decision(value.asString()) : value.deepCopy());
            }
            if (storage) {
                String flags = row.get(Compact.RETENTION).asString();
                ObjectNode memory = memories.addObject();
                memory.set(Analysis.ITEM_KEY, row.get(Compact.ITEM).deepCopy());
                memory.put(Analysis.ACTIVE, flags.charAt(0) == '1');
                memory.put(Analysis.IS_REFERENCE, flags.charAt(1) == '1');
                memory.put(Analysis.IMPORTANT, flags.charAt(2) == '1');
                memory.put(Analysis.REFERENCE_POLICY, flags.charAt(3) == '1'
                    ? AiConfigConstants.Memory.REFERENCE_REQUIRED
                    : AiConfigConstants.Memory.OPTIONAL_REFERENCE);
                memory.set(Analysis.REASON, row.get(Compact.RETENTION_REASON).deepCopy());
            }
        }
        SchemaRules.check(original, root);
        return root;
    }

    /**
     * 원래 허용 값과 판단 유보 사유를 단일 코드에 일대일로 대응시킨다.
     * @created 2026-11-04
     * @usedBy CompactOutput 생성자
     */
    private static ObjectNode decisionSchema(JsonNode full) {
        ObjectNode result = JSON.createObjectNode().put(Schema.TYPE_KEY, Schema.STRING_TYPE);
        var choices = result.putArray(Schema.ENUM);
        JsonNode properties = full.get(Schema.PROPERTIES);
        for (JsonNode value : properties.get(Analysis.VALUE).get(Schema.ENUM)) {
            if (!value.isNull()) {
                choices.add(value.deepCopy());
            }
        }
        for (JsonNode reason : properties.get(Analysis.REASON_CODE).get(Schema.ENUM)) {
            if (!AiConfigConstants.Analysis.SUPPORTED.equals(reason.asString())) {
                choices.add(AiConfigConstants.Analysis.UNKNOWN_PREFIX + reason.asString());
            }
        }
        return result;
    }

    /**
     * 모델이 고른 단일 코드를 원래의 일치하는 세 필드로 복원한다.
     * @created 2026-11-04
     * @usedBy restore
     */
    private static ObjectNode decision(String code) {
        ObjectNode value = JSON.createObjectNode();
        if (code.startsWith(AiConfigConstants.Analysis.UNKNOWN_PREFIX)) {
            value.put(Analysis.STATUS, AiConfigConstants.Analysis.UNKNOWN);
            value.putNull(Analysis.VALUE);
            value.put(Analysis.REASON_CODE, code.substring(1));
        } else {
            value.put(Analysis.STATUS, AiConfigConstants.Analysis.CANDIDATE);
            value.put(Analysis.VALUE, code);
            value.put(Analysis.REASON_CODE, AiConfigConstants.Analysis.SUPPORTED);
        }
        return value;
    }

    /**
     * 모든 필드를 필수로 하고 임의 필드를 차단하는 객체 규격을 만든다.
     * @created 2026-11-04
     * @usedBy CompactOutput 생성자
     */
    private static ObjectNode object() {
        ObjectNode node = JSON.createObjectNode()
            .put(Schema.TYPE_KEY, Schema.OBJECT_TYPE)
            .put(Schema.ADDITIONAL_PROPERTIES, false);
        node.putObject(Schema.PROPERTIES);
        node.putArray(Schema.REQUIRED_FIELDS);
        return node;
    }

    /**
     * 필드 규격과 필수 목록을 함께 추가해 선택적 생략을 막는다.
     * @created 2026-11-04
     * @usedBy CompactOutput 생성자
     */
    private static void add(ObjectNode parent, String name, JsonNode field) {
        ((ObjectNode) parent.get(Schema.PROPERTIES)).set(name, field);
        parent.withArray(Schema.REQUIRED_FIELDS).add(name);
    }
}
