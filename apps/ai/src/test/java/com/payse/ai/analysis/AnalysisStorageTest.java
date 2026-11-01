package com.payse.ai.analysis;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import java.util.function.UnaryOperator;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 AI 서비스의 단일 응답·보존 메타데이터 경계를 외부 호출 없는 공급자 대역으로 검사한다.
 * @created 2026-11-01
 * @usedBy JUnit
 */
class AnalysisStorageTest {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final TokenUsage USAGE = new TokenUsage(100, null, 30);

    /**
     * 기존 의미는 원형을 유지하고 보존 항목은 같은 ID로 복원되며 원본·결과 사본이 격리된다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void restoresBothPartsOnce() throws Exception {
        ObjectNode payload = input();
        ObjectNode before = payload.deepCopy();
        AtomicInteger calls = new AtomicInteger();
        var service = new AnalysisService((instructions, schema) -> {
            assertTrue(instructions.contains("PAYSE-MEMORY-1"));
            assertEquals(2, schema.get("properties").size());
            assertTrue(schema.get("properties").has("output"));
            assertTrue(schema.get("properties").has("memories"));
            return model(100, body -> {
                calls.incrementAndGet();
                assertFalse(body.has("context"));
                assertFalse(body.toString().contains(before.get("items").get(0).get("itemKey").asString()));
                return new ModelReply(wrapper(body), USAGE, null);
            });
        }, 6000);
        AnalysisResult result = service.analyzeForStorage(payload);
        String key = payload.get("items").get(0).get("itemKey").asString();
        assertNull(result.failure());
        assertEquals(USAGE, result.usage());
        assertEquals(before, payload);
        assertEquals(key, result.output().get("items").get(0).get("itemKey").asString());
        assertEquals(key, result.memories().get(0).itemKey());
        assertTrue(result.memories().get(0).important());
        assertEquals("required", result.memories().get(0).referencePolicy());
        assertFalse(result.output().has("memories"));
        assertFalse(result.output().get("items").get(0).has("important"));
        result.output().put("shouldNotPersist", true);
        assertFalse(result.output().has("shouldNotPersist"));
        assertThrows(UnsupportedOperationException.class, () -> result.memories().clear());
        assertEquals("AnalysisResult[REDACTED]", result.toString());
        assertEquals("MemoryDecision[REDACTED]", result.memories().get(0).toString());
        assertEquals(1, calls.get());
    }

    /**
     * 보존 목록의 누락·중복·추가·허용되지 않은 ID와 필드를 정상 결과로 저장하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsBrokenMetadata() throws Exception {
        String originalKey = input().get("items").get(0).get("itemKey").asString();
        List<UnaryOperator<ObjectNode>> mutations = List.of(
            root -> { root.remove("memories"); return root; },
            root -> { root.withArray("memories").removeAll(); return root; },
            root -> { root.withArray("memories").add(memory(root).deepCopy()); return root; },
            root -> { memory(root).put("itemKey", "i999"); return root; },
            root -> { memory(root).put("itemKey", "t1"); return root; },
            root -> { memory(root).put("itemKey", originalKey); return root; },
            root -> { memory(root).remove("active"); return root; },
            root -> { memory(root).put("active", "true"); return root; },
            root -> { memory(root).putNull("important"); return root; },
            root -> { memory(root).put("isReference", false); return root; },
            root -> { memory(root).put("referencePolicy", "forever"); return root; },
            root -> { memory(root).put("reason", "🌙".repeat(241)); return root; },
            root -> { memory(root).put("reason", "   "); return root; },
            root -> { memory(root).put("userId", originalKey); return root; },
            root -> { root.put("saved", true); return root; },
            root -> { root.remove("output"); return root; }
        );
        for (var mutation : mutations) {
            AtomicInteger calls = new AtomicInteger();
            var service = new AnalysisService((instructions, schema) -> model(100, body -> {
                calls.incrementAndGet();
                return new ModelReply(mutation.apply(wrapper(body)), USAGE, null);
            }), 6000);
            AnalysisResult result = service.analyzeForStorage(input());
            assertEquals("INVALID_MODEL_OUTPUT", result.failure());
            assertNull(result.output());
            assertTrue(result.memories().isEmpty());
            assertEquals(USAGE, result.usage());
            assertEquals(1, calls.get());
        }
    }

    /**
     * 같은 개수의 중복 보존 항목도 누락으로 거절하며 순서 차이는 허용한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void matchesEveryItemExactlyOnce() throws Exception {
        ObjectNode payload = twoItems();
        var duplicate = new AnalysisService((instructions, schema) -> model(100, body -> {
            ObjectNode response = wrapper(body);
            response.withArray("memories").set(1, memory(response).deepCopy());
            return new ModelReply(response, null, null);
        }), 6000);
        assertEquals("INVALID_MODEL_OUTPUT", duplicate.analyzeForStorage(payload).failure());
        var reverse = new AnalysisService((instructions, schema) -> model(100, body -> {
            ObjectNode response = wrapper(body);
            ObjectNode first = memory(response).deepCopy();
            response.withArray("memories").set(0, response.get("memories").get(1).deepCopy());
            response.withArray("memories").set(1, first);
            return new ModelReply(response, null, null);
        }), 6000);
        AnalysisResult result = reverse.analyzeForStorage(payload);
        assertNull(result.failure());
        assertEquals(payload.get("items").get(1).get("itemKey").asString(), result.memories().get(0).itemKey());
    }

    /**
     * 유니코드 240자 경계·독립 플래그·optional 정책을 손실 없이 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesAllowedMetadata() throws Exception {
        var service = new AnalysisService((instructions, schema) -> model(100, body -> {
            ObjectNode response = wrapper(body);
            memory(response).put("reason", "🌙".repeat(240)).put("active", false)
                .put("isReference", false).put("important", false).put("referencePolicy", "optional");
            return new ModelReply(response, null, null);
        }), 6000);
        AnalysisResult result = service.analyzeForStorage(input());
        assertNull(result.failure());
        assertNull(result.usage());
        assertFalse(result.memories().get(0).active());
        assertFalse(result.memories().get(0).isReference());
        assertEquals(240, result.memories().get(0).reason().codePointCount(0, result.memories().get(0).reason().length()));
    }

    /**
     * 보존 목록이 유효해도 기존 의미 검증이 실패하면 전체 응답 채택을 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void retainsMeaningValidation() throws Exception {
        var service = new AnalysisService((instructions, schema) -> model(100, body -> {
            ObjectNode response = wrapper(body);
            ((ObjectNode) response.get("output").get("items").get(0)).put("balanceKRW", 100);
            return new ModelReply(response, USAGE, null);
        }), 6000);
        assertEquals("INVALID_MODEL_OUTPUT", service.analyzeForStorage(input()).failure());
    }

    /**
     * 반복 의미도 같은 저장 봉투를 사용하며 후보 ID·금액·일정 계약을 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void supportsRecurringMeaning() throws Exception {
        ObjectNode payload = recurringInput();
        ObjectNode before = payload.deepCopy();
        var service = new AnalysisService((instructions, schema) -> model(100,
            body -> new ModelReply(wrapper(body), null, null)), 6000);
        AnalysisResult result = service.analyzeForStorage(payload);
        assertNull(result.failure());
        assertEquals(before, payload);
        assertEquals(payload.get("items").get(0).get("candidateKey"),
            result.output().get("items").get(0).get("candidateKey"));
        assertFalse(result.output().get("items").get(0).has("suggestedAmountKRW"));
    }

    /**
     * 공급자 거절·완료 불명·계수 실패·null 응답을 재호출 없이 기존 정책으로 전달한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesFailuresAndUnknownUsage() throws Exception {
        for (String code : List.of("MODEL_REFUSAL", "INCOMPLETE_RESPONSE", "INVALID_PROVIDER_RESPONSE", "INVALID_MODEL_OUTPUT")) {
            var service = new AnalysisService((instructions, schema) -> model(100,
                body -> new ModelReply(null, null, code)), 6000);
            AnalysisResult result = service.analyzeForStorage(input());
            assertEquals(code, result.failure());
            assertNull(result.usage());
            assertNull(result.output());
            assertTrue(result.memories().isEmpty());
        }
        AtomicInteger generations = new AtomicInteger();
        var overflow = new AnalysisService((instructions, schema) -> model(6001, body -> {
            generations.incrementAndGet();
            return new ModelReply(wrapper(body), null, null);
        }), 6000);
        var tooLarge = assertThrows(ModelFailure.class, () -> overflow.analyzeForStorage(input()));
        assertFalse(tooLarge.mayHaveBeenSent());
        assertEquals(0, generations.get());
        var timeout = new AnalysisService((instructions, schema) -> model(100, body -> {
            throw new ModelFailure("TRANSMISSION_UNKNOWN", ModelFailure.Stage.GENERATION, true);
        }), 6000);
        assertTrue(assertThrows(ModelFailure.class, () -> timeout.analyzeForStorage(input())).mayHaveBeenSent());
        var noReply = new AnalysisService((instructions, schema) -> model(100, body -> null), 6000);
        assertTrue(assertThrows(ModelFailure.class, () -> noReply.analyzeForStorage(input())).mayHaveBeenSent());
    }

    /**
     * 동시 저장용 호출의 보존 식별자가 다른 요청의 원래 ID로 복원되지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void isolatesStorageRequests() throws Exception {
        var service = new AnalysisService((instructions, schema) -> model(100,
            body -> new ModelReply(wrapper(body), null, null)), 6000);
        try (var pool = Executors.newFixedThreadPool(4)) {
            var tasks = new ArrayList<java.util.concurrent.Callable<Void>>();
            for (int index = 0; index < 20; index++) {
                ObjectNode payload = input();
                String key = UUID.randomUUID().toString();
                ((ObjectNode) payload.get("items").get(0)).put("itemKey", key);
                tasks.add(() -> {
                    AnalysisResult result = service.analyzeForStorage(payload);
                    assertNull(result.failure());
                    assertEquals(key, result.memories().get(0).itemKey());
                    assertEquals(key, result.output().get("items").get(0).get("itemKey").asString());
                    return null;
                });
            }
            for (var task : pool.invokeAll(tasks)) task.get();
        }
    }

    /**
     * 공개 합성 입력만 읽으며 정답·계정 자격·공급자 연결 정보를 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 저장 계약 테스트
     */
    private ObjectNode input() throws Exception {
        return (ObjectNode) JSON.readTree(Files.readString(Path.of(System.getProperty("payse.testData"), "service-input.json")));
    }

    /**
     * 기존 대조 자료에서 반복 입력 부분만 선택하며 기대 출력은 읽어 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy supportsRecurringMeaning
     */
    private ObjectNode recurringInput() throws Exception {
        try (var reader = Files.newBufferedReader(Path.of(System.getProperty("payse.testData"), "parity.jsonl"))) {
            String line;
            while ((line = reader.readLine()) != null) {
                JsonNode payload = JSON.readTree(line).get("input");
                if ("recurringMeaning".equals(payload.get("semanticTaskKind").asString())) return (ObjectNode) payload;
            }
        }
        throw new AssertionError("Recurring contract fixture required");
    }

    /**
     * 두 독립 항목을 준비하여 개수만 맞는 중복 메타데이터를 검사한다.
     * @created 2026-11-01
     * @usedBy matchesEveryItemExactlyOnce
     */
    private ObjectNode twoItems() throws Exception {
        ObjectNode payload = input();
        String id = UUID.randomUUID().toString();
        ObjectNode transaction = ((ObjectNode) payload.get("transactions").get(0)).deepCopy();
        transaction.put("transactionId", id);
        payload.withArray("transactions").add(transaction);
        ObjectNode item = ((ObjectNode) payload.get("items").get(0)).deepCopy();
        item.put("itemKey", id).put("targetTransactionId", id);
        item.putArray("evidenceTransactionIds").add(id);
        payload.withArray("items").add(item);
        return payload;
    }

    /**
     * 합성 unknown과 보존 제안을 생성하며 실제 의미 정확도 정답으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 공급자 대역
     */
    private ObjectNode wrapper(JsonNode input) {
        ObjectNode root = JSON.createObjectNode();
        ObjectNode output = root.putObject("output").put("meaningPolicyVersion", "PAYSE-MEANING-1");
        var items = output.putArray("items");
        var memories = root.putArray("memories");
        boolean recurring = "recurringMeaning".equals(input.get("semanticTaskKind").asString());
        for (JsonNode source : input.get("items")) {
            String key = source.get("itemKey").asString();
            ObjectNode item = items.addObject().put("itemKey", key).put("reason", "근거가 부족합니다.");
            item.set("evidenceTransactionIds", source.get("evidenceTransactionIds").deepCopy());
            item.putObject("meaning").put("status", "unknown").putNull("value").put("reasonCode", "insufficient_evidence");
            if (recurring) {
                item.set("candidateKey", source.get("candidateKey").deepCopy());
                item.put("name", "반복 지출 확인");
            } else {
                item.putObject("classification").put("status", "unknown").putNull("value").put("reasonCode", "insufficient_evidence");
            }
            memories.addObject().put("itemKey", key).put("active", true).put("isReference", true)
                .put("important", true).put("referencePolicy", "required").put("reason", "현재 근거와 이후 정정을 함께 확인합니다.");
        }
        return root;
    }

    /**
     * 반례 변형에서 첫 보존 객체를 명시적으로 고른다.
     * @created 2026-11-01
     * @usedBy 저장 계약 테스트
     */
    private ObjectNode memory(ObjectNode response) { return (ObjectNode) response.get("memories").get(0); }

    /**
     * 실제 서비스 실행 순서는 유지하고 계수·생성만 외부 호출 없는 대역으로 바꾼다.
     * @created 2026-11-01
     * @usedBy 저장 계약 테스트
     */
    private ModelGateway model(long count, Function<JsonNode, ModelReply> generate) {
        return new ModelGateway() {
            /**
             * 명시한 합성 토큰 계수를 반환한다.
             * @created 2026-11-01
             * @usedBy AnalysisService.analyzeForStorage
             */
            @Override public long countInput(JsonNode input) { return count; }
            /**
             * 지정한 단일 응답·실패만 반환한다.
             * @created 2026-11-01
             * @usedBy AnalysisService.analyzeForStorage
             */
            @Override public ModelReply generate(JsonNode input) { return generate.apply(input); }
        };
    }
}
