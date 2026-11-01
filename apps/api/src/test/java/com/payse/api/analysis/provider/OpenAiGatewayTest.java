package com.payse.api.analysis.provider;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.api.analysis.provider.ProviderHttp.ProviderFailure;
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
    private static final String CREDENTIAL = "fixture-openai-secret";

    /**
     * 계수와 생성의 입력·지침·모델·형식을 비교하고 생성 요청의 보관·도구 실행 제한을 확인한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
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
            assertEquals("/v1/responses/input_tokens", count.path());
            assertEquals("/v1/responses", generation.path());
            assertEquals("Bearer " + CREDENTIAL, count.authorization());
            assertEquals("Bearer " + CREDENTIAL, generation.authorization());
            for (String field : new String[] {"model", "instructions", "input", "reasoning", "tools", "text"}) {
                assertEquals(count.body().get(field), generation.body().get(field), field);
            }
            JsonNode request = generation.body();
            assertEquals("approved-test-model", request.path("model").asString());
            assertEquals("low", request.path("reasoning").path("effort").asString());
            assertEquals(input(), JSON.readTree(request.path("input").asString()));
            assertTrue(request.path("tools").isArray());
            assertEquals(0, request.path("tools").size());
            assertEquals("json_schema", request.path("text").path("format").path("type").asString());
            assertTrue(request.path("text").path("format").path("strict").asBoolean());
            assertEquals(schema(), request.path("text").path("format").path("schema"));
            for (String field : new String[] {"store", "background", "stream"}) {
                assertTrue(request.path(field).isBoolean(), field);
                assertFalse(request.path(field).asBoolean(), field);
            }
            assertEquals(40, request.path("max_output_tokens").asInt());
        }
    }

    /**
     * 정상 객체와 입력·캐시·출력 토큰을 금융 금액으로 변환하지 않고 반환한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void returnsStructuredOutputAndUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.reply(200, completed("{\"kind\":\"fixture\"}", USAGE));
            var reply = gateway(provider).generate(input());
            assertNull(reply.failure());
            assertEquals("fixture", reply.output().path("kind").asString());
            assertEquals(new OpenAiGateway.Usage(21, 5, 7), reply.usage());
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
            for (String usage : new String[] {null, "null"}) {
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
     */
    @Test
    void preservesRefusalUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.reply(200, "{\"status\":\"completed\",\"usage\":" + USAGE
                + ",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":["
                + "{\"type\":\"refusal\",\"refusal\":\"private refusal fixture\"}]}]}");
            var reply = gateway(provider).generate(input());
            assertEquals("MODEL_REFUSAL", reply.failure());
            assertNull(reply.output());
            assertEquals(new OpenAiGateway.Usage(21, 5, 7), reply.usage());
            assertEquals(1, provider.requests().size());
        }
    }

    /**
     * 미완료 응답의 출력은 채택하지 않고 관측 사용량과 실패만 돌려준다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void preservesIncompleteUsage() throws Exception {
        try (var provider = new ProviderStub()) {
            ObjectNode response = (ObjectNode) JSON.readTree(completed("{\"kind\":\"partial\"}", USAGE));
            response.put("status", "incomplete");
            provider.reply(200, JSON.writeValueAsString(response));
            var reply = gateway(provider).generate(input());
            assertEquals("INCOMPLETE_RESPONSE", reply.failure());
            assertNull(reply.output());
            assertEquals(new OpenAiGateway.Usage(21, 5, 7), reply.usage());
            assertEquals(1, provider.requests().size());
        }
    }

    /**
     * 깨진 JSON·비객체·뒤에 붙은 추가 JSON을 채택하지 않으며 사용량을 잃지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsMalformedModelJson() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            String[] outputs = {"{", "[]", "null", "{\"kind\":\"fixture\"} {\"kind\":\"extra\"}",
                "{\"kind\":\"fixture\"} trailing"};
            for (String output : outputs) {
                provider.reply(200, completed(output, USAGE));
                var reply = gateway.generate(input());
                assertEquals("INVALID_MODEL_OUTPUT", reply.failure());
                assertNull(reply.output());
                assertEquals(new OpenAiGateway.Usage(21, 5, 7), reply.usage());
            }
            assertEquals(outputs.length, provider.requests().size());
        }
    }

    /**
     * 완료 상태여도 응답 배열·역할·중복 본문이 잘못되면 공급자 구조 오류로 구분한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
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
                provider.reply(200, response);
                var failure = assertThrows(ProviderFailure.class, () -> gateway.generate(input()));
                assertEquals("INVALID_PROVIDER_RESPONSE", failure.getMessage());
                assertTrue(failure.mayHaveBeenSent());
            }
            assertEquals(responses.length, provider.requests().size());
        }
    }

    /**
     * 명시한 입력 한도와 같은 토큰 수는 허용하고 한 토큰 초과는 생성 호출 없이 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void enforcesInputTokenLimit() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            provider.reply(200, "{\"object\":\"response.input_tokens\",\"input_tokens\":100}");
            assertEquals(100L, gateway.countInput(input()));
            provider.reply(200, "{\"object\":\"response.input_tokens\",\"input_tokens\":101}");
            var failure = assertThrows(ProviderFailure.class, () -> gateway.countInput(input()));
            assertEquals("INPUT_TOKEN_LIMIT", failure.getMessage());
            assertEquals(2, provider.requests().size());
            assertTrue(provider.requests().stream().allMatch(request -> request.path().endsWith("/input_tokens")));
        }
    }

    /**
     * 음수·실수·문자열·정수 범위 초과와 다른 계수 응답 종류를 정상 토큰으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void rejectsInvalidTokenCounts() throws Exception {
        try (var provider = new ProviderStub()) {
            var gateway = gateway(provider);
            String[] counts = {"-1", "1.5", "\"3\"", "9223372036854775808", "null"};
            for (String count : counts) {
                provider.reply(200, "{\"object\":\"response.input_tokens\",\"input_tokens\":" + count + "}");
                var failure = assertThrows(ProviderFailure.class, () -> gateway.countInput(input()));
                assertEquals("INVALID_PROVIDER_RESPONSE", failure.getMessage());
                assertTrue(failure.mayHaveBeenSent());
            }
            provider.reply(200, "{\"object\":\"unexpected\",\"input_tokens\":3}");
            assertThrows(ProviderFailure.class, () -> gateway.countInput(input()));
            assertEquals(counts.length + 1, provider.requests().size());
        }
    }

    /**
     * 불완전하거나 모순된 사용량을 정산 가능한 수치로 채택하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
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
                var failure = assertThrows(ProviderFailure.class, () -> gateway.generate(input()));
                assertEquals("INVALID_PROVIDER_RESPONSE", failure.getMessage());
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
     */
    @Test
    void protectsConfiguredSchema() throws Exception {
        try (var provider = new ProviderStub()) {
            ObjectNode configured = schema();
            var gateway = new OpenAiGateway(provider.http(), () -> CREDENTIAL, "approved-test-model",
                "Return the supplied fixture kind only.", "low", configured, 100, 40, provider.endpoint());
            configured.put("additionalProperties", true);
            provider.reply(200, completed("{\"kind\":\"fixture\"}", USAGE));
            gateway.generate(input());
            assertFalse(provider.requests().get(0).body().path("text").path("format")
                .path("schema").path("additionalProperties").asBoolean());
        }
    }

    /**
     * 결과 객체의 기본 문자열 표현에 민감한 해석 원문이나 자격값이 나타나지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit 5
     */
    @Test
    void redactsReplyText() throws Exception {
        try (var provider = new ProviderStub()) {
            provider.reply(200, completed("{\"kind\":\"private-analysis-sentinel\"}", USAGE));
            var reply = gateway(provider).generate(input());
            assertNotNull(reply.output());
            assertEquals("AnalysisReply[REDACTED]", reply.toString());
            assertFalse(reply.toString().contains("private-analysis-sentinel"));
            assertFalse(reply.toString().contains(CREDENTIAL));
        }
    }

    /**
     * 실제 공급자 주소 대신 로컬 모의 서버와 명시적인 테스트 상한을 사용한다.
     * @created 2026-11-01
     * @usedBy OpenAiGatewayTest 테스트 메서드
     */
    private OpenAiGateway gateway(ProviderStub provider) {
        return new OpenAiGateway(provider.http(), () -> CREDENTIAL, "approved-test-model",
            "Return the supplied fixture kind only.", "low", schema(), 100, 40, provider.endpoint());
    }

    /**
     * 금융 원천이나 업무 분류를 포함하지 않는 모의 입력을 만든다.
     * @created 2026-11-01
     * @usedBy OpenAiGatewayTest 테스트 메서드
     */
    private ObjectNode input() {
        return JSON.createObjectNode().put("kind", "fixture");
    }

    /**
     * 공급자 전달 형식만 검사하는 모의 스키마이며 실제 분석 계약으로 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy gateway, sharesCountingAndGenerationPayloads, protectsConfiguredSchema
     */
    private ObjectNode schema() {
        return (ObjectNode) JSON.readTree("{\"type\":\"object\",\"properties\":{\"kind\":{\"type\":\"string\"}},"
            + "\"required\":[\"kind\"],\"additionalProperties\":false}");
    }

    /**
     * 출력 문자열과 선택 사용량을 정상 공급자 봉투에 넣어 파싱 경계를 독립 검사한다.
     * @created 2026-11-01
     * @usedBy OpenAiGatewayTest 테스트 메서드
     */
    private String completed(String output, String usage) {
        ObjectNode response = JSON.createObjectNode().put("status", "completed");
        response.putArray("output").addObject().put("type", "message").put("role", "assistant")
            .putArray("content").addObject().put("type", "output_text").put("text", output);
        if (usage != null) response.set("usage", JSON.readTree(usage));
        return JSON.writeValueAsString(response);
    }
}
