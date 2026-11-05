package com.payse.ai.provider.openai;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.AiTestConstants.AnalysisFields;
import com.payse.ai.AiTestConstants.Files;
import com.payse.ai.AiTestConstants.OpenAiFields;
import com.payse.ai.AiTestConstants.OpenAiValues;
import com.payse.ai.AiTestConstants.ProviderCodes;
import com.payse.ai.AiTestConstants.ProviderValues;
import com.payse.ai.AiTestConstants.Schema;
import com.payse.ai.provider.ModelFailure.Stage;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import com.payse.ai.testing.ProviderStub;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 로컬 모의 공급자로 구조화 요청과 사용량·실패 처리를 검사한다. 업무 해석 스키마를 확정하지 않는다.
 * @created 2026-11-01
 * @usedBy JUnit 5
 */
class OpenAiGatewayTest {
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final String USAGE = "{\"input_tokens\":21,\"output_tokens\":7,"
        + "\"input_tokens_details\":{\"cached_tokens\":5}}";

    /**
     * 계수·생성에 같은 응답 길이 정책을 보내고 미지정 요청과 잘못된 설정을 구분한다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void boundsVerbosityWithoutChangingValidation() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.sequence(
                "{\"object\":\"response.input_tokens\",\"input_tokens\":21}",
                completed("{}", USAGE)
            );
            var gateway = new OpenAiGateway(
                provider.http(),
                () -> OpenAiValues.CREDENTIAL,
                "approved-test-model",
                "Return JSON",
                OpenAiValues.EFFORT_LOW,
                schema(),
                100,
                40,
                provider.endpoint(),
                "default",
                "low"
            );
            assertEquals(21, gateway.countInput(input()));
            assertNull(gateway.generate(input()).failure());
            for (var request : provider.requests()) {
                assertEquals("low", request.body().path(OpenAiFields.TEXT)
                    .path(OpenAiFields.VERBOSITY).asString());
            }
            assertEquals(2, provider.requests().size());
            assertThrows(IllegalArgumentException.class, () -> new OpenAiGateway(
                provider.http(),
                () -> OpenAiValues.CREDENTIAL,
                "approved-test-model",
                "Return JSON",
                OpenAiValues.EFFORT_LOW,
                schema(),
                100,
                40,
                provider.endpoint(),
                "default",
                "invalid"
            ));
            provider.reply(200, completed("{}", USAGE));
            assertNull(gateway(provider).generate(input()).failure());
            assertFalse(provider.requests().get(2).body().path(OpenAiFields.TEXT)
                .has(OpenAiFields.VERBOSITY));
        }
    }

    /**
     * 중간 진행문을 JSON으로 읽지 않고 한 최종 응답만 허용하며 실패·사용량을 보존한다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void distinguishesCommentaryFromFinalAnswer() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            ObjectNode response = (ObjectNode) JSON.readTree(completed("{}", USAGE));
            ObjectNode finalMessage = (ObjectNode) response.get(OpenAiFields.OUTPUT).get(0);
            finalMessage.put(OpenAiFields.PHASE, "final_answer");
            ObjectNode progress = finalMessage.deepCopy().put(OpenAiFields.PHASE, "commentary");
            ((ObjectNode) progress.get(OpenAiFields.CONTENT).get(0))
                .put(OpenAiFields.TEXT, "private-progress-sentinel, not JSON");
            response.putArray(OpenAiFields.OUTPUT)
                .add(progress)
                .add(finalMessage);
            provider.reply(200, response.toString());
            var reply = gateway.generate(input());
            assertNull(reply.failure());
            assertEquals(JSON.createObjectNode(), reply.output());
            assertEquals(new TokenUsage(21, 5L, 7), reply.usage());

            response.putArray(OpenAiFields.OUTPUT).add(progress);
            provider.reply(200, response.toString());
            assertEquals(ProviderCodes.INVALID_PROVIDER_RESPONSE,
                gateway.generate(input()).failure());
            response.putArray(OpenAiFields.OUTPUT)
                .add(finalMessage)
                .add(finalMessage.deepCopy());
            provider.reply(200, response.toString());
            assertEquals(ProviderCodes.INVALID_PROVIDER_RESPONSE,
                gateway.generate(input()).failure());
            finalMessage.put(OpenAiFields.PHASE, "unrecognized");
            response.putArray(OpenAiFields.OUTPUT).add(finalMessage);
            provider.reply(200, response.toString());
            assertEquals(ProviderCodes.INVALID_PROVIDER_RESPONSE,
                gateway.generate(input()).failure());
            finalMessage.putNull(OpenAiFields.PHASE);
            provider.reply(200, response.toString());
            assertNull(gateway.generate(input()).failure());
            progress.put(OpenAiFields.STATUS, "incomplete");
            response.putArray(OpenAiFields.OUTPUT)
                .add(progress)
                .add(finalMessage);
            provider.reply(200, response.toString());
            assertEquals(ProviderCodes.INCOMPLETE_RESPONSE, gateway.generate(input()).failure());
            progress.put(OpenAiFields.STATUS, "completed");
            ((ObjectNode) progress.get(OpenAiFields.CONTENT).get(0))
                .put(OpenAiFields.TYPE_KEY, "refusal");
            provider.reply(200, response.toString());
            assertEquals(ProviderCodes.MODEL_REFUSAL, gateway.generate(input()).failure());
            assertEquals(7, provider.requests().size());
        }
    }

    /**
     * 표준·Fast 생성 선택을 명시하고 계수 요청이나 자동 재시도로 확대하지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void serviceTiersAreExplicit() throws Exception {
        for (String tier : new String[] {"default", "fast"}) {
            try (var provider = new ProviderStub()) {
                ObjectNode reply = (ObjectNode) JSON.readTree(completed("{}", USAGE));
                reply.put(OpenAiFields.SERVICE_TIER, tier);
                provider.sequence("{\"object\":\"response.input_tokens\",\"input_tokens\":21}",
                    reply.toString());
                var gateway = new OpenAiGateway(
                    provider.http(),
                    () -> OpenAiValues.CREDENTIAL,
                    "approved-test-model",
                    "Return JSON",
                    OpenAiValues.EFFORT_LOW,
                    schema(),
                    100,
                    40,
                    provider.endpoint(),
                    tier
                );
                assertEquals(21, gateway.countInput(input()));
                assertNull(gateway.generate(input()).failure());
                assertEquals(2, provider.requests().size());
                var countRequest = provider.requests().get(0).body();
                var generationRequest = provider.requests().get(1).body();
                assertFalse(countRequest.has(OpenAiFields.SERVICE_TIER));
                assertEquals(tier, generationRequest.path(OpenAiFields.SERVICE_TIER).asString());
                assertThrows(IllegalArgumentException.class, () -> new OpenAiGateway(
                    provider.http(), () -> OpenAiValues.CREDENTIAL, "approved-test-model",
                    "Return JSON", OpenAiValues.EFFORT_LOW, schema(), 100, 40,
                    provider.endpoint(), "flex"));
                assertEquals(2, provider.requests().size());
            }
        }
    }

    /**
     * 실제 서비스에서 실제 HTTP 어댑터를 호출하되 네트워크 대상만 로컬 대역으로 고정한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void runtimeFlow() throws Exception {
        try (var provider = new ProviderStub()) {
            var inputFile = java.nio.file.Path
                .of(System.getProperty(Files.TEST_DATA_PROPERTY), Files.INPUT_FILE);
            String source = java.nio.file.Files.readString(inputFile);
            ObjectNode input = (ObjectNode) JSON.readTree(source);
            String output =
                "{\"meaningPolicyVersion\":\"PAYSE-MEANING-1\",\"items\":[{\"itemKey\":\"i1\","
                + "\"meaning\":{\"status\":\"unknown\",\"value\":null,\"reasonCode\":\"insufficient_evidence\"},"
                + "\"classification\":{\"status\":\"unknown\",\"value\":null,\"reasonCode\":\"insufficient_evidence\"},"
                + "\"reason\":\"전달 검사용 대역 응답\",\"evidenceTransactionIds\":[\"t1\"]}]}";
            provider.sequence(
                "{\"object\":\"response.input_tokens\",\"input_tokens\":21}",
                completed(output, USAGE)
            );

            var service = new com.payse.ai.analysis.service.AnalysisService(
                (instructions, schema) -> new OpenAiGateway(
                    provider.http(),
                    () -> OpenAiValues.CREDENTIAL,
                    "approved-test-model",
                    instructions,
                    OpenAiValues.EFFORT_LOW,
                    schema,
                    6000,
                    1200,
                    provider.endpoint()
                ),
                6000
            );

            var result = service.analyze(input);
            assertNull(result.failure());
            assertEquals(
                input.get(AnalysisFields.ITEMS)
                    .get(0)
                    .get(AnalysisFields.EVIDENCE_TRANSACTION_IDS),
                result.output()
                    .get(AnalysisFields.ITEMS)
                    .get(0)
                    .get(AnalysisFields.EVIDENCE_TRANSACTION_IDS)
            );
            assertEquals(new TokenUsage(21, 5L, 7), result.usage());
            assertEquals(2, provider.requests().size());

            // HTTP·OpenAI 응답 봉투가 없는 대역도 동일한 업무 입력/출력 경계를 사용한다.

            var offline = new com.payse.ai.analysis.service.AnalysisService(
                (instructions, schema) -> {
                    JsonNode captured = provider.requests()
                        .get(0)
                        .body();
                    assertEquals(instructions, captured.get(OpenAiFields.INSTRUCTIONS).asString());
                    JsonNode capturedSchema = provider.requests()
                        .get(0)
                        .body()
                        .path(OpenAiFields.TEXT)
                        .path(OpenAiFields.FORMAT)
                        .get(OpenAiFields.SCHEMA);
                    assertEquals(schema, capturedSchema);
                    return new ModelGateway() {
                        /**
                         * 네트워크 없는 합성 계수를 반환한다. 실제 토크나이저 검증은 아니다.
                         * @created 2026-11-01
                         * @usedBy AnalysisService.analyze
                         * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
                         * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
                         */
                        @Override
                        public long countInput(JsonNode body) {
                            String capturedInput = provider.requests()
                                .get(0)
                                .body()
                                .get(OpenAiFields.INPUT)
                                .asString();
                            JsonNode decoded = JSON.readTree(capturedInput);
                            assertEquals(decoded, body);
                            return 21;
                        }

                        /**
                         * 정규화된 동일 응답을 직접 반환하며 캐시 사용량 미확인을 유지한다.
                         * @created 2026-11-01
                         * @usedBy AnalysisService.analyze
                         */
                        @Override
                        public ModelReply generate(JsonNode body) {
                            return new ModelReply(
                                (ObjectNode) JSON.readTree(output),
                                new TokenUsage(21, null, 7),
                                null
                            );
                        }
                    };
                },
                6000
            );

            var offlineResult = offline.analyze(input);
            assertEquals(result.output(), offlineResult.output());
            assertNull(offlineResult.usage().cachedTokens());
            assertEquals(2, provider.requests().size());
        }
    }

    /**
     * 최상위 완료와 메시지 미완료가 모순되면 JSON이 정상이어도 채택하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsIncompleteMessage() throws Exception {
        try (var provider = new ProviderStub()) {
            ObjectNode response = (ObjectNode) JSON
                .readTree(completed("{\"kind\":\"fixture\"}", USAGE));
            ((ObjectNode) response.get(OpenAiFields.OUTPUT).get(0))
                .put(OpenAiFields.STATUS, OpenAiValues.INCOMPLETE);
            provider.reply(200, JSON.writeValueAsString(response));

            var result = gateway(provider).generate(input());
            assertEquals(ProviderCodes.INCOMPLETE_RESPONSE, result.failure());
            assertNull(result.output());
            assertEquals(new TokenUsage(21, 5L, 7), result.usage());
            assertEquals(1, provider.requests().size());
        }
    }

    /**
     * 계수와 생성의 입력·지침·모델·형식을 비교하고 생성 요청의 보관·도구 실행 제한을 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void sharesCountingAndGenerationPayloads() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            provider.reply(200, "{\"object\":\"response.input_tokens\",\"input_tokens\":21}");
            assertEquals(21L, gateway.countInput(input()));
            provider.reply(200, completed("{\"kind\":\"fixture\"}", USAGE));
            gateway.generate(input());

            assertEquals(2, provider.requests().size());
            var count = provider.requests().get(0);
            var generation = provider.requests().get(1);
            assertEquals(OpenAiValues.COUNT_PATH, count.path());
            assertEquals(OpenAiValues.RESPONSES_PATH, generation.path());
            assertEquals(
                OpenAiValues.BEARER_PREFIX + OpenAiValues.CREDENTIAL,
                count.authorization()
            );
            assertEquals(
                OpenAiValues.BEARER_PREFIX + OpenAiValues.CREDENTIAL,
                generation.authorization()
            );
            String[] requestFields = {
                OpenAiFields.MODEL,
                OpenAiFields.INSTRUCTIONS,
                OpenAiFields.INPUT,
                OpenAiFields.REASONING,
                OpenAiFields.TOOLS,
                OpenAiFields.TEXT
            };
            for (String field : requestFields) {
                assertEquals(count.body().get(field), generation.body().get(field), field);
            }
            JsonNode request = generation.body();
            assertEquals("approved-test-model", request.path(OpenAiFields.MODEL).asString());
            assertEquals(
                OpenAiValues.EFFORT_LOW,
                request.path(OpenAiFields.REASONING)
                    .path(OpenAiFields.EFFORT)
                    .asString()
            );
            assertEquals(input(), JSON.readTree(request.path(OpenAiFields.INPUT).asString()));
            assertTrue(request.path(OpenAiFields.TOOLS).isArray());
            assertEquals(0, request.path(OpenAiFields.TOOLS).size());
            JsonNode format = request.path(OpenAiFields.TEXT).path(OpenAiFields.FORMAT);
            assertEquals(OpenAiValues.JSON_SCHEMA, format.path(OpenAiFields.TYPE_KEY).asString());
            assertTrue(format.path(OpenAiFields.STRICT).asBoolean());
            assertEquals(schema(), format.path(OpenAiFields.SCHEMA));
            for (String field : new String[] {
                OpenAiFields.STORE,
                OpenAiFields.BACKGROUND,
                OpenAiFields.STREAM
            }) {
                assertTrue(request.path(field).isBoolean(), field);
                assertFalse(request.path(field).asBoolean(), field);
            }
            assertEquals(40, request.path(OpenAiFields.MAX_OUTPUT_TOKENS).asInt());
        }
    }

    /**
     * 정상 객체와 입력·캐시·출력 토큰을 금융 금액으로 변환하지 않고 반환한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void returnsStructuredOutputAndUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.reply(200, completed("{\"kind\":\"fixture\"}", USAGE));

            var reply = gateway(provider).generate(input());
            assertNull(reply.failure());
            assertEquals(
                "fixture",
                reply.output()
                    .path(AnalysisFields.KIND)
                    .asString()
            );
            assertEquals(new TokenUsage(21, 5L, 7), reply.usage());
            assertEquals(1, provider.requests().size());
        }
    }

    /**
     * 사용량이 없거나 null이면 미확인 상태를 유지하며 비용0으로 대체하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void preservesUnknownUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            for (String usage : new String[] { null, "null" }) {
                provider.reply(200, completed("{\"kind\":\"fixture\"}", usage));

                var reply = gateway.generate(input());
                assertNull(reply.failure());
                assertNotNull(reply.output());
                assertNull(reply.usage());
            }
            assertEquals(2, provider.requests().size());
        }
    }

    /**
     * 모델 거절에는 해석 본문이 없고 관측한 사용량은 보존되며 추가 전송하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void preservesRefusalUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.reply(
                200,
                "{\"status\":\"completed\",\"usage\":" + USAGE
                    + ",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":["
                    + "{\"type\":\"refusal\",\"refusal\":\"private refusal fixture\"}]}]}"
            );

            var reply = gateway(provider).generate(input());
            assertEquals(ProviderCodes.MODEL_REFUSAL, reply.failure());
            assertNull(reply.output());
            assertEquals(new TokenUsage(21, 5L, 7), reply.usage());
            assertEquals(1, provider.requests().size());
        }
    }

    /**
     * 미완료 응답의 출력은 채택하지 않고 관측 사용량과 실패만 돌려준다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void preservesIncompleteUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            ObjectNode response = (ObjectNode) JSON
                .readTree(completed("{\"kind\":\"partial\"}", USAGE));
            response.put(OpenAiFields.STATUS, OpenAiValues.INCOMPLETE);
            provider.reply(200, JSON.writeValueAsString(response));

            var reply = gateway(provider).generate(input());
            assertEquals(ProviderCodes.INCOMPLETE_RESPONSE, reply.failure());
            assertNull(reply.output());
            assertEquals(new TokenUsage(21, 5L, 7), reply.usage());
            assertEquals(1, provider.requests().size());
        }
    }

    /**
     * 깨진 JSON·비객체·뒤에 붙은 추가 JSON을 채택하지 않으며 사용량을 잃지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsMalformedModelJson() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            String[] outputs = {
                "{",
                "[]",
                "null",
                "{\"kind\":\"fixture\"} {\"kind\":\"extra\"}",
                "{\"kind\":\"fixture\"} trailing"
            };
            for (String output : outputs) {
                provider.reply(200, completed(output, USAGE));

                var reply = gateway.generate(input());
                assertEquals(ProviderCodes.INVALID_MODEL_OUTPUT, reply.failure());
                assertNull(reply.output());
                assertEquals(new TokenUsage(21, 5L, 7), reply.usage());
            }
            assertEquals(outputs.length, provider.requests().size());
        }
    }

    /**
     * 완료 상태여도 응답 배열·역할·중복 본문 오류를 거절하고 관측 사용량을 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-01 - 구조 오류의 사용량 보존 검증
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsMalformedResponseEnvelope() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            String[] responses = {
                "{\"status\":\"completed\",\"output\":{}}",
                "{\"status\":\"completed\",\"output\":[]}",
                "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"user\",\"content\":[]}]}",
                "{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":["
                    + "{\"type\":\"output_text\",\"text\":\"{}\"},{\"type\":\"output_text\",\"text\":\"{}\"}]}]}"
            };
            for (String response : responses) {
                ObjectNode malformed = (ObjectNode) JSON.readTree(response);
                malformed.set(OpenAiFields.USAGE_FIELD, JSON.readTree(USAGE));
                provider.reply(200, JSON.writeValueAsString(malformed));

                var failure = gateway.generate(input());
                assertEquals(ProviderCodes.INVALID_PROVIDER_RESPONSE, failure.failure());
                assertNull(failure.output());
                assertEquals(new TokenUsage(21, 5L, 7), failure.usage());
            }
            assertEquals(responses.length, provider.requests().size());
        }
    }

    /**
     * 명시한 입력 한도와 같은 토큰 수는 허용하고 한 토큰 초과는 생성 호출 없이 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void enforcesInputTokenLimit() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            provider.reply(200, "{\"object\":\"response.input_tokens\",\"input_tokens\":100}");
            assertEquals(100L, gateway.countInput(input()));
            provider.reply(200, "{\"object\":\"response.input_tokens\",\"input_tokens\":101}");

            var failure = assertThrows(ModelFailure.class, () -> gateway.countInput(input()));
            assertEquals(ProviderCodes.INPUT_TOKEN_LIMIT, failure.getMessage());
            assertEquals(Stage.INPUT_COUNT, failure.stage());
            assertTrue(failure.mayHaveBeenSent());
            assertEquals(2, provider.requests().size());
            assertTrue(
                provider.requests()
                    .stream()
                    .allMatch(
                        request -> request.path()
                            .endsWith(OpenAiValues.COUNT_SUFFIX)
                    )
            );
        }
    }

    /**
     * 키 공급자 예외는 계수/생성 모두 원문 없이 전송 전 실패하며 구성만으로 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void sanitizesCredentialFailures() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = new OpenAiGateway(
                provider.http(),
                () -> {
                    throw new IllegalStateException("private-secret-do-not-log");
                },
                "approved-test-model",
                "Return kind only.",
                OpenAiValues.EFFORT_LOW,
                schema(),
                100,
                40,
                provider.endpoint()
            );
            assertEquals(0, provider.requests().size());
            var count = assertThrows(ModelFailure.class, () -> gateway.countInput(input()));
            var generation = assertThrows(ModelFailure.class, () -> gateway.generate(input()));
            assertEquals(Stage.INPUT_COUNT, count.stage());
            assertEquals(Stage.GENERATION, generation.stage());
            for (var failure : java.util.List.of(count, generation)) {
                assertEquals(ProviderCodes.CREDENTIAL_UNAVAILABLE, failure.getMessage());
                assertNull(failure.getCause());
                assertFalse(failure.mayHaveBeenSent());
                assertFalse(failure.toString().contains("private-secret"));
            }
            assertEquals(0, provider.requests().size());
        }
    }

    /**
     * 같은 HTTP 실패도 발생 단계와 전송 가능성을 구분하며 자동 재시도하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void separatesTransmissionStages() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.reply(503, "{\"message\":\"private-provider-detail\"}");
            var gateway = gateway(provider);
            var count = assertThrows(ModelFailure.class, () -> gateway.countInput(input()));
            var generation = assertThrows(ModelFailure.class, () -> gateway.generate(input()));
            assertEquals(Stage.INPUT_COUNT, count.stage());
            assertEquals(Stage.GENERATION, generation.stage());
            for (var failure : java.util.List.of(count, generation)) {
                assertEquals(ProviderCodes.PROVIDER_HTTP_503, failure.getMessage());
                assertTrue(failure.mayHaveBeenSent());
                assertNull(failure.getCause());
            }
            assertEquals(2, provider.requests().size());
        }
    }

    /**
     * 음수·실수·문자열·정수 범위 초과와 다른 계수 응답 종류를 정상 토큰으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsInvalidTokenCounts() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            String[] counts = {
                "-1",
                "1.5",
                "\"3\"",
                "9223372036854775808",
                "null"
            };
            for (String count : counts) {
                provider.reply(
                    200,
                    "{\"object\":\"response.input_tokens\",\"input_tokens\":" + count + "}"
                );

                var failure = assertThrows(ModelFailure.class, () -> gateway.countInput(input()));
                assertEquals(ProviderCodes.INVALID_PROVIDER_RESPONSE, failure.getMessage());
                assertTrue(failure.mayHaveBeenSent());
            }
            provider.reply(200, "{\"object\":\"unexpected\",\"input_tokens\":3}");
            assertThrows(ModelFailure.class, () -> gateway.countInput(input()));
            assertEquals(counts.length + 1, provider.requests().size());
        }
    }

    /**
     * 불완전하거나 모순된 사용량을 정산 가능한 수치로 채택하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsInvalidUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            String[] usages = {
                "{}",
                "{\"input_tokens\":-1,\"output_tokens\":1}",
                "{\"input_tokens\":1,\"output_tokens\":1.5}",
                "{\"input_tokens\":\"1\",\"output_tokens\":1}",
                "{\"input_tokens\":1,\"output_tokens\":9223372036854775808}",
                "{\"input_tokens\":1,\"output_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":2}}",
                "{\"input_tokens\":1,\"output_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":-1}}"
            };
            for (String usage : usages) {
                provider.reply(200, completed("{\"kind\":\"fixture\"}", usage));

                var failure = assertThrows(ModelFailure.class, () -> gateway.generate(input()));
                assertEquals(ProviderCodes.INVALID_PROVIDER_RESPONSE, failure.getMessage());
                assertTrue(failure.mayHaveBeenSent());
                assertNull(failure.getCause());
            }
            assertEquals(usages.length, provider.requests().size());
        }
    }

    /**
     * 호출자가 전달한 스키마를 나중에 바꾸어도 생성 요청의 승인 설정은 유지한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void protectsConfiguredSchema() throws Exception {
        try (var provider = new ProviderStub()) {
            ObjectNode configured = schema();
            var gateway = new OpenAiGateway(
                provider.http(),
                () -> OpenAiValues.CREDENTIAL,
                "approved-test-model",
                "Return the supplied fixture kind only.",
                OpenAiValues.EFFORT_LOW,
                configured,
                100,
                40,
                provider.endpoint()
            );
            configured.put(Schema.ADDITIONAL_PROPERTIES, true);
            provider.reply(200, completed("{\"kind\":\"fixture\"}", USAGE));
            gateway.generate(input());
            assertFalse(
                provider.requests()
                    .get(0)
                    .body()
                    .path(OpenAiFields.TEXT)
                    .path(OpenAiFields.FORMAT)
                    .path(OpenAiFields.SCHEMA)
                    .path(Schema.ADDITIONAL_PROPERTIES)
                    .asBoolean()
            );
        }
    }

    /**
     * 결과 객체의 기본 문자열 표현에 민감한 해석 원문이나 자격값이 나타나지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void redactsReplyText() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.reply(200, completed("{\"kind\":\"private-analysis-sentinel\"}", USAGE));

            var reply = gateway(provider).generate(input());
            assertNotNull(reply.output());
            assertEquals(ProviderValues.REDACTED_REPLY, reply.toString());
            assertFalse(reply.toString().contains("private-analysis-sentinel"));
            assertFalse(reply.toString().contains(OpenAiValues.CREDENTIAL));
        }
    }

    /**
     * 실제 공급자 주소 대신 로컬 모의 서버와 명시적인 테스트 상한을 사용한다.
     * @created 2026-11-01
     * @usedBy OpenAiGatewayTest 테스트 메서드
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private OpenAiGateway gateway(ProviderStub provider) {
        return new OpenAiGateway(
            provider.http(),
            () -> OpenAiValues.CREDENTIAL,
            "approved-test-model",
            "Return the supplied fixture kind only.",
            OpenAiValues.EFFORT_LOW,
            schema(),
            100,
            40,
            provider.endpoint()
        );
    }

    /**
     * 금융 원천이나 업무 분류를 포함하지 않는 모의 입력을 만든다.
     * @created 2026-11-01
     * @usedBy OpenAiGatewayTest 테스트 메서드
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    private ObjectNode input() {
        return JSON.createObjectNode().put(AnalysisFields.KIND, "fixture");
    }

    /**
     * 공급자 전달 형식만 검사하는 모의 스키마이며 실제 분석 계약으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy gateway, sharesCountingAndGenerationPayloads, protectsConfiguredSchema
     */
    private ObjectNode schema() {
        return (ObjectNode) JSON.readTree(
            "{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"}},"
                + "\"required\":[\"kind\"],\"additionalProperties\":false}"
        );
    }

    /**
     * 출력 문자열과 선택 사용량을 정상 공급자 봉투에 넣어 파싱 경계를 독립 검사한다.
     * @created 2026-11-01
     * @usedBy OpenAiGatewayTest 테스트 메서드
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조; 제어문 본문 구분
     */
    private String completed(String output, String usage) {
        ObjectNode response = JSON.createObjectNode()
            .put(OpenAiFields.STATUS, OpenAiValues.COMPLETED);
        response.putArray(OpenAiFields.OUTPUT)
            .addObject()
            .put(OpenAiFields.TYPE_KEY, OpenAiValues.MESSAGE)
            .put(OpenAiFields.ROLE, OpenAiValues.ASSISTANT)
            .putArray(OpenAiFields.CONTENT)
            .addObject()
            .put(OpenAiFields.TYPE_KEY, OpenAiValues.OUTPUT_TEXT)
            .put(OpenAiFields.TEXT, output);
        if (usage != null) {
            response.set(OpenAiFields.USAGE_FIELD, JSON.readTree(usage));
        }
        return JSON.writeValueAsString(response);
    }
}
