package com.payse.ai.provider.openai;

import com.payse.ai.constants.AiCodeConstants.Provider;
import com.payse.ai.constants.AiConfigConstants;
import com.payse.ai.constants.AiFieldConstants;
import com.payse.ai.constants.AiMessageConstants;
import com.payse.ai.provider.ModelFailure.Stage;
import com.payse.ai.provider.ModelFailure;
import com.payse.ai.provider.ModelGateway;
import com.payse.ai.provider.dto.ModelReply;
import com.payse.ai.provider.dto.TokenUsage;
import com.payse.ai.transport.ProviderHttp.ProviderFailure;
import com.payse.ai.transport.ProviderHttp;
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
    private final String serviceTier;
    private final String verbosity;
    private final JsonNode schema;
    private final int inputLimit;
    private final int outputLimit;
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 공식 주소와 승인된 모델·프롬프트·응답 스키마·상한을 받는다. 누락을 기본값으로 보충하지 않는다.
     * @created 2026-10-29
     * @usedBy LlmSettings.factory
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public OpenAiGateway(
        ProviderHttp http,
        Supplier<String> credentials,
        String model,
        String instructions,
        String effort,
        JsonNode schema,
        int inputLimit,
        int outputLimit
    ) {
        this(
            http,
            credentials,
            model,
            instructions,
            effort,
            schema,
            inputLimit,
            outputLimit,
            URI.create(AiConfigConstants.OpenAi.API_ENDPOINT)
        );
    }

    /**
     * 같은 패키지의 모의 HTTP 테스트만 다른 endpoint를 전달할 수 있다.
     * @created 2026-10-29
     * @usedBy OpenAiGatewayTest
     * @modified 2026-11-04 - 기존 생성자는 표준 처리로 위임
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    OpenAiGateway(
        ProviderHttp http,
        Supplier<String> credentials,
        String model,
        String instructions,
        String effort,
        JsonNode schema,
        int inputLimit,
        int outputLimit,
        URI endpoint
    ) {
        this(http, credentials, model, instructions, effort, schema, inputLimit, outputLimit,
            endpoint, AiConfigConstants.OpenAi.SERVICE_DEFAULT);
    }

    /**
     * 공식 주소에서 요청 단위 처리 등급을 명시한다. 프로젝트 설정을 바꾸지 않는다.
     * @created 2026-11-04
     * @usedBy LlmSettings.factory
     */
    public OpenAiGateway(
        ProviderHttp http,
        Supplier<String> credentials,
        String model,
        String instructions,
        String effort,
        JsonNode schema,
        int inputLimit,
        int outputLimit,
        String serviceTier
    ) {
        this(http, credentials, model, instructions, effort, schema, inputLimit, outputLimit,
            URI.create(AiConfigConstants.OpenAi.API_ENDPOINT), serviceTier);
    }

    /**
     * 비교 실행에서만 응답 길이 정책을 명시하며 키·상한·처리 등급은 기존 검증을 따른다.
     * @created 2026-11-04
     * @usedBy LlmSettings.factory
     */
    public OpenAiGateway(
        ProviderHttp http,
        Supplier<String> credentials,
        String model,
        String instructions,
        String effort,
        JsonNode schema,
        int inputLimit,
        int outputLimit,
        String serviceTier,
        String verbosity
    ) {
        this(
            http,
            credentials,
            model,
            instructions,
            effort,
            schema,
            inputLimit,
            outputLimit,
            URI.create(AiConfigConstants.OpenAi.API_ENDPOINT),
            serviceTier,
            verbosity
        );
    }

    /**
     * 명시된 표준·Fast 설정만 수용하며 비용 정책과 연결은 호출 계층에서 검증한다.
     * @created 2026-11-04
     * @usedBy OpenAiGateway 생성자, OpenAiGatewayTest
     */
    OpenAiGateway(
        ProviderHttp http,
        Supplier<String> credentials,
        String model,
        String instructions,
        String effort,
        JsonNode schema,
        int inputLimit,
        int outputLimit,
        URI endpoint,
        String serviceTier
    ) {
        this(
            http,
            credentials,
            model,
            instructions,
            effort,
            schema,
            inputLimit,
            outputLimit,
            endpoint,
            serviceTier,
            null
        );
    }

    /**
     * 미지정 길이 정책은 생략하고 공식 세 단계만 허용한다. 업무 검증을 대신하지 않는다.
     * @created 2026-11-04
     * @usedBy OpenAiGateway 생성자, OpenAiGatewayTest
     */
    OpenAiGateway(
        ProviderHttp http,
        Supplier<String> credentials,
        String model,
        String instructions,
        String effort,
        JsonNode schema,
        int inputLimit,
        int outputLimit,
        URI endpoint,
        String serviceTier,
        String verbosity
    ) {
        if (serviceTier == null || !java.util.Set.of(AiConfigConstants.OpenAi.SERVICE_DEFAULT,
            AiConfigConstants.OpenAi.SERVICE_FAST).contains(serviceTier)) {
            throw new IllegalArgumentException(AiMessageConstants.OpenAi.INVALID_PROFILE);
        }
        this.serviceTier = serviceTier;
        if (verbosity != null && !java.util.Set.of(
            AiConfigConstants.OpenAi.VERBOSITY_LOW,
            AiConfigConstants.OpenAi.VERBOSITY_MEDIUM,
            AiConfigConstants.OpenAi.VERBOSITY_HIGH
        ).contains(verbosity)) {
            throw new IllegalArgumentException(AiMessageConstants.OpenAi.INVALID_PROFILE);
        }
        this.verbosity = verbosity;
        this.http = Objects.requireNonNull(http, AiMessageConstants.OpenAi.HTTP_PARAMETER);
        this.credentials = Objects
            .requireNonNull(credentials, AiMessageConstants.OpenAi.CREDENTIALS_PARAMETER);
        if (model == null
            || model.isBlank()
            || instructions == null
            || instructions.isBlank()
            || effort == null
            || !java.util.Set.of(
                AiConfigConstants.OpenAi.EFFORT_NONE,
                AiConfigConstants.OpenAi.EFFORT_LOW,
                AiConfigConstants.OpenAi.EFFORT_MEDIUM,
                AiConfigConstants.OpenAi.EFFORT_HIGH,
                AiConfigConstants.OpenAi.EFFORT_XHIGH,
                AiConfigConstants.OpenAi.EFFORT_MAX
            ).contains(effort)
            || schema == null
            || !schema.isObject()
            || inputLimit < 1
            || outputLimit < 1) {
            throw new IllegalArgumentException(AiMessageConstants.OpenAi.INVALID_PROFILE);
        }
        this.model = model;
        this.instructions = instructions;
        this.effort = effort;
        this.schema = schema.deepCopy();
        this.inputLimit = inputLimit;
        this.outputLimit = outputLimit;
        this.endpoint = Objects
            .requireNonNull(endpoint, AiMessageConstants.OpenAi.ENDPOINT_PARAMETER);
    }

    /**
     * 생성 요청과 같은 지침·스키마·본문의 실제 입력 토큰을 공급자에 확인한다. 외부 전송이다.
     * @created 2026-10-29
     * @usedBy AnalysisService.analyze, OpenAiGatewayTest
     * @modified 2026-11-01 - 계수 실패를 생성과 분리하고 이미 발생한 계수 전송을 보존
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조; 제어문 본문 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public long countInput(JsonNode input) {
        try {
            URI countEndpoint = endpoint.resolve(AiConfigConstants.OpenAi.COUNT_PATH);
            JsonNode result = http
                .post(countEndpoint, credential(Stage.INPUT_COUNT), payload(input));
            if (!AiConfigConstants.OpenAi.COUNT_OBJECT.equals(
                result.path(AiFieldConstants.OpenAi.OBJECT)
                    .asString("")
            )) {
                throw invalid();
            }

            long count = natural(result.path(AiFieldConstants.OpenAi.INPUT_TOKENS));
            if (count > inputLimit) {
                throw new ModelFailure(Provider.INPUT_TOKEN_LIMIT, Stage.INPUT_COUNT, true);
            }
            return count;
        } catch (ProviderFailure failure) {
            throw new ModelFailure(
                failure.getMessage(),
                Stage.INPUT_COUNT,
                failure.mayHaveBeenSent()
            );
        }
    }

    /**
     * 한 전송의 원시 구조화 응답과 사용량을 반환한다. 업무 스키마·ID·소유권 검증은 후속 계층 책임이다.
     * @created 2026-10-29
     * @usedBy AnalysisService.analyze, OpenAiGatewayTest
     * @modified 2026-11-04 - 생성에만 요청 단위 처리 등급을 명시
     * @modified 2026-11-01 - 메시지 완료 상태 검증과 오류 시 관측 사용량 보존
     * @modified 2026-11-01 - HTTP 실패를 공급자 중립 생성 실패로 변환
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public ModelReply generate(JsonNode input) {
        ObjectNode request = payload(input);
        request.put(AiFieldConstants.OpenAi.STORE, false)
            .put(AiFieldConstants.OpenAi.BACKGROUND, false)
            .put(AiFieldConstants.OpenAi.STREAM, false);
        request.put(AiFieldConstants.OpenAi.MAX_OUTPUT_TOKENS, outputLimit);
        request.put(AiFieldConstants.OpenAi.SERVICE_TIER, serviceTier);

        try {
            JsonNode response = http.post(
                endpoint.resolve(AiConfigConstants.OpenAi.RESPONSES_PATH),
                credential(Stage.GENERATION),
                request
            );
            return reply(response);
        } catch (ProviderFailure failure) {
            throw new ModelFailure(
                failure.getMessage(),
                Stage.GENERATION,
                failure.mayHaveBeenSent()
            );
        }
    }

    /**
     * OpenAI 완료·거절·본문·사용량을 공급자 공통 결과로 변환한다.
     * @created 2026-11-01
     * @usedBy generate
     * @modified 2026-11-04 - Fast 실제 처리 여부만 본문 없는 고정 코드로 관측
     * @modified 2026-11-04 - 잘못된 응답의 메시지·텍스트 개수만 진단
     * @modified 2026-11-04 - 명시된 중간 commentary를 최종 업무 응답과 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조; 제어문 본문 구분
     */
    private ModelReply reply(JsonNode response) {
        if (serviceTier.equals(AiConfigConstants.OpenAi.SERVICE_FAST)) {
            String actual = response.path(AiFieldConstants.OpenAi.SERVICE_TIER).asString("");
            boolean confirmed = java.util.Set.of(AiConfigConstants.OpenAi.SERVICE_FAST,
                AiConfigConstants.OpenAi.SERVICE_PRIORITY).contains(actual);
            System.getLogger(OpenAiGateway.class.getName()).log(System.Logger.Level.INFO,
                confirmed ? AiMessageConstants.OpenAi.FAST_CONFIRMED
                    : AiMessageConstants.OpenAi.FAST_NOT_CONFIRMED);
        }
        TokenUsage usage = usage(response.path(AiFieldConstants.OpenAi.USAGE_FIELD));
        String status = response.path(AiFieldConstants.OpenAi.STATUS).asString("");
        if (!AiConfigConstants.OpenAi.COMPLETED.equals(status)) {
            return incomplete(response, usage);
        }

        String text = null;
        if (!response.path(AiFieldConstants.OpenAi.OUTPUT).isArray()) {
            return rejectedEnvelope(response, usage);
        }

        for (JsonNode output : response.get(AiFieldConstants.OpenAi.OUTPUT)) {
            if (!AiConfigConstants.OpenAi.MESSAGE.equals(
                output.path(AiFieldConstants.OpenAi.TYPE_KEY)
                    .asString("")
            )) {
                continue;
            }
            if (output.has(AiFieldConstants.OpenAi.STATUS)
                && !AiConfigConstants.OpenAi.COMPLETED.equals(
                    output.get(AiFieldConstants.OpenAi.STATUS)
                        .asString("")
                )) {
                return incomplete(response, usage);
            }
            if (!AiConfigConstants.OpenAi.ASSISTANT.equals(
                output.path(AiFieldConstants.OpenAi.ROLE)
                    .asString("")
            )
                || !output.path(AiFieldConstants.OpenAi.CONTENT)
                    .isArray()) {
                return rejectedEnvelope(response, usage);
            }
            JsonNode phase = output.path(AiFieldConstants.OpenAi.PHASE);
            boolean commentary = AiConfigConstants.OpenAi.COMMENTARY.equals(phase.asString(""));
            if (!phase.isMissingNode() && !phase.isNull() && !commentary
                && !AiConfigConstants.OpenAi.FINAL_ANSWER.equals(phase.asString(""))) {
                return rejectedEnvelope(response, usage);
            }
            for (JsonNode part : output.get(AiFieldConstants.OpenAi.CONTENT)) {
                String type = part.path(AiFieldConstants.OpenAi.TYPE_KEY).asString("");
                if (AiConfigConstants.OpenAi.REFUSAL.equals(type)) {
                    return new ModelReply(null, usage, Provider.MODEL_REFUSAL);
                }
                if (!AiConfigConstants.OpenAi.OUTPUT_TEXT.equals(type)
                    || !part.path(AiFieldConstants.OpenAi.TEXT)
                        .isString()) {
                    return rejectedEnvelope(response, usage);
                }
                if (commentary) {
                    continue;
                }
                if (text != null) {
                    return rejectedEnvelope(response, usage);
                }
                text = part.get(AiFieldConstants.OpenAi.TEXT).asString();
            }
            if (commentary) {
                System.getLogger(OpenAiGateway.class.getName()).log(System.Logger.Level.INFO,
                    AiMessageConstants.OpenAi.COMMENTARY_IGNORED);
            }
        }
        if (text == null) {
            return rejectedEnvelope(response, usage);
        }

        try {
            JsonNode result = json.readTree(text);
            if (result == null || !result.isObject()) {
                return new ModelReply(null, usage, Provider.INVALID_MODEL_OUTPUT);
            }
            return new ModelReply((ObjectNode) result, usage, null);
        } catch (RuntimeException failure) {
            return new ModelReply(null, usage, Provider.INVALID_MODEL_OUTPUT);
        }
    }

    /**
     * 메시지·텍스트 개수만 남겨 잘못된 공급자 구조를 원문 노출 없이 진단한다.
     * @created 2026-11-04
     * @usedBy reply
     */
    private ModelReply rejectedEnvelope(JsonNode response, TokenUsage usage) {
        int messages = 0;
        int texts = 0;
        for (JsonNode output : response.path(AiFieldConstants.OpenAi.OUTPUT)) {
            if (!AiConfigConstants.OpenAi.MESSAGE.equals(
                output.path(AiFieldConstants.OpenAi.TYPE_KEY).asString(""))) {
                continue;
            }
            messages++;
            for (JsonNode part : output.path(AiFieldConstants.OpenAi.CONTENT)) {
                if (AiConfigConstants.OpenAi.OUTPUT_TEXT.equals(
                    part.path(AiFieldConstants.OpenAi.TYPE_KEY).asString(""))) {
                    texts++;
                }
            }
        }
        System.getLogger(OpenAiGateway.class.getName()).log(System.Logger.Level.WARNING,
            AiMessageConstants.OpenAi.ENVELOPE_REJECTED, messages, texts);
        return new ModelReply(null, usage, Provider.INVALID_PROVIDER_RESPONSE);
    }

    /**
     * 미완료 원인은 숫자·불리언으로만 관측하며 부분 본문과 공급자 문장을 남기지 않는다.
     * @created 2026-11-04
     * @usedBy reply
     */
    private ModelReply incomplete(JsonNode response, TokenUsage usage) {
        boolean limited = AiConfigConstants.OpenAi.INCOMPLETE_OUTPUT_LIMIT.equals(
            response.path(AiFieldConstants.OpenAi.INCOMPLETE_DETAILS)
                .path(AiFieldConstants.OpenAi.INCOMPLETE_REASON).asString("")
        );
        JsonNode reasoning = response.path(AiFieldConstants.OpenAi.USAGE_FIELD)
            .path(AiFieldConstants.OpenAi.OUTPUT_TOKENS_DETAILS)
            .path(AiFieldConstants.OpenAi.REASONING_TOKENS);
        long reasoningTokens = reasoning.isIntegralNumber() && reasoning.canConvertToLong()
            && reasoning.asLong() >= 0 ? reasoning.asLong() : -1;
        int messages = 0;
        int characters = 0;
        for (JsonNode output : response.path(AiFieldConstants.OpenAi.OUTPUT)) {
            if (!AiConfigConstants.OpenAi.MESSAGE.equals(
                output.path(AiFieldConstants.OpenAi.TYPE_KEY).asString(""))) {
                continue;
            }
            messages++;
            for (JsonNode part : output.path(AiFieldConstants.OpenAi.CONTENT)) {
                JsonNode text = part.path(AiFieldConstants.OpenAi.TEXT);
                if (text.isString()) {
                    characters += text.asString().length();
                }
            }
        }
        System.getLogger(OpenAiGateway.class.getName()).log(
            System.Logger.Level.WARNING,
            AiMessageConstants.OpenAi.INCOMPLETE_DIAGNOSTIC,
            limited,
            reasoningTokens,
            characters,
            messages
        );
        return new ModelReply(null, usage, Provider.INCOMPLETE_RESPONSE);
    }

    /**
     * 자격 공급자의 원문 예외를 제거한다. 실패한 단계의 전송은 시작하지 않는다.
     * @created 2026-11-01
     * @usedBy countInput, generate
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조
     */
    private String credential(Stage stage) {
        try {
            return credentials.get();
        } catch (RuntimeException failure) {
            throw new ModelFailure(Provider.CREDENTIAL_UNAVAILABLE, stage, false);
        }
    }

    /**
     * 토큰 계수와 생성에 같은 입력·스키마를 사용하고 공급자 도구 실행은 허용하지 않는다.
     * @created 2026-10-29
     * @usedBy countInput, generate
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private ObjectNode payload(JsonNode input) {
        Objects.requireNonNull(input, AiFieldConstants.OpenAi.INPUT);
        ObjectNode request = json.createObjectNode()
            .put(AiFieldConstants.OpenAi.MODEL, model)
            .put(AiFieldConstants.OpenAi.INSTRUCTIONS, instructions);
        request.put(AiFieldConstants.OpenAi.INPUT, json.writeValueAsString(input));
        request.putObject(AiFieldConstants.OpenAi.REASONING)
            .put(AiFieldConstants.OpenAi.EFFORT, effort);
        request.putArray(AiFieldConstants.OpenAi.TOOLS);

        ObjectNode text = request.putObject(AiFieldConstants.OpenAi.TEXT);
        if (verbosity != null) {
            text.put(AiFieldConstants.OpenAi.VERBOSITY, verbosity);
        }
        ObjectNode format = text.putObject(AiFieldConstants.OpenAi.FORMAT);
        format.put(AiFieldConstants.OpenAi.TYPE_KEY, AiConfigConstants.OpenAi.JSON_SCHEMA)
            .put(AiFieldConstants.OpenAi.NAME, AiConfigConstants.OpenAi.PAYSE_ANALYSIS)
            .put(AiFieldConstants.OpenAi.STRICT, true);
        format.set(AiFieldConstants.OpenAi.SCHEMA, schema.deepCopy());
        return request;
    }

    /**
     * 공급자 사용량이 없으면 비용0 대신 미확인으로 남긴다. 출력에는 reasoning 토큰도 포함된다.
     * @created 2026-10-29
     * @usedBy generate
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    private TokenUsage usage(JsonNode raw) {
        if (raw.isMissingNode() || raw.isNull()) {
            return null;
        }
        long input = natural(raw.path(AiFieldConstants.OpenAi.INPUT_TOKENS));
        long output = natural(raw.path(AiFieldConstants.OpenAi.OUTPUT_TOKENS));
        long cached = raw.path(AiFieldConstants.OpenAi.INPUT_TOKENS_DETAILS)
            .path(AiFieldConstants.OpenAi.CACHED_TOKENS)
            .isMissingNode()
                ? 0
                : natural(
                    raw.get(AiFieldConstants.OpenAi.INPUT_TOKENS_DETAILS)
                        .get(AiFieldConstants.OpenAi.CACHED_TOKENS)
                );
        if (cached > input) {
            throw invalid();
        }
        return new TokenUsage(input, cached, output);
    }

    /**
     * 음수·실수·문자열 사용량을 정상 토큰 수로 바꾸지 않는다.
     * @created 2026-10-29
     * @usedBy countInput, usage
     * @modified 2026-11-02 - 제어문 본문 구분
     */
    private long natural(JsonNode value) {
        if (value == null
            || !value.isIntegralNumber()
            || !value.canConvertToLong()
            || value.longValue() < 0) {
            throw invalid();
        }
        return value.longValue();
    }

    /**
     * 공급자 원문 없이 구조 오류를 전달한다. 전송 사실은 유지한다.
     * @created 2026-10-29
     * @usedBy generate, usage, natural
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 상수 타입 명시 참조
     */
    private ProviderFailure invalid() {
        return new ProviderFailure(Provider.INVALID_PROVIDER_RESPONSE, true);
    }

}
