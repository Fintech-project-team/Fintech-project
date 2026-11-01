package com.payse.ai.analysis;

import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.provider.ModelGateway;


import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelFailure.Stage;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Function;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 실행 서비스에 공급자만 대역 주입하여 실패·근거 격리·토큰 제한을 검사한다.
 * @created 2026-11-01
 * @usedBy JUnit
 */
class AnalysisServiceTest {
    private static final JsonMapper JSON = JsonMapper.builder().build();

    /**
     * 실제 서비스의 계수·생성·복원을 통과하고 원본·모델 입력·개인정보 경계를 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void usesTheRuntimeWithMinimalInput() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        ObjectNode input = input();
        ObjectNode before = input.deepCopy();
        AnalysisService service = new AnalysisService((instructions, schema) -> {
            assertTrue(instructions.contains("PAYSE-MEANING-1"));
            for (String privateField : new String[] {"expectedBasicType", "expectedMeaning", "counterexample", "labelOrigin"}) {
                assertFalse(instructions.contains(privateField));
            }
            return model(6000, body -> {
                calls.incrementAndGet();
                assertFalse(body.has("context"));
                assertFalse(body.toString().contains(before.get("transactions").get(0).get("transactionId").asString()));
                assertFalse(body.has("expected"));
                return unknown(body);
            });
        }, 6000);
        ModelReply result = service.analyze(input);
        assertNull(result.failure());
        assertEquals(before, input);
        assertEquals(before.get("items").get(0).get("itemKey"), result.output().get("items").get(0).get("itemKey"));
        assertEquals(1, calls.get());
        assertNull(result.usage());
        assertEquals("AnalysisReply[REDACTED]", result.toString());
    }

    /**
     * 근거 오류는 공급자 생성 전, 토큰 한도 초과는 모델 생성 전 차단한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsInputAndTokenOverflowBeforeGeneration() throws Exception {
        AtomicInteger factories = new AtomicInteger();
        AtomicInteger generations = new AtomicInteger();
        var service = new AnalysisService((instructions, schema) -> {
            factories.incrementAndGet();
            return model(6001, body -> { generations.incrementAndGet(); return unknown(body); });
        }, 6000);
        ObjectNode bad = input();
        bad.put("unexpectedSecret", "never-send");
        assertThrows(ContractFailure.class, () -> service.analyze(bad));
        assertEquals(0, factories.get());
        var failure = assertThrows(ModelFailure.class, () -> service.analyze(input()));
        assertEquals(Stage.GENERATION, failure.stage());
        assertFalse(failure.mayHaveBeenSent());
        assertEquals(0, generations.get());
    }

    /**
     * HTTP 없는 공급자가 계수 불가를 알리면 생성·재시도·공급자 재선택 없이 종료한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void stopsWhenCountingIsUnavailable() throws Exception {
        AtomicInteger factories = new AtomicInteger();
        AtomicInteger generations = new AtomicInteger();
        var service = new AnalysisService((instructions, schema) -> {
            factories.incrementAndGet();
            return new ModelGateway() {
                /**
                 * 미준비 로컬 토크나이저를 대역으로 표현하고 0으로 대체하지 않는다.
                 * @created 2026-11-01
                 * @usedBy AnalysisService.analyze
                 */
                @Override
                public long countInput(JsonNode input) {
                    throw new ModelFailure("INPUT_TOKENS_UNAVAILABLE", Stage.INPUT_COUNT, false);
                }

                /**
                 * 계수 실패 뒤 실행되면 테스트가 실패하도록 호출 수를 센다.
                 * @created 2026-11-01
                 * @usedBy ModelGateway 테스트
                 */
                @Override
                public ModelReply generate(JsonNode input) {
                    generations.incrementAndGet();
                    return unknown(input);
                }
            };
        }, 6000);
        var failure = assertThrows(ModelFailure.class, () -> service.analyze(input()));
        assertEquals("INPUT_TOKENS_UNAVAILABLE", failure.getMessage());
        assertEquals(Stage.INPUT_COUNT, failure.stage());
        assertFalse(failure.mayHaveBeenSent());
        assertEquals(1, factories.get());
        assertEquals(0, generations.get());
    }

    /**
     * 공급자가 음수 계수를 반환해도 무제한 호출로 바꾸지 않고 생성 전 차단한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidCountWithoutGeneration() throws Exception {
        AtomicInteger generations = new AtomicInteger();
        var service = new AnalysisService((instructions, schema) -> model(-1, body -> {
            generations.incrementAndGet();
            return unknown(body);
        }), 6000);
        var failure = assertThrows(ModelFailure.class, () -> service.analyze(input()));
        assertEquals("INVALID_TOKEN_COUNT", failure.getMessage());
        assertEquals(Stage.GENERATION, failure.stage());
        assertFalse(failure.mayHaveBeenSent());
        assertEquals(0, generations.get());
    }

    /**
     * 누락·추가·중복·잘못된 ID·기존 분류 충돌을 성공이나 정상 unknown으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsBadOutputsWithoutRetry() throws Exception {
        List<Function<ObjectNode, ObjectNode>> changes = List.of(
            out -> { out.withArray("items").removeAll(); return out; },
            out -> { out.withArray("items").add(out.get("items").get(0).deepCopy()); return out; },
            out -> { ((ObjectNode) out.get("items").get(0)).put("itemKey", "foreign"); return out; },
            out -> { ((ObjectNode) out.get("items").get(0)).putArray("evidenceTransactionIds").add("t999"); return out; },
            out -> { ((ObjectNode) out.get("items").get(0).get("classification")).put("status", "candidate").put("value", "card_payment").put("reasonCode", "supported"); return out; },
            out -> { ((ObjectNode) out.get("items").get(0).get("meaning")).put("value", "salary"); return out; },
            out -> { out.put("balance", 1); return out; }
        );
        for (var change : changes) {
            AtomicInteger calls = new AtomicInteger();
            var service = new AnalysisService((instructions, schema) -> model(100, body -> {
                calls.incrementAndGet();
                return new ModelReply(change.apply(unknown(body).output()), new TokenUsage(100, 0L, 30), null);
            }), 6000);
            ModelReply result = service.analyze(input());
            assertEquals("INVALID_MODEL_OUTPUT", result.failure());
            assertNull(result.output());
            assertEquals(new TokenUsage(100, 0L, 30), result.usage());
            assertEquals(1, calls.get());
        }
    }

    /**
     * 공급자 거절·완료 불명·중단을 자동 재호출하지 않고 사용량·전송 가능성을 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void preservesProviderFailure() throws Exception {
        var refusal = new AnalysisService((instructions, schema) -> model(100,
            body -> new ModelReply(null, new TokenUsage(100, 0L, 5), "MODEL_REFUSAL")), 6000);
        ModelReply result = refusal.analyze(input());
        assertEquals("MODEL_REFUSAL", result.failure());
        assertNotNull(result.usage());
        var timeout = new AnalysisService((instructions, schema) -> model(100,
            body -> { throw new ModelFailure("TRANSMISSION_UNKNOWN", Stage.GENERATION, true); }), 6000);
        assertTrue(assertThrows(ModelFailure.class, () -> timeout.analyze(input())).mayHaveBeenSent());
    }

    /**
     * 한 서비스의 동시 호출에서도 요청별 별칭이 다른 사용자의 원래 식별자로 복원되지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void isolatesConcurrentRequests() throws Exception {
        var service = new AnalysisService((instructions, schema) -> model(1, this::unknown), 6000);
        try (var pool = Executors.newFixedThreadPool(4)) {
            var tasks = new ArrayList<java.util.concurrent.Callable<Void>>();
            for (int index = 0; index < 20; index++) {
                ObjectNode payload = input();
                String id = UUID.randomUUID().toString();
                ((ObjectNode) payload.get("transactions").get(0)).put("transactionId", id);
                ObjectNode item = (ObjectNode) payload.get("items").get(0);
                item.put("targetTransactionId", id).put("itemKey", id);
                item.putArray("evidenceTransactionIds").add(id);
                tasks.add(() -> {
                    var result = service.analyze(payload);
                    assertNull(result.failure());
                    assertEquals(id, result.output().get("items").get(0).get("evidenceTransactionIds").get(0).asString());
                    return null;
                });
            }
            for (var task : pool.invokeAll(tasks)) task.get();
        }
    }

    /**
     * 기존 공개 합성 입력만 읽고 비공개 정답은 읽지 않는다.
     * @created 2026-11-01
     * @usedBy 서비스 테스트
     */
    private ObjectNode input() throws Exception {
        return (ObjectNode) JSON.readTree(Files.readString(Path.of(System.getProperty("payse.testData"), "service-input.json")));
    }

    /**
     * 응답 전달 검사용 unknown을 만들며 이 응답을 정확도 정답으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 모의 ModelGateway
     */
    private ModelReply unknown(JsonNode input) {
        ObjectNode result = JSON.createObjectNode().put("meaningPolicyVersion", "PAYSE-MEANING-1");
        var items = result.putArray("items");
        for (JsonNode source : input.get("items")) {
            ObjectNode item = items.addObject().put("itemKey", source.get("itemKey").asString()).put("reason", "근거가 부족합니다.");
            item.set("evidenceTransactionIds", source.get("evidenceTransactionIds").deepCopy());
            for (String name : new String[] {"meaning", "classification"}) {
                item.putObject(name).put("status", "unknown").putNull("value").put("reasonCode", "insufficient_evidence");
            }
        }
        return new ModelReply(result, null, null);
    }

    /**
     * 실제 실행 순서는 유지하고 계수·응답만 통제한다.
     * @created 2026-11-01
     * @usedBy 서비스 테스트
     */
    private ModelGateway model(long count, Function<JsonNode, ModelReply> generate) {
        return new ModelGateway() {
            /**
             * 승인된 테스트 계수를 반환하며 외부 호출하지 않는다.
             * @created 2026-11-01
             * @usedBy AnalysisService.analyze
             */
            @Override public long countInput(JsonNode input) { return count; }
            /**
             * 대역 응답 또는 실패를 한 번 전달한다.
             * @created 2026-11-01
             * @usedBy AnalysisService.analyze
             */
            @Override public ModelReply generate(JsonNode input) { return generate.apply(input); }
        };
    }
}
