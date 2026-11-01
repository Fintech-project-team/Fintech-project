package com.payse.ai.provider.config;

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
    private static final Set<String> KEYS = Set.of("enabled", "provider", "model", "apiKey", "reasoningEffort");
    private static final Set<String> EFFORTS = Set.of("none", "low", "medium", "high", "xhigh", "max");
    private final boolean enabled;
    private final String model;
    private final String apiKey;
    private final String effort;

    /**
     * 값·공급자를 검증하고 설정을 고정한다. 활성화되지 않은 구성은 호출에 사용할 수 없다.
     * @created 2026-11-01
     * @usedBy read
     */
    private LlmSettings(Properties values) {
        if (!values.keySet().equals(KEYS)) throw invalid();
        String flag = values.getProperty("enabled");
        if (!Set.of("true", "false").contains(flag)) throw invalid();
        enabled = Boolean.parseBoolean(flag);
        model = values.getProperty("model");
        apiKey = values.getProperty("apiKey");
        effort = values.getProperty("reasoningEffort");
        if (enabled && (!"openai".equals(values.getProperty("provider"))
                || !model.matches("[A-Za-z0-9][A-Za-z0-9._:-]*")
                || !apiKey.matches("[-A-Za-z0-9._~+/]+=*") || !EFFORTS.contains(effort))) {
            throw invalid();
        }
    }

    /**
     * UTF-8 파일 하나를 제한 크기로 읽는다. 원문·경로·키가 포함된 파서 예외는 노출하지 않는다.
     * @created 2026-11-01
     * @usedBy API 분석 실행 구성, LlmSettingsTest
     */
    public static LlmSettings read(Path file) {
        if (file == null) throw invalid();
        byte[] bytes = null;
        try (var input = Files.newInputStream(file)) {
            bytes = input.readNBytes(FILE_LIMIT + 1);
            if (bytes.length > FILE_LIMIT) throw invalid();
            String text = StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(bytes)).toString();
            if (text.startsWith("\uFEFF")) text = text.substring(1);
            Properties values = new UniqueProperties();
            values.load(new StringReader(text));
            return new LlmSettings(values);
        } catch (IOException | IllegalArgumentException | SecurityException failure) {
            throw invalid();
        } finally {
            if (bytes != null) java.util.Arrays.fill(bytes, (byte) 0);
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
     * 기존 게이트웨이를 생성할 팩토리를 반환한다. 모델·키는 파일, 호출 상한은 API 정책에서 받는다.
     * @created 2026-11-01
     * @usedBy API 분석 실행 구성, LlmSettingsTest
     */
    public ModelFactory factory(ProviderHttp http, int inputLimit, int outputLimit) {
        if (!enabled) throw new IllegalStateException("LLM provider is disabled");
        Objects.requireNonNull(http, "http");
        if (inputLimit < 1 || outputLimit < 1) throw new IllegalArgumentException("LLM limits are required");
        return (instructions, schema) -> new OpenAiGateway(http, () -> apiKey, model, instructions,
            effort, schema, inputLimit, outputLimit);
    }

    /**
     * 구성 원문이 로그에 포함되지 않도록 고정 문자열만 반환한다.
     * @created 2026-11-01
     * @usedBy 진단 출력, LlmSettingsTest
     */
    @Override
    public String toString() {
        return "LlmSettings[REDACTED]";
    }

    /**
     * 설정 오류를 원문이나 원인 예외 없이 보고한다.
     * @created 2026-11-01
     * @usedBy read, LlmSettings, UniqueProperties.put
     */
    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException("LLM configuration is invalid or unavailable");
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
         */
        @Override
        public synchronized Object put(Object key, Object value) {
            if (containsKey(key)) throw invalid();
            return super.put(key, value);
        }
    }
}
