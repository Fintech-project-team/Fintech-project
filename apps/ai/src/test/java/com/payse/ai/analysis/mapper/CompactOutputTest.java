package com.payse.ai.analysis.mapper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.ai.AiTestConstants.Files;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.provider.CompactModel;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import java.nio.file.Path;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.UnaryOperator;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;
import tools.jackson.databind.node.ArrayNode;

/**
 * 축약 코드의 전수 복원과 기존 서비스의 소유 ID·완전성 검증을 확인한다.
 * @created 2026-11-04
 * @usedBy JUnit
 */
class CompactOutputTest {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final TokenUsage USAGE = new TokenUsage(100, 0L, 50);

    /**
     * 모든 의미 코드·유보 사유와 유효 보존 조합이 서버 추론 없이 정확하게 복원된다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void restoresEveryDecisionAndRetention() throws Exception {
        var mapper = new InputMapper(input(), new AnalysisContract());
        var codec = new CompactOutput(mapper.storageSchema());
        JsonNode fields = mapper.schema().path("properties")
            .path("items")
            .path("items")
            .path("properties");
        var meanings = fields.path("meaning").path("properties").path("value").path("enum");
        ArrayNode choices = JSON.createArrayNode();
        for (JsonNode meaning : meanings) {
            if (!meaning.isNull()) {
                choices.add(meaning);
            }
        }
        choices.add("?insufficient_evidence").add("?conflicting_evidence").add("?outside_taxonomy");
        for (JsonNode choice : choices) {
            for (String flags : java.util.List.of("0000", "0001", "0100", "0101", "0110", "0111",
                "1000", "1001", "1100", "1101", "1110", "1111")) {
                ObjectNode reply = response(codec.schema());
                ObjectNode row = (ObjectNode) reply.path("rows").get(0);
                row.set("m", choice);
                row.put("k", flags);
                ObjectNode restored = codec.restore(reply);
                JsonNode meaning = restored.path("output").path("items").get(0).path("meaning");
                String code = choice.asString();
                assertEquals(code.startsWith("?") ? "unknown" : "candidate",
                    meaning.path("status").asString());
                if (code.startsWith("?")) {
                    assertTrue(meaning.path("value").isNull());
                    assertEquals(code.substring(1), meaning.path("reasonCode").asString());
                } else {
                    assertEquals(code, meaning.path("value").asString());
                    assertEquals("supported", meaning.path("reasonCode").asString());
                }
                JsonNode memory = restored.path("memories").get(0);
                String bits = flags;
                assertEquals(bits.charAt(0) == '1', memory.path("active").asBoolean());
                assertEquals(bits.charAt(1) == '1', memory.path("isReference").asBoolean());
                assertEquals(bits.charAt(2) == '1', memory.path("important").asBoolean());
                assertEquals(bits.charAt(3) == '1' ? "required" : "optional",
                    memory.path("referencePolicy").asString());
                assertEquals(row.get("s"), memory.get("reason"));
                assertEquals(JSON.createArrayNode().add("t1"),
                    restored.path("output").path("items").get(0).get("evidenceTransactionIds"));
            }
        }
        for (String choice : java.util.List.of("expense", "income", "internal_transfer",
            "card_payment", "?insufficient_evidence", "?conflicting_evidence", "?outside_taxonomy")) {
            ObjectNode reply = response(codec.schema());
            ((ObjectNode) reply.path("rows").get(0)).put("c", choice);
            JsonNode classification = codec.restore(reply).path("output")
                .path("items")
                .get(0)
                .path("classification");
            String code = choice;
            assertEquals(code.startsWith("?") ? "unknown" : "candidate",
                classification.path("status").asString());
            if (code.startsWith("?")) {
                assertTrue(classification.path("value").isNull());
                assertEquals(code.substring(1), classification.path("reasonCode").asString());
            } else {
                assertEquals(code, classification.path("value").asString());
                assertEquals("supported", classification.path("reasonCode").asString());
            }
        }
    }

    /**
     * 판단을 바꾸지 않고 기존 공개 응답·저장 검증·사용량에 연결한다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void runsExistingServiceOnce() throws Exception {
        AtomicInteger counts = new AtomicInteger();
        AtomicInteger generations = new AtomicInteger();
        ModelFactory factory = provider(UnaryOperator.identity(), counts, generations);
        var service = new AnalysisService(CompactModel.factory(factory), 12000);
        var result = service.analyzeForStorage(input());
        assertNull(result.failure());
        assertEquals(USAGE, result.usage());
        assertEquals(1, counts.get());
        assertEquals(1, generations.get());
        assertEquals(input().path("items").get(0).get("itemKey"),
            result.output().path("items").get(0).get("itemKey"));
        assertEquals(1, result.memories().size());
        assertTrue(CompactModel.version().matches("PAYSE-COMPACT-4:[0-9a-f]{64}"));
        assertNotEquals(service.promptVersion(), CompactModel.version());
    }

    /**
     * 잘못된 코드·식별자·누락·중복을 정상 unknown으로 반환하지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidRowsWithoutRetry() throws Exception {
        for (int variant = 0; variant < 6; variant++) {
            int selected = variant;
            AtomicInteger generations = new AtomicInteger();
            ModelFactory factory = provider(reply -> {
                ObjectNode row = (ObjectNode) reply.path("rows").get(0);
                switch (selected) {
                case 0 -> row.put("m", "invented");
                case 1 -> row.put("i", "foreign-item");
                case 2 -> row.putArray("e").add("foreign-transaction");
                case 3 -> row.remove("s");
                case 4 -> reply.withArray("rows").add(row.deepCopy());
                case 5 -> row.put("k", "1010");
                default -> throw new AssertionError();
                }
                return reply;
            }, new AtomicInteger(), generations);
            var service = new AnalysisService(CompactModel.factory(factory), 12000);
            var result = service.analyzeForStorage(input());
            assertEquals("INVALID_MODEL_OUTPUT", result.failure());
            assertNull(result.output());
            assertTrue(result.memories().isEmpty());
            assertEquals(USAGE, result.usage());
            assertEquals(1, generations.get());
        }
    }

    /**
     * 반복 후보의 식별자·이름과 저장 없는 경로에도 같은 가역 변환을 적용한다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void preservesRecurringAndMeaningOnly() throws Exception {
        Path cases = Path.of(System.getProperty(Files.TEST_DATA_PROPERTY), Files.PARITY_FILE);
        try (var lines = java.nio.file.Files.lines(cases)) {
            ObjectNode recurring = lines.map(JSON::readTree)
                .map(node -> (ObjectNode) node.get("input"))
                .filter(node -> "recurringMeaning".equals(node.path("semanticTaskKind").asString()))
                .findFirst()
                .orElseThrow();
            var service = new AnalysisService(CompactModel.factory(
                provider(UnaryOperator.identity(), new AtomicInteger(), new AtomicInteger())), 12000);
            var result = service.analyzeForStorage(recurring);
            assertNull(result.failure());
            assertEquals(recurring.path("items").get(0).get("candidateKey"),
                result.output().path("items").get(0).get("candidateKey"));
        }
        var mapper = new InputMapper(input(), new AnalysisContract());
        var codec = new CompactOutput(mapper.schema());
        ObjectNode value = codec.restore(response(codec.schema()));
        assertFalse(value.has("memories"));
        assertEquals("PAYSE-MEANING-1", value.path("meaningPolicyVersion").asString());
        assertThrows(ContractFailure.class, () -> codec.restore(JSON.createObjectNode()));
    }

    /**
     * 현재 계수·생성 경계만 대체하고 서비스의 실제 입력·출력 검증을 유지한다.
     * @created 2026-11-04
     * @usedBy 테스트 메서드
     */
    private ModelFactory provider(UnaryOperator<ObjectNode> change, AtomicInteger counts,
        AtomicInteger generations) {
        return (instructions, schema) -> new ModelGateway() {
            /**
             * 실제 전송 규격에 축약 지침이 연결됐는지 확인한다.
             * @created 2026-11-04
             * @usedBy AnalysisService
             */
            @Override
            public long countInput(JsonNode input) {
                counts.incrementAndGet();
                assertTrue(instructions.contains("PAYSE 내부 응답 전송 형식"));
                return 100;
            }

            /**
             * 규격에 맞는 합성 응답을 한 번만 만들고 지정한 반례만 추가한다.
             * @created 2026-11-04
             * @usedBy AnalysisService
             */
            @Override
            public ModelReply generate(JsonNode input) {
                generations.incrementAndGet();
                return new ModelReply(change.apply(response(schema)), USAGE, null);
            }
        };
    }

    /**
     * 별칭 스키마의 현재 항목에만 미확정 대역 출력을 만든다. 정확도 정답은 아니다.
     * @created 2026-11-04
     * @usedBy 테스트 공급자·직접 복원 검사
     */
    private ObjectNode response(ObjectNode schema) {
        JsonNode fields = schema.path("properties").path("rows").path("items").path("properties");
        ObjectNode result = JSON.createObjectNode();
        ObjectNode row = result.putArray("rows").addObject();
        row.put("i", "i1").put("m", "?insufficient_evidence");
        if (fields.has("c")) {
            row.put("c", "?insufficient_evidence");
        } else {
            row.put("q", "c1").putNull("n");
        }
        row.put("r", "거래 근거 부족").putArray("e").add("t1");
        if (fields.has("k")) {
            row.put("k", "1000").put("s", "현재 근거 확인");
        }
        return result;
    }

    /**
     * 기존 공개 계약 입력만 읽으며 키·정답·실행 결과에 접근하지 않는다.
     * @created 2026-11-04
     * @usedBy 테스트 메서드
     */
    private ObjectNode input() throws Exception {
        Path path = Path.of(System.getProperty(Files.TEST_DATA_PROPERTY), Files.INPUT_FILE);
        return (ObjectNode) JSON.readTree(java.nio.file.Files.readString(path));
    }
}
