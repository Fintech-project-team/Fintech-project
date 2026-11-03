package com.payse.ai.provider.config;

import com.payse.ai.constants.AiConfigConstants;
import com.payse.ai.constants.AiMessageConstants;
import com.payse.ai.provider.ModelFactory;
import com.payse.ai.provider.openai.OpenAiGateway;
import com.payse.ai.transport.ProviderHttp;
import java.io.IOException;
import java.io.StringReader;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Objects;
import java.util.Properties;
import java.util.Set;

/**
 * 명시한 비공개 파일의 연결 설정만 읽는다. 환경·Codex 자격을 사용하거나 외부 통신하지 않는다.
 * @created 2026-11-01
 * @usedBy LlmSettingsTest, 미연결: 예정 사용처 API 분석 실행 구성
 */
public final class LlmSettings {
    private static final int FILE_LIMIT = 16384;
    private static final Set<String> KEYS = Set.of(
        AiConfigConstants.Llm.ENABLED,
        AiConfigConstants.Llm.PROVIDER,
        AiConfigConstants.Llm.MODEL,
        AiConfigConstants.Llm.API_KEY,
        AiConfigConstants.Llm.REASONING_EFFORT
    );
    private static final Set<String> EFFORTS = Set.of(
        AiConfigConstants.Llm.EFFORT_NONE,
        AiConfigConstants.Llm.EFFORT_LOW,
        AiConfigConstants.Llm.EFFORT_MEDIUM,
        AiConfigConstants.Llm.EFFORT_HIGH,
        AiConfigConstants.Llm.EFFORT_XHIGH,
        AiConfigConstants.Llm.EFFORT_MAX
    );
    private final boolean enabled;
    private final String model;
    private final String apiKey;
    private final String effort;

    /**
     * 값·공급자를 검증하고 설정을 고정한다. 활성화되지 않은 구성은 호출에 사용할 수 없다.
     * @created 2026-11-01
     * @usedBy read
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    private LlmSettings(Properties values) {
        if (!values.keySet().equals(KEYS)) {
            throw invalid();
        }
        String flag = values.getProperty(AiConfigConstants.Llm.ENABLED);
        if (!Set.of(AiConfigConstants.Llm.TRUE_VALUE, AiConfigConstants.Llm.FALSE_VALUE)
            .contains(flag)) {
            throw invalid();
        }

        enabled = Boolean.parseBoolean(flag);
        model = values.getProperty(AiConfigConstants.Llm.MODEL);
        apiKey = values.getProperty(AiConfigConstants.Llm.API_KEY);
        effort = values.getProperty(AiConfigConstants.Llm.REASONING_EFFORT);
        if (enabled
            && (!AiConfigConstants.Llm.OPENAI
                .equals(values.getProperty(AiConfigConstants.Llm.PROVIDER))
                || !model.matches(AiConfigConstants.Llm.MODEL_PATTERN)
                || !apiKey.matches(AiConfigConstants.Llm.BEARER_PATTERN)
                || !EFFORTS.contains(effort))) {
            throw invalid();
        }
    }

    /**
     * UTF-8 파일 하나를 제한 크기로 읽는다. 원문·경로·키가 포함된 파서 예외는 노출하지 않는다.
     * @created 2026-11-01
     * @usedBy API 분석 실행 구성, LlmSettingsTest
     * @modified 2026-11-02 - 제어문 본문 구분
     */
    public static LlmSettings read(Path file) {
        if (file == null) {
            throw invalid();
        }

        byte[] bytes = null;
        try (var input = Files.newInputStream(file)) {
            bytes = input.readNBytes(FILE_LIMIT + 1);
            if (bytes.length > FILE_LIMIT) {
                throw invalid();
            }
            String text = StandardCharsets.UTF_8.newDecoder()
                .decode(ByteBuffer.wrap(bytes))
                .toString();
            if (text.startsWith("\uFEFF")) {
                text = text.substring(1);
            }

            Properties values = new UniqueProperties();
            values.load(new StringReader(text));
            return new LlmSettings(values);
        } catch (IOException | IllegalArgumentException | SecurityException failure) {
            throw invalid();
        } finally {
            if (bytes != null) {
                java.util.Arrays.fill(bytes, (byte) 0);
            }
        }
    }

    /**
     * 운영 연결 허용 여부만 반환한다. 키나 공급자 원문을 노출하지 않는다.
     * @created 2026-11-01
     * @usedBy API 분석 실행 구성, LlmSettingsTest
     */
    public boolean enabled() {
        return enabled;
    }

    /**
     * 승인 가격·캐시 버전과 대조할 모델 이름만 반환한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public String model() {
        return model;
    }

    /**
     * 기존 게이트웨이를 생성할 팩토리를 반환한다. 모델·키는 파일, 호출 상한은 API 정책에서 받는다.
     * @created 2026-11-01
     * @usedBy API 분석 실행 구성, LlmSettingsTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    public ModelFactory factory(ProviderHttp http, int inputLimit, int outputLimit) {
        if (!enabled) {
            throw new IllegalStateException(AiMessageConstants.Llm.DISABLED_PROVIDER);
        }
        Objects.requireNonNull(http, AiMessageConstants.Llm.HTTP_PARAMETER);
        if (inputLimit < 1 || outputLimit < 1) {
            throw new IllegalArgumentException(AiMessageConstants.Llm.MISSING_LIMITS);
        }

        return (instructions, schema) -> new OpenAiGateway(
            http,
            () -> apiKey,
            model,
            instructions,
            effort,
            schema,
            inputLimit,
            outputLimit
        );
    }

    /**
     * 구성 원문이 로그에 포함되지 않도록 고정 문자열만 반환한다.
     * @created 2026-11-01
     * @usedBy 진단 출력, LlmSettingsTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    @Override
    public String toString() {
        return AiMessageConstants.Llm.REDACTED_SETTINGS;
    }

    /**
     * 설정 오류를 원문이나 원인 예외 없이 보고한다.
     * @created 2026-11-01
     * @usedBy read, LlmSettings, UniqueProperties.put
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException(AiMessageConstants.Llm.INVALID_CONFIGURATION);
    }

    /**
     * 같은 키가 반복되어 앞선 연결 설정이 조용히 교체되는 것을 거절한다.
     * @created 2026-11-01
     * @usedBy read
     */
    private static final class UniqueProperties extends Properties {
        /**
         * Properties 파서의 중복 키를 저장 전에 검사한다.
         * @created 2026-11-01
         * @usedBy Properties.load
         * @modified 2026-11-02 - 제어문 본문 구분
         */
        @Override
        public synchronized Object put(Object key, Object value) {
            if (containsKey(key)) {
                throw invalid();
            }
            return super.put(key, value);
        }
    }
}
