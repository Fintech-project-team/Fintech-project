package com.payse.ai.provider.openai;

import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelFailure.Stage;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;

import com.payse.ai.transport.ProviderHttp;
import com.payse.ai.transport.ProviderHttp.ProviderFailure;
import java.net.URI;
import java.util.Objects;
import java.util.function.Supplier;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 명시 설정된 모델의 구조화 응답을 한 번 요청한다. 금액 계산·자동 재시도·금융 저장은 하지 않는다.
 * @created 2026-10-29
 * @usedBy AnalysisService.analyze, OpenAiGatewayTest
 */
public final class OpenAiGateway implements ModelGateway {
    private final ProviderHttp http;
    private final Supplier<String> credentials;
    private final URI endpoint;
    private final String model;
    private final String instructions;
    private final String effort;
    private final JsonNode schema;
    private final int inputLimit;
    private final int outputLimit;
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 공식 주소와 승인된 모델·프롬프트·응답 스키마·상한을 받는다. 누락을 기본값으로 보충하지 않는다.
     * @created 2026-10-29
     * @usedBy 미연결: 예정 사용처 분석 공급자 설정
     */
    public OpenAiGateway(ProviderHttp http, Supplier<String> credentials, String model, String instructions,
            String effort, JsonNode schema, int inputLimit, int outputLimit) {
        this(http, credentials, model, instructions, effort, schema, inputLimit, outputLimit,
            URI.create("https://api.openai.com/v1/"));
    }

    /**
     * 같은 패키지의 모의 HTTP 테스트만 다른 endpoint를 전달할 수 있다.
     * @created 2026-10-29
     * @usedBy OpenAiGatewayTest
     */
    OpenAiGateway(ProviderHttp http, Supplier<String> credentials, String model, String instructions,
            String effort, JsonNode schema, int inputLimit, int outputLimit, URI endpoint) {
        this.http = Objects.requireNonNull(http, "http");
        this.credentials = Objects.requireNonNull(credentials, "credentials");
        if (model == null || model.isBlank() || instructions == null || instructions.isBlank()
                || effort == null || !java.util.Set.of("none", "low", "medium", "high", "xhigh", "max").contains(effort)
                || schema == null || !schema.isObject() || inputLimit < 1 || outputLimit < 1) {
            throw new IllegalArgumentException("Approved analysis provider profile is required");
        }
        this.model = model;
        this.instructions = instructions;
        this.effort = effort;
        this.schema = schema.deepCopy();
        this.inputLimit = inputLimit;
        this.outputLimit = outputLimit;
        this.endpoint = Objects.requireNonNull(endpoint, "endpoint");
    }

    /**
     * 생성 요청과 같은 지침·스키마·본문의 실제 입력 토큰을 공급자에 확인한다. 외부 전송이다.
     * @created 2026-10-29
     * @usedBy AnalysisService.analyze, OpenAiGatewayTest
     * @modified 2026-11-01 - 계수 실패를 생성과 분리하고 이미 발생한 계수 전송을 보존
     */
    public long countInput(JsonNode input) {
        try {
            JsonNode result = http.post(endpoint.resolve("responses/input_tokens"), credential(Stage.INPUT_COUNT), payload(input));
            if (!"response.input_tokens".equals(result.path("object").asString(""))) throw invalid();
            long count = natural(result.path("input_tokens"));
            if (count > inputLimit) throw new ModelFailure("INPUT_TOKEN_LIMIT", Stage.INPUT_COUNT, true);
            return count;
        } catch (ProviderFailure failure) {
            throw new ModelFailure(failure.getMessage(), Stage.INPUT_COUNT, failure.mayHaveBeenSent());
        }
    }

    /**
     * 한 전송의 원시 구조화 응답과 사용량을 반환한다. 업무 스키마·ID·소유권 검증은 후속 계층 책임이다.
     * @created 2026-10-29
     * @usedBy AnalysisService.analyze, OpenAiGatewayTest
     * @modified 2026-11-01 - 메시지 완료 상태 검증과 오류 시 관측 사용량 보존
     * @modified 2026-11-01 - HTTP 실패를 공급자 중립 생성 실패로 변환
     */
    public ModelReply generate(JsonNode input) {
        ObjectNode request = payload(input);
        request.put("store", false).put("background", false).put("stream", false);
        request.put("max_output_tokens", outputLimit);
        try {
            JsonNode response = http.post(endpoint.resolve("responses"), credential(Stage.GENERATION), request);
            return reply(response);
        } catch (ProviderFailure failure) {
            throw new ModelFailure(failure.getMessage(), Stage.GENERATION, failure.mayHaveBeenSent());
        }
    }

    /**
     * OpenAI 완료·거절·본문·사용량을 공급자 공통 결과로 변환한다.
     * @created 2026-11-01
     * @usedBy generate
     */
    private ModelReply reply(JsonNode response) {
        TokenUsage usage = usage(response.path("usage"));
        String status = response.path("status").asString("");
        if (!"completed".equals(status)) return new ModelReply(null, usage, "INCOMPLETE_RESPONSE");
        String text = null;
        if (!response.path("output").isArray()) return new ModelReply(null, usage, "INVALID_PROVIDER_RESPONSE");
        for (JsonNode output : response.get("output")) {
            if (!"message".equals(output.path("type").asString(""))) continue;
            if (output.has("status") && !"completed".equals(output.get("status").asString(""))) {
                return new ModelReply(null, usage, "INCOMPLETE_RESPONSE");
            }
            if (!"assistant".equals(output.path("role").asString("")) || !output.path("content").isArray()) {
                return new ModelReply(null, usage, "INVALID_PROVIDER_RESPONSE");
            }
            for (JsonNode part : output.get("content")) {
                String type = part.path("type").asString("");
                if ("refusal".equals(type)) return new ModelReply(null, usage, "MODEL_REFUSAL");
                if (!"output_text".equals(type) || !part.path("text").isString() || text != null) {
                    return new ModelReply(null, usage, "INVALID_PROVIDER_RESPONSE");
                }
                text = part.get("text").asString();
            }
        }
        if (text == null) return new ModelReply(null, usage, "INVALID_PROVIDER_RESPONSE");
        try {
            JsonNode result = json.readTree(text);
            if (result == null || !result.isObject()) return new ModelReply(null, usage, "INVALID_MODEL_OUTPUT");
            return new ModelReply((ObjectNode) result, usage, null);
        } catch (RuntimeException failure) {
            return new ModelReply(null, usage, "INVALID_MODEL_OUTPUT");
        }
    }

    /**
     * 자격 공급자의 원문 예외를 제거한다. 실패한 단계의 전송은 시작하지 않는다.
     * @created 2026-11-01
     * @usedBy countInput, generate
     */
    private String credential(Stage stage) {
        try {
            return credentials.get();
        } catch (RuntimeException failure) {
            throw new ModelFailure("CREDENTIAL_UNAVAILABLE", stage, false);
        }
    }

    /**
     * 토큰 계수와 생성에 같은 입력·스키마를 사용하고 공급자 도구 실행은 허용하지 않는다.
     * @created 2026-10-29
     * @usedBy countInput, generate
     */
    private ObjectNode payload(JsonNode input) {
        Objects.requireNonNull(input, "input");
        ObjectNode request = json.createObjectNode().put("model", model).put("instructions", instructions);
        request.put("input", json.writeValueAsString(input));
        request.putObject("reasoning").put("effort", effort);
        request.putArray("tools");
        ObjectNode format = request.putObject("text").putObject("format");
        format.put("type", "json_schema").put("name", "payse_analysis").put("strict", true);
        format.set("schema", schema.deepCopy());
        return request;
    }

    /**
     * 공급자 사용량이 없으면 비용0 대신 미확인으로 남긴다. 출력에는 reasoning 토큰도 포함된다.
     * @created 2026-10-29
     * @usedBy generate
     */
    private TokenUsage usage(JsonNode raw) {
        if (raw.isMissingNode() || raw.isNull()) return null;
        long input = natural(raw.path("input_tokens"));
        long output = natural(raw.path("output_tokens"));
        long cached = raw.path("input_tokens_details").path("cached_tokens").isMissingNode()
            ? 0 : natural(raw.get("input_tokens_details").get("cached_tokens"));
        if (cached > input) throw invalid();
        return new TokenUsage(input, cached, output);
    }

    /**
     * 음수·실수·문자열 사용량을 정상 토큰 수로 바꾸지 않는다.
     * @created 2026-10-29
     * @usedBy countInput, usage
     */
    private long natural(JsonNode value) {
        if (value == null || !value.isIntegralNumber() || !value.canConvertToLong() || value.longValue() < 0) throw invalid();
        return value.longValue();
    }

    /**
     * 공급자 원문 없이 구조 오류를 전달한다. 전송 사실은 유지한다.
     * @created 2026-10-29
     * @usedBy generate, usage, natural
     */
    private ProviderFailure invalid() { return new ProviderFailure("INVALID_PROVIDER_RESPONSE", true); }

}
