package com.payse.api.analysis.provider;

import com.payse.api.analysis.provider.ProviderHttp.ProviderFailure;
import java.net.URI;
import java.util.Objects;
import java.util.function.Supplier;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 명시 설정된 모델의 구조화 응답을 한 번 요청한다. 금액 계산·자동 재시도·금융 저장은 하지 않는다.
 * @created 2026-10-29
 * @usedBy 미연결: 예정 사용처 분석 실행 서비스, OpenAiGatewayTest
 */
public final class OpenAiGateway {
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
     * @usedBy 미연결: 예정 사용처 분석 실행 서비스, OpenAiGatewayTest
     */
    public long countInput(JsonNode input) {
        JsonNode result = http.post(endpoint.resolve("responses/input_tokens"), credentials.get(), payload(input));
        if (!"response.input_tokens".equals(result.path("object").asString(""))) throw invalid();
        long count = natural(result.path("input_tokens"));
        if (count > inputLimit) throw new ProviderFailure("INPUT_TOKEN_LIMIT", false);
        return count;
    }

    /**
     * 한 전송의 원시 구조화 응답과 사용량을 반환한다. 업무 스키마·ID·소유권 검증은 후속 계층 책임이다.
     * @created 2026-10-29
     * @usedBy 미연결: 예정 사용처 분석 실행 서비스, OpenAiGatewayTest
     */
    public Reply generate(JsonNode input) {
        ObjectNode request = payload(input);
        request.put("store", false).put("background", false).put("stream", false);
        request.put("max_output_tokens", outputLimit);
        JsonNode response = http.post(endpoint.resolve("responses"), credentials.get(), request);
        Usage usage = usage(response.path("usage"));
        String status = response.path("status").asString("");
        if (!"completed".equals(status)) return new Reply(null, usage, "INCOMPLETE_RESPONSE");
        String text = null;
        if (!response.path("output").isArray()) throw invalid();
        for (JsonNode output : response.get("output")) {
            if (!"message".equals(output.path("type").asString(""))) continue;
            if (!"assistant".equals(output.path("role").asString("")) || !output.path("content").isArray()) throw invalid();
            for (JsonNode part : output.get("content")) {
                String type = part.path("type").asString("");
                if ("refusal".equals(type)) return new Reply(null, usage, "MODEL_REFUSAL");
                if (!"output_text".equals(type) || !part.path("text").isString() || text != null) throw invalid();
                text = part.get("text").asString();
            }
        }
        if (text == null) throw invalid();
        try {
            JsonNode result = json.readTree(text);
            if (result == null || !result.isObject()) return new Reply(null, usage, "INVALID_MODEL_OUTPUT");
            return new Reply((ObjectNode) result, usage, null);
        } catch (RuntimeException failure) {
            return new Reply(null, usage, "INVALID_MODEL_OUTPUT");
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
    private Usage usage(JsonNode raw) {
        if (raw.isMissingNode() || raw.isNull()) return null;
        long input = natural(raw.path("input_tokens"));
        long output = natural(raw.path("output_tokens"));
        long cached = raw.path("input_tokens_details").path("cached_tokens").isMissingNode()
            ? 0 : natural(raw.get("input_tokens_details").get("cached_tokens"));
        if (cached > input) throw invalid();
        return new Usage(input, cached, output);
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

    /**
     * 금액으로 임의 환산하지 않은 공급자 토큰 사용량이다.
     * @created 2026-10-29
     * @usedBy Reply, 미연결: 예정 사용처 분석 비용 정산 서비스
     */
    public record Usage(long inputTokens, long cachedTokens, long outputTokens) {}

    /**
     * 처리 메모리 전용 결과다. 전체 응답을 영속화하지 않고 개별 검증 기억으로 분리해야 한다.
     * @created 2026-10-29
     * @usedBy generate, 미연결: 예정 사용처 분석 결과 채택 서비스
     */
    public record Reply(ObjectNode output, Usage usage, String failure) {
        /**
         * 원문 해석을 자동 로그의 문자열 표현에서 제외한다.
         * @created 2026-10-29
         * @usedBy Java 문자열 변환
         */
        @Override
        public String toString() { return "AnalysisReply[REDACTED]"; }
    }
}
