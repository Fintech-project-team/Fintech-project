package com.payse.ai.analysis;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.AiTestConstants.AnalysisFields;
import com.payse.ai.AiTestConstants.AnalysisValues;
import com.payse.ai.AiTestConstants.ProviderCodes;
import com.payse.ai.AiTestConstants.ProviderValues;
import com.payse.ai.AiTestConstants;
import com.payse.ai.analysis.service.AnalysisService;
import com.payse.ai.analysis.validation.AnalysisContract;
import com.payse.ai.analysis.validation.ContractFailure;
import com.payse.ai.provider.ModelFailure.Stage;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
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
    /**
     * 한글·표 형태로 줄인 기준을 복원하면 공개 원문의 값·구조가 모두 일치한다.
     * @created 2026-11-03
     * @usedBy JUnit
     * @modified 2026-11-04 - 공통 근거를 복원하여 41개 의미의 모든 기준 보존 확인
     */
    @Test
    void preservesCriteriaWithoutEscapedUnicode() throws Exception {
        try (var stream = getClass().getResourceAsStream(AnalysisValues.CRITERIA_RESOURCE)) {
            assertNotNull(stream);
            String raw = new String(stream.readAllBytes(), StandardCharsets.UTF_8);
            String instructions = new AnalysisContract().instructions();
            String criteria = instructions.substring(instructions.indexOf('{'));
            ObjectNode restored = (ObjectNode) JSON.readTree(criteria);
            JsonNode common = restored.remove("commonEvidence");
            assertNotNull(common);
            assertFalse(common.path("requiredEvidence").isEmpty());
            assertFalse(common.path("insufficientEvidence").isEmpty());
            JsonNode table = restored.get(AnalysisFields.MEANINGS);
            JsonNode columns = table.get(AnalysisFields.COLUMNS);
            var meanings = restored.putArray(AnalysisFields.MEANINGS);
            for (JsonNode row : table.get(AnalysisFields.ROWS)) {
                assertEquals(columns.size(), row.size());
                ObjectNode meaning = meanings.addObject();
                for (int index = 0; index < columns.size(); index++) {
                    String column = columns.get(index).asString();
                    if (common.has(column)) {
                        var evidence = meaning.putArray(column);
                        for (JsonNode value : row.get(index)) {
                            evidence.add(value.isIntegralNumber()
                                ? common.get(column).get(value.asInt()) : value);
                        }
                    } else {
                        meaning.set(column, row.get(index).deepCopy());
                    }
                }
            }
            assertEquals(JSON.readTree(raw), restored);
            assertFalse(criteria.contains("\\u"));
            assertTrue(criteria.length() < raw.length() / 2);
        }
    }

    /**
     * 서버의 금액·날짜만 결합하고 원래 ID·원천 객체·민감 추가 필드는 외부로 내보내지 않는다.
     * @created 2026-11-03
     * @usedBy JUnit
     * @modified 2026-11-04 - 모델 전용 null 생략과 공개 입력 불변을 구별하여 검사
     */
    @Test
    void usesSourceFactsWithoutChangingPublicInput() throws Exception {
        ObjectNode payload = input();
        ObjectNode before = payload.deepCopy();
        ObjectNode facts = JSON.createObjectNode();
        facts.set("asOf", payload.path("context").path("asOf"));
        var rows = facts.putArray("transactions");
        String account = UUID.randomUUID().toString();
        for (JsonNode transaction : payload.path("transactions")) {
            ObjectNode row = rows.addObject();
            row.set("transactionId", transaction.path("transactionId"));
            row.put("amountKRW", 123456).put("accountId", account).putNull("cardId");
            for (String name : List.of(
                "purchaseDate", "withdrawalDate", "refundDate", "cancellationDate",
                "bookingDate", "occurredAt", "occurredAtBasis"
            )) {
                row.putNull(name);
            }
        }
        AtomicInteger calls = new AtomicInteger();
        AnalysisService service = new AnalysisService(
            (instructions, schema) -> model(100, body -> {
                calls.incrementAndGet();
                JsonNode target = body.path("items").get(0).path("target");
                assertEquals(123456, target.path("amountKRW").asInt());
                assertFalse(body.toString().contains(account));
                assertEquals("a1", target.path("accountId").asString());
                assertTrue(target.path("bookingDate").isMissingNode());
                assertEquals(facts.path("asOf"), body.path("asOf"));
                return new ModelReply(null, new TokenUsage(100, null, 10), "MODEL_REFUSAL");
            }),
            6000
        );
        assertEquals("MODEL_REFUSAL", service.analyzeForStorage(payload, facts).failure());
        assertEquals(before, payload);
        ((ObjectNode) rows.get(0)).put("expectedMeaning", "never-send-gold");
        assertThrows(ContractFailure.class, () -> service.analyzeForStorage(payload, facts));
        assertEquals(1, calls.get());
    }

    private static final JsonMapper JSON = JsonMapper.builder().build();

    /**
     * 실제 서비스의 계수·생성·복원을 통과하고 원본·모델 입력·개인정보 경계를 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     */
    @Test
    void usesTheRuntimeWithMinimalInput() throws Exception {
        AtomicInteger calls = new AtomicInteger();
        ObjectNode input = input();
        ObjectNode before = input.deepCopy();

        AnalysisService service = new AnalysisService(
            (instructions, schema) -> {
                assertTrue(instructions.contains(AnalysisValues.MEANING_VERSION));
                String[] privateFields = {
                    AnalysisFields.EXPECTED_BASIC_TYPE,
                    AnalysisFields.EXPECTED_MEANING,
                    AnalysisFields.COUNTEREXAMPLE,
                    AnalysisFields.LABEL_ORIGIN
                };
                for (String privateField : privateFields) {
                    assertFalse(instructions.contains(privateField));
                }
                return model(
                    6000,
                    body -> {
                        calls.incrementAndGet();
                        assertFalse(body.has(AnalysisFields.CONTEXT));
                        assertFalse(
                            body.toString()
                                .contains(
                                    before.get(AnalysisFields.TRANSACTIONS)
                                        .get(0)
                                        .get(AnalysisFields.TRANSACTION_ID)
                                        .asString()
                                )
                        );
                        assertFalse(body.has(AnalysisFields.EXPECTED));
                        return unknown(body);
                    }
                );
            },
            6000
        );

        ModelReply result = service.analyze(input);

        assertNull(result.failure());
        assertEquals(before, input);
        assertEquals(
            before.get(AnalysisFields.ITEMS)
                .get(0)
                .get(AnalysisFields.ITEM_KEY),
            result.output()
                .get(AnalysisFields.ITEMS)
                .get(0)
                .get(AnalysisFields.ITEM_KEY)
        );
        assertEquals(1, calls.get());
        assertNull(result.usage());
        assertEquals(ProviderValues.REDACTED_REPLY, result.toString());
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

        var service = new AnalysisService(
            (instructions, schema) -> {
                factories.incrementAndGet();
                return model(
                    6001,
                    body -> {
                        generations.incrementAndGet();
                        return unknown(body);
                    }
                );
            },
            6000
        );

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
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void stopsWhenCountingIsUnavailable() throws Exception {
        AtomicInteger factories = new AtomicInteger();
        AtomicInteger generations = new AtomicInteger();

        var service = new AnalysisService(
            (instructions, schema) -> {
                factories.incrementAndGet();
                return new ModelGateway() {
                    /**
                     * 미준비 로컬 토크나이저를 대역으로 표현하고 0으로 대체하지 않는다.
                     * @created 2026-11-01
                     * @usedBy AnalysisService.analyze
                     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
                     */
                    @Override
                    public long countInput(JsonNode input) {
                        throw new ModelFailure(
                            ProviderCodes.INPUT_TOKENS_UNAVAILABLE,
                            Stage.INPUT_COUNT,
                            false
                        );
                    }

                    /**
                     * 계수 실패 뒤 실행되면 테스트가 실패하도록 호출 수를 센다.
                     * @created 2026-11-01
                     * @usedBy ModelGateway 테스트
                     * @modified 2026-11-02 - 상수 타입 명시 참조
                     */
                    @Override
                    public ModelReply generate(JsonNode input) {
                        generations.incrementAndGet();
                        return unknown(input);
                    }
                };
            },
            6000
        );

        var failure = assertThrows(ModelFailure.class, () -> service.analyze(input()));
        assertEquals(ProviderCodes.INPUT_TOKENS_UNAVAILABLE, failure.getMessage());
        assertEquals(Stage.INPUT_COUNT, failure.stage());
        assertFalse(failure.mayHaveBeenSent());
        assertEquals(1, factories.get());
        assertEquals(0, generations.get());
    }

    /**
     * 공급자가 음수 계수를 반환해도 무제한 호출로 바꾸지 않고 생성 전 차단한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsInvalidCountWithoutGeneration() throws Exception {
        AtomicInteger generations = new AtomicInteger();

        var service = new AnalysisService(
            (instructions, schema) -> model(
                -1,
                body -> {
                    generations.incrementAndGet();
                    return unknown(body);
                }
            ),
            6000
        );

        var failure = assertThrows(ModelFailure.class, () -> service.analyze(input()));
        assertEquals(ProviderCodes.INVALID_TOKEN_COUNT, failure.getMessage());
        assertEquals(Stage.GENERATION, failure.stage());
        assertFalse(failure.mayHaveBeenSent());
        assertEquals(0, generations.get());
    }

    /**
     * 누락·추가·중복·잘못된 ID·기존 분류 충돌을 성공이나 정상 unknown으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void rejectsBadOutputsWithoutRetry() throws Exception {
        List<Function<ObjectNode, ObjectNode>> changes = List.of(
            out -> {
                out.withArray(AnalysisFields.ITEMS).removeAll();
                return out;
            },
            out -> {
                var items = out.withArray(AnalysisFields.ITEMS);
                JsonNode duplicate = out.get(AnalysisFields.ITEMS)
                    .get(0)
                    .deepCopy();
                items.add(duplicate);
                return out;
            },
            out -> {
                ObjectNode item = (ObjectNode) out.get(AnalysisFields.ITEMS).get(0);
                item.put(AnalysisFields.ITEM_KEY, "foreign");
                return out;
            },
            out -> {
                ObjectNode item = (ObjectNode) out.get(AnalysisFields.ITEMS).get(0);
                item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS).add("t999");
                return out;
            },
            out -> {
                ObjectNode classification = (ObjectNode) out.get(AnalysisFields.ITEMS)
                    .get(0)
                    .get(AnalysisFields.CLASSIFICATION);
                classification.put(AnalysisFields.STATUS, AnalysisValues.CANDIDATE)
                    .put(AnalysisFields.VALUE, AnalysisValues.CARD_PAYMENT)
                    .put(AnalysisFields.REASON_CODE, AnalysisValues.SUPPORTED);
                return out;
            },
            out -> {
                ObjectNode meaning = (ObjectNode) out.get(AnalysisFields.ITEMS)
                    .get(0)
                    .get(AnalysisFields.MEANING);
                meaning.put(AnalysisFields.VALUE, AnalysisValues.SALARY);
                return out;
            },
            out -> {
                out.put("balance", 1);
                return out;
            }
        );
        for (var change : changes) {
            AtomicInteger calls = new AtomicInteger();

            var service = new AnalysisService(
                (instructions, schema) -> model(
                    100,
                    body -> {
                        calls.incrementAndGet();
                        ObjectNode changed = change.apply(unknown(body).output());
                        return new ModelReply(changed, new TokenUsage(100, 0L, 30), null);
                    }
                ),
                6000
            );

            ModelReply result = service.analyze(input());
            assertEquals(ProviderCodes.INVALID_MODEL_OUTPUT, result.failure());
            assertNull(result.output());
            assertEquals(new TokenUsage(100, 0L, 30), result.usage());
            assertEquals(1, calls.get());
        }
    }

    /**
     * 공급자 거절·완료 불명·중단을 자동 재호출하지 않고 사용량·전송 가능성을 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void preservesProviderFailure() throws Exception {
        var refusal = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> new ModelReply(
                    null,
                    new TokenUsage(100, 0L, 5),
                    ProviderCodes.MODEL_REFUSAL
                )
            ),
            6000
        );

        ModelReply result = refusal.analyze(input());
        assertEquals(ProviderCodes.MODEL_REFUSAL, result.failure());
        assertNotNull(result.usage());
        var timeout = new AnalysisService(
            (instructions, schema) -> model(
                100,
                body -> {
                    throw new ModelFailure(
                        ProviderCodes.TRANSMISSION_UNKNOWN,
                        Stage.GENERATION,
                        true
                    );
                }
            ),
            6000
        );
        assertTrue(
            assertThrows(ModelFailure.class, () -> timeout.analyze(input()))
                .mayHaveBeenSent()
        );
    }

    /**
     * 한 서비스의 동시 호출에서도 요청별 별칭이 다른 사용자의 원래 식별자로 복원되지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void isolatesConcurrentRequests() throws Exception {
        var service = new AnalysisService((instructions, schema) -> model(1, this::unknown), 6000);
        try (var pool = Executors.newFixedThreadPool(4)) {
            var tasks = new ArrayList<java.util.concurrent.Callable<Void>>();
            for (int index = 0; index < 20; index++) {
                ObjectNode payload = input();
                String id = UUID.randomUUID().toString();
                ((ObjectNode) payload.get(AnalysisFields.TRANSACTIONS).get(0))
                    .put(AnalysisFields.TRANSACTION_ID, id);
                ObjectNode item = (ObjectNode) payload.get(AnalysisFields.ITEMS).get(0);
                item.put(AnalysisFields.TARGET_TRANSACTION_ID, id).put(AnalysisFields.ITEM_KEY, id);
                item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS).add(id);
                tasks.add(
                    () -> {
                        var result = service.analyze(payload);
                        assertNull(result.failure());
                        JsonNode restoredItem = result.output()
                            .get(AnalysisFields.ITEMS)
                            .get(0);
                        String restoredId = restoredItem
                            .get(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
                            .get(0)
                            .asString();
                        assertEquals(id, restoredId);
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
     * 감마 연간 거래와 반복 입력을 실제 실행 서비스로 처리하며 공급자만 대역으로 둔다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void processesGammaYearWithoutGoldLabels() throws Exception {
        Path file = Path.of(
            System.getProperty(AiTestConstants.Files.TEST_DATA_PROPERTY),
            AiTestConstants.Files.GAMMA_YEAR_FILE
        );
        JsonNode batches = JSON.readTree(Files.readString(file));
        assertEquals(97, batches.size());
        var seen = new java.util.HashSet<String>();
        AtomicInteger calls = new AtomicInteger();
        AnalysisService service = new AnalysisService(
            (instructions, schema) -> model(
                6000,
                body -> {
                    calls.incrementAndGet();
                    assertFalse(body.toString().contains("scenarioTruth"));
                    assertFalse(body.toString().contains("openingBalancesKRW"));
                    assertFalse(body.toString().contains("payseTransactionType"));
                    return unknown(body);
                }
            ),
            6000
        );
        for (JsonNode batch : batches) {
            assertTrue(batch.get(AnalysisFields.TRANSACTIONS).size() <= 20);
            assertTrue(batch.get(AnalysisFields.CURRENT_CLASSIFICATIONS).isEmpty());
            for (JsonNode transaction : batch.get(AnalysisFields.TRANSACTIONS)) {
                seen.add(transaction.get(AnalysisFields.TRANSACTION_ID).asString());
            }
            ModelReply reply = service.analyze((ObjectNode) batch);
            assertNull(reply.failure());
            assertEquals(
                batch.get(AnalysisFields.ITEMS).size(),
                reply.output().get(AnalysisFields.ITEMS).size()
            );
        }
        assertEquals(1825, seen.size());
        assertEquals(97, calls.get());
    }

    /**
     * 기존 공개 합성 입력만 읽고 비공개 정답은 읽지 않는다.
     * @created 2026-11-01
     * @usedBy 서비스 테스트
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
     * 응답 전달 검사용 unknown을 만들며 이 응답을 정확도 정답으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy 모의 ModelGateway
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     * @modified 2026-11-03 - 연간 반복 후보의 정상 unknown 응답도 제공
     */
    private ModelReply unknown(JsonNode input) {
        ObjectNode result = JSON.createObjectNode()
            .put(AnalysisFields.MEANING_POLICY_VERSION, AnalysisValues.MEANING_VERSION);
        var items = result.putArray(AnalysisFields.ITEMS);
        for (JsonNode source : input.get(AnalysisFields.ITEMS)) {
            ObjectNode item = items.addObject()
                .put(AnalysisFields.ITEM_KEY, source.get(AnalysisFields.ITEM_KEY).asString())
                .put(AnalysisFields.REASON, "근거가 부족합니다.");
            item.set(
                AnalysisFields.EVIDENCE_TRANSACTION_IDS,
                source.get(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
                    .deepCopy()
            );
            boolean recurring = input.get(AnalysisFields.SEMANTIC_TASK_KIND)
                .asString().equals(AnalysisValues.RECURRING_MEANING);
            if (recurring) {
                item.set(AnalysisFields.CANDIDATE_KEY, source.get(AnalysisFields.CANDIDATE_KEY));
                item.putNull(AnalysisFields.NAME);
            }
            for (String name : new String[] {
                AnalysisFields.MEANING,
                AnalysisFields.CLASSIFICATION }) {
                if (recurring && name.equals(AnalysisFields.CLASSIFICATION)) {
                    continue;
                }
                item.putObject(name)
                    .put(AnalysisFields.STATUS, AnalysisValues.UNKNOWN)
                    .putNull(AnalysisFields.VALUE)
                    .put(AnalysisFields.REASON_CODE, "insufficient_evidence");
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
            @Override
            public long countInput(JsonNode input) {
                return count;
            }

            /**
             * 대역 응답 또는 실패를 한 번 전달한다.
             * @created 2026-11-01
             * @usedBy AnalysisService.analyze
             */
            @Override
            public ModelReply generate(JsonNode input) {
                return generate.apply(input);
            }
        };
    }
}
