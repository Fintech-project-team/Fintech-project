package com.payse.ai.analysis;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.AiTestConstants.AnalysisFields;
import com.payse.ai.AiTestConstants.AnalysisValues;
import com.payse.ai.AiTestConstants.ProviderCodes;
import com.payse.ai.AiTestConstants.Schema;
import com.payse.ai.AiTestConstants;
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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void restoresBothPartsOnce() throws Exception {
        ObjectNode payload = input();
        ObjectNode before = payload.deepCopy();
        AtomicInteger calls = new AtomicInteger();

        var service = new AnalysisService(
            (instructions, schema) -> {
                assertTrue(instructions.contains(AnalysisValues.MEMORY_VERSION));
                assertEquals(2, schema.get(Schema.PROPERTIES).size());
                assertTrue(schema.get(Schema.PROPERTIES).has(AnalysisFields.OUTPUT));
                assertTrue(schema.get(Schema.PROPERTIES).has(AnalysisFields.MEMORIES));
                return model(
                    100,
                    body -> {
                        calls.incrementAndGet();
                        assertFalse(body.has(AnalysisFields.CONTEXT));
                        assertFalse(
                            body.toString()
                                .contains(
                                    before.get(AnalysisFields.ITEMS)
                                        .get(0)
                                        .get(AnalysisFields.ITEM_KEY)
                                        .asString()
                                )
                        );
                        return new ModelReply(wrapper(body), USAGE, null);
                    }
                );
            },
            6000
        );

        AnalysisResult result = service.analyzeForStorage(payload);
        String key = payload.get(AnalysisFields.ITEMS)
            .get(0)
            .get(AnalysisFields.ITEM_KEY)
            .asString();

        assertNull(result.failure());
        assertEquals(USAGE, result.usage());
        assertEquals(before, payload);
        assertEquals(
            key,
            result.output()
                .get(AnalysisFields.ITEMS)
                .get(0)
                .get(AnalysisFields.ITEM_KEY)
                .asString()
        );
        assertEquals(
            key,
            result.memories()
                .get(0)
                .itemKey()
        );
        assertTrue(
            result.memories()
                .get(0)
                .important()
        );
        assertEquals(
            AnalysisValues.REFERENCE_REQUIRED,
            result.memories()
                .get(0)
                .referencePolicy()
        );
        assertFalse(result.output().has(AnalysisFields.MEMORIES));
        assertFalse(
            result.output()
                .get(AnalysisFields.ITEMS)
                .get(0)
                .has(AnalysisFields.IMPORTANT)
        );

        result.output().put("shouldNotPersist", true);
        assertFalse(result.output().has("shouldNotPersist"));
        assertThrows(UnsupportedOperationException.class, () -> result.memories().clear());
        assertEquals(AnalysisValues.REDACTED_RESULT, result.toString());
        assertEquals(
            AnalysisValues.REDACTED_MEMORY,
            result.memories()
                .get(0)
                .toString()
        );
        assertEquals(1, calls.get());
    }

    /**
     * 보존 목록의 누락·중복·추가·허용되지 않은 ID와 필드를 정상 결과로 저장하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsBrokenMetadata() throws Exception {
        String originalKey = input()
            .get(AnalysisFields.ITEMS)
            .get(0)
            .get(AnalysisFields.ITEM_KEY)
            .asString();
        List<UnaryOperator<ObjectNode>> mutations = List.of(
            root -> {
                root.remove(AnalysisFields.MEMORIES);
                return root;
            },
            root -> {
                root.withArray(AnalysisFields.MEMORIES).removeAll();
                return root;
            },
            root -> {
                root.withArray(AnalysisFields.MEMORIES).add(memory(root).deepCopy());
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.ITEM_KEY, "i999");
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.ITEM_KEY, "t1");
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.ITEM_KEY, originalKey);
                return root;
            },
            root -> {
                memory(root).remove(AnalysisFields.ACTIVE);
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.ACTIVE, "true");
                return root;
            },
            root -> {
                memory(root).putNull(AnalysisFields.IMPORTANT);
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.IS_REFERENCE, false);
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.REFERENCE_POLICY, "forever");
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.REASON, "🌙".repeat(241));
                return root;
            },
            root -> {
                memory(root).put(AnalysisFields.REASON, "   ");
                return root;
            },
            root -> {
                memory(root).put("userId", originalKey);
                return root;
            },
            root -> {
                root.put("saved", true);
                return root;
            },
            root -> {
                root.remove(AnalysisFields.OUTPUT);
                return root;
            }
        );

        for (var mutation : mutations) {
            AtomicInteger calls = new AtomicInteger();

            var service = new AnalysisService(
                (instructions, schema) -> model(
                    100,
                    body -> {
                        calls.incrementAndGet();
                        return new ModelReply(mutation.apply(wrapper(body)), USAGE, null);
                    }
                ),
                6000
            );

            AnalysisResult result = service.analyzeForStorage(input());
            assertEquals(ProviderCodes.INVALID_MODEL_OUTPUT, result.failure());
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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void matchesEveryItemExactlyOnce() throws Exception {
        ObjectNode payload = twoItems();

        var duplicate = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> {
                    ObjectNode response = wrapper(body);
                    response.withArray(AnalysisFields.MEMORIES).set(1, memory(response).deepCopy());
                    return new ModelReply(response, null, null);
                }
            ),
            6000
        );
        assertEquals(
            ProviderCodes.INVALID_MODEL_OUTPUT,
            duplicate.analyzeForStorage(payload)
                .failure()
        );

        var reverse = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> {
                    ObjectNode response = wrapper(body);
                    ObjectNode first = memory(response).deepCopy();
                    response.withArray(AnalysisFields.MEMORIES)
                        .set(
                            0,
                            response.get(AnalysisFields.MEMORIES)
                                .get(1)
                                .deepCopy()
                        );
                    response.withArray(AnalysisFields.MEMORIES).set(1, first);
                    return new ModelReply(response, null, null);
                }
            ),
            6000
        );

        AnalysisResult result = reverse.analyzeForStorage(payload);

        assertNull(result.failure());
        assertEquals(
            payload.get(AnalysisFields.ITEMS)
                .get(1)
                .get(AnalysisFields.ITEM_KEY)
                .asString(),
            result.memories()
                .get(0)
                .itemKey()
        );
    }

    /**
     * 유니코드 240자 경계·독립 플래그·optional 정책을 손실 없이 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void preservesAllowedMetadata() throws Exception {
        var service = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> {
                    ObjectNode response = wrapper(body);
                    memory(response)
                        .put(AnalysisFields.REASON, "🌙".repeat(240))
                        .put(AnalysisFields.ACTIVE, false)
                        .put(AnalysisFields.IS_REFERENCE, false)
                        .put(AnalysisFields.IMPORTANT, false)
                        .put(AnalysisFields.REFERENCE_POLICY, AnalysisValues.OPTIONAL_REFERENCE);
                    return new ModelReply(response, null, null);
                }
            ),
            6000
        );

        AnalysisResult result = service.analyzeForStorage(input());

        assertNull(result.failure());
        assertNull(result.usage());
        assertFalse(
            result.memories()
                .get(0)
                .active()
        );
        assertFalse(
            result.memories()
                .get(0)
                .isReference()
        );
        String reason = result.memories()
            .get(0)
            .reason();
        assertEquals(240, reason.codePointCount(0, reason.length()));
    }

    /**
     * 보존 목록이 유효해도 기존 의미 검증이 실패하면 전체 응답 채택을 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void retainsMeaningValidation() throws Exception {
        var service = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> {
                    ObjectNode response = wrapper(body);
                    ((ObjectNode) response.get(AnalysisFields.OUTPUT)
                        .get(AnalysisFields.ITEMS)
                        .get(0)).put("balanceKRW", 100);
                    return new ModelReply(response, USAGE, null);
                }
            ),
            6000
        );
        assertEquals(
            ProviderCodes.INVALID_MODEL_OUTPUT,
            service.analyzeForStorage(input())
                .failure()
        );
    }

    /**
     * 반복 의미도 같은 저장 봉투를 사용하며 후보 ID·금액·일정 계약을 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void supportsRecurringMeaning() throws Exception {
        ObjectNode payload = recurringInput();
        ObjectNode before = payload.deepCopy();

        var service = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> new ModelReply(wrapper(body), null, null)
            ),
            6000
        );

        AnalysisResult result = service.analyzeForStorage(payload);

        assertNull(result.failure());
        assertEquals(before, payload);
        assertEquals(
            payload.get(AnalysisFields.ITEMS)
                .get(0)
                .get(AnalysisFields.CANDIDATE_KEY),
            result.output()
                .get(AnalysisFields.ITEMS)
                .get(0)
                .get(AnalysisFields.CANDIDATE_KEY)
        );
        assertFalse(
            result.output()
                .get(AnalysisFields.ITEMS)
                .get(0)
                .has(AnalysisFields.SUGGESTED_AMOUNT_KRW)
        );
    }

    /**
     * 공급자 거절·완료 불명·계수 실패·null 응답을 재호출 없이 기존 정책으로 전달한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void preservesFailuresAndUnknownUsage() throws Exception {
        List<String> failureCodes = List.of(
            ProviderCodes.MODEL_REFUSAL,
            ProviderCodes.INCOMPLETE_RESPONSE,
            ProviderCodes.INVALID_PROVIDER_RESPONSE,
            ProviderCodes.INVALID_MODEL_OUTPUT
        );
        for (String code : failureCodes) {
            var service = new AnalysisService(
                (instructions, schema) -> model(
                    100,
                    body -> new ModelReply(null, null, code)
                ),
                6000
            );

            AnalysisResult result = service.analyzeForStorage(input());
            assertEquals(code, result.failure());
            assertNull(result.usage());
            assertNull(result.output());
            assertTrue(result.memories().isEmpty());
        }
        AtomicInteger generations = new AtomicInteger();
        var overflow = new AnalysisService(
            (instructions, schema) -> model(
                6001,
                body -> {
                    generations.incrementAndGet();
                    return new ModelReply(wrapper(body), null, null);
                }
            ),
            6000
        );
        var tooLarge = assertThrows(ModelFailure.class, () -> overflow.analyzeForStorage(input()));
        assertFalse(tooLarge.mayHaveBeenSent());
        assertEquals(0, generations.get());
        var timeout = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> {
                    throw new ModelFailure(
                        ProviderCodes.TRANSMISSION_UNKNOWN,
                        ModelFailure.Stage.GENERATION,
                        true
                    );
                }
            ),
            6000
        );
        var timeoutFailure = assertThrows(
            ModelFailure.class,
            () -> timeout.analyzeForStorage(input())
        );
        assertTrue(timeoutFailure.mayHaveBeenSent());
        var noReply = new AnalysisService((instructions, schema) -> model(100, body -> null), 6000);
        var replyFailure = assertThrows(
            ModelFailure.class,
            () -> noReply.analyzeForStorage(input())
        );
        assertTrue(replyFailure.mayHaveBeenSent());
    }

    /**
     * 동시 저장용 호출의 보존 식별자가 다른 요청의 원래 ID로 복원되지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void isolatesStorageRequests() throws Exception {
        var service = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> new ModelReply(wrapper(body), null, null)
            ),
            6000
        );
        try (var pool = Executors.newFixedThreadPool(4)) {
            var tasks = new ArrayList<java.util.concurrent.Callable<Void>>();
            for (int index = 0; index < 20; index++) {
                ObjectNode payload = input();
                String key = UUID.randomUUID().toString();
                ((ObjectNode) payload.get(AnalysisFields.ITEMS).get(0))
                    .put(AnalysisFields.ITEM_KEY, key);
                tasks.add(
                    () -> {
                        AnalysisResult result = service.analyzeForStorage(payload);
                        assertNull(result.failure());
                        assertEquals(
                            key,
                            result.memories()
                                .get(0)
                                .itemKey()
                        );
                        assertEquals(
                            key,
                            result.output()
                                .get(AnalysisFields.ITEMS)
                                .get(0)
                                .get(AnalysisFields.ITEM_KEY)
                                .asString()
                        );
                        return null;
                    }
                );
            }
            var completed = pool.invokeAll(tasks);
            for (var task : completed) {
                task.get();
            }
        }
    }

    /**
     * 공개 합성 입력만 읽으며 정답·계정 자격·공급자 연결 정보를 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 저장 계약 테스트
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    private ObjectNode input() throws Exception {
        Path inputFile = Path.of(
            System.getProperty(AiTestConstants.Files.TEST_DATA_PROPERTY),
            AiTestConstants.Files.INPUT_FILE
        );
        String source = Files.readString(inputFile);
        return (ObjectNode) JSON.readTree(source);
    }

    /**
     * 기존 대조 자료에서 반복 입력 부분만 선택하며 기대 출력은 읽어 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy supportsRecurringMeaning
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    private ObjectNode recurringInput() throws Exception {
        Path casesFile = Path.of(
            System.getProperty(AiTestConstants.Files.TEST_DATA_PROPERTY),
            AiTestConstants.Files.PARITY_FILE
        );
        try (var reader = Files.newBufferedReader(casesFile)) {
            String line;
            while ((line = reader.readLine()) != null) {
                JsonNode payload = JSON.readTree(line).get(AnalysisFields.INPUT);
                if (AnalysisValues.RECURRING_MEANING.equals(
                    payload.get(AnalysisFields.SEMANTIC_TASK_KIND)
                        .asString()
                )) {
                    return (ObjectNode) payload;
                }
            }
        }
        throw new AssertionError("Recurring contract fixture required");
    }

    /**
     * 두 독립 항목을 준비하여 개수만 맞는 중복 메타데이터를 검사한다.
     * @created 2026-11-01
     * @usedBy matchesEveryItemExactlyOnce
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private ObjectNode twoItems() throws Exception {
        ObjectNode payload = input();
        String id = UUID.randomUUID().toString();
        ObjectNode transaction = ((ObjectNode) payload.get(AnalysisFields.TRANSACTIONS).get(0))
            .deepCopy();
        transaction.put(AnalysisFields.TRANSACTION_ID, id);
        payload.withArray(AnalysisFields.TRANSACTIONS).add(transaction);
        ObjectNode item = ((ObjectNode) payload.get(AnalysisFields.ITEMS).get(0)).deepCopy();
        item.put(AnalysisFields.ITEM_KEY, id).put(AnalysisFields.TARGET_TRANSACTION_ID, id);
        item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS).add(id);
        payload.withArray(AnalysisFields.ITEMS).add(item);
        return payload;
    }

    /**
     * 합성 unknown과 보존 제안을 생성하며 실제 의미 정확도 정답으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 공급자 대역
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private ObjectNode wrapper(JsonNode input) {
        ObjectNode root = JSON.createObjectNode();
        ObjectNode output = root.putObject(AnalysisFields.OUTPUT)
            .put(AnalysisFields.MEANING_POLICY_VERSION, AnalysisValues.MEANING_VERSION);
        var items = output.putArray(AnalysisFields.ITEMS);
        var memories = root.putArray(AnalysisFields.MEMORIES);
        boolean recurring = AnalysisValues.RECURRING_MEANING.equals(
            input.get(AnalysisFields.SEMANTIC_TASK_KIND)
                .asString()
        );
        for (JsonNode source : input.get(AnalysisFields.ITEMS)) {
            String key = source.get(AnalysisFields.ITEM_KEY).asString();
            ObjectNode item = items.addObject()
                .put(AnalysisFields.ITEM_KEY, key)
                .put(AnalysisFields.REASON, "근거가 부족합니다.");
            item.set(
                AnalysisFields.EVIDENCE_TRANSACTION_IDS,
                source.get(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
                    .deepCopy()
            );
            item.putObject(AnalysisFields.MEANING)
                .put(AnalysisFields.STATUS, AnalysisValues.UNKNOWN)
                .putNull(AnalysisFields.VALUE)
                .put(AnalysisFields.REASON_CODE, "insufficient_evidence");
            if (recurring) {
                item.set(
                    AnalysisFields.CANDIDATE_KEY,
                    source.get(AnalysisFields.CANDIDATE_KEY)
                        .deepCopy()
                );
                item.put(AnalysisFields.NAME, "반복 지출 확인");
            } else {
                item.putObject(AnalysisFields.CLASSIFICATION)
                    .put(AnalysisFields.STATUS, AnalysisValues.UNKNOWN)
                    .putNull(AnalysisFields.VALUE)
                    .put(AnalysisFields.REASON_CODE, "insufficient_evidence");
            }
            memories.addObject()
                .put(AnalysisFields.ITEM_KEY, key)
                .put(AnalysisFields.ACTIVE, true)
                .put(AnalysisFields.IS_REFERENCE, true)
                .put(AnalysisFields.IMPORTANT, true)
                .put(AnalysisFields.REFERENCE_POLICY, AnalysisValues.REFERENCE_REQUIRED)
                .put(AnalysisFields.REASON, "현재 근거와 이후 정정을 함께 확인합니다.");
        }
        return root;
    }

    /**
     * 반례 변형에서 첫 보존 객체를 명시적으로 고른다.
     * @created 2026-11-01
     * @usedBy 저장 계약 테스트
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private ObjectNode memory(ObjectNode response) {
        return (ObjectNode) response.get(AnalysisFields.MEMORIES)
            .get(0);
    }

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
            @Override
            public long countInput(JsonNode input) {
                return count;
            }

            /**
             * 지정한 단일 응답·실패만 반환한다.
             * @created 2026-11-01
             * @usedBy AnalysisService.analyzeForStorage
             */
            @Override
            public ModelReply generate(JsonNode input) {
                return generate.apply(input);
            }
        };
    }
}
