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
import java.nio.file.LinkOption;
import java.nio.file.OpenOption;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.Objects;
import java.util.Properties;
import java.util.Set;
import java.util.regex.Pattern;

/**
 * 명시한 비공개 설정과 키 파일만 읽는다. 프로세스 환경·Codex 자격을 탐색하지 않는다.
 * @created 2026-11-01
 * @usedBy LlmSettingsTest, AnalysisConfiguration.analysisRuntime
 * @modified 2026-11-03 - 명시적 env 키 파일 참조 지원
 */
public final class LlmSettings {
    private static final int FILE_LIMIT = 16384;
    private static final Pattern ENV_ENTRY = Pattern.compile(
        "^\\s*(?:export\\s+)?" + AiConfigConstants.Llm.API_KEY_ENV_NAME + "\\s*=\\s*(.*?)\\s*$"
    );
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
     * @modified 2026-11-03 - 선택적 키 파일과 기존 직접 설정을 상호 배타적으로 검증
     */
    private LlmSettings(Properties values) {
        Set<String> keys = new HashSet<>(values.stringPropertyNames());
        keys.remove(AiConfigConstants.Llm.API_KEY_ENV_FILE);
        if (!keys.equals(KEYS)) {
            throw invalid();
        }
        String flag = values.getProperty(AiConfigConstants.Llm.ENABLED);
        if (!Set.of(AiConfigConstants.Llm.TRUE_VALUE, AiConfigConstants.Llm.FALSE_VALUE)
            .contains(flag)) {
            throw invalid();
        }

        enabled = Boolean.parseBoolean(flag);
        model = values.getProperty(AiConfigConstants.Llm.MODEL);
        effort = values.getProperty(AiConfigConstants.Llm.REASONING_EFFORT);
        if (enabled
            && (!AiConfigConstants.Llm.OPENAI
                .equals(values.getProperty(AiConfigConstants.Llm.PROVIDER))
                || !model.matches(AiConfigConstants.Llm.MODEL_PATTERN)
                || !EFFORTS.contains(effort))) {
            throw invalid();
        }
        apiKey = enabled ? credential(values) : "";
        if (enabled && !apiKey.matches(AiConfigConstants.Llm.BEARER_PATTERN)) {
            throw invalid();
        }
    }

    /**
     * UTF-8 파일 하나를 제한 크기로 읽는다. 원문·경로·키가 포함된 파서 예외는 노출하지 않는다.
     * @created 2026-11-01
     * @usedBy API 분석 실행 구성, LlmSettingsTest
     * @modified 2026-11-02 - 제어문 본문 구분
     * @modified 2026-11-03 - 설정과 참조 파일의 제한 읽기를 공유하고 원문 오류 차단
     */
    public static LlmSettings read(Path file) {
        if (file == null) {
            throw invalid();
        }

        try {
            Properties values = new UniqueProperties();
            values.load(new StringReader(text(file)));
            return new LlmSettings(values);
        } catch (IOException | IllegalArgumentException | SecurityException failure) {
            throw invalid();
        }
    }

    /**
     * 활성 구성에서만 명시한 자격 하나를 읽으며 환경 탐색·쉘 실행·값 보간을 하지 않는다.
     * @created 2026-11-03
     * @usedBy LlmSettings
     */
    private static String credential(Properties values) {
        String direct = values.getProperty(AiConfigConstants.Llm.API_KEY);
        String configured = values.getProperty(AiConfigConstants.Llm.API_KEY_ENV_FILE, "");
        if (configured.isBlank()) {
            return direct;
        }
        if (!direct.isBlank()) {
            throw invalid();
        }
        Path file = Path.of(configured);
        if (!file.isAbsolute() || !Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
            throw invalid();
        }

        try {
            String key = null;
            for (String line : text(file, LinkOption.NOFOLLOW_LINKS).split("\\R")) {
                var entry = ENV_ENTRY.matcher(line);
                if (!entry.matches()) {
                    continue;
                }
                if (key != null) {
                    throw invalid();
                }
                key = entry.group(1);
                if (key.length() >= 2
                    && ((key.startsWith("\"") && key.endsWith("\""))
                        || (key.startsWith("'") && key.endsWith("'")))) {
                    key = key.substring(1, key.length() - 1);
                }
            }
            if (key == null) {
                throw invalid();
            }
            return key;
        } catch (IOException failure) {
            throw invalid();
        }
    }

    /**
     * UTF-8 파일을 제한 크기로 읽고 임시 바이트를 지운다. 문자열 원문은 출력하지 않는다.
     * @created 2026-11-03
     * @usedBy read, credential
     */
    private static String text(Path file, OpenOption... options) throws IOException {
        byte[] bytes = null;
        try (var input = Files.newInputStream(file, options)) {
            bytes = input.readNBytes(FILE_LIMIT + 1);
            if (bytes.length > FILE_LIMIT) {
                throw invalid();
            }
            String value = StandardCharsets.UTF_8.newDecoder()
                .decode(ByteBuffer.wrap(bytes))
                .toString();
            return value.startsWith("\uFEFF") ? value.substring(1) : value;
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
     * 준비 프로필과 실제 추론 설정을 대조한다.
     * @created 2026-11-04
     * @usedBy GammaDeployment.deployedGammaRuntime
     */
    public String reasoningEffort() {
        return effort;
    }

    /**
     * 자격 회전 시 연결 확인을 무효화하며 자격 자체를 노출하지 않는다.
     * @created 2026-11-04
     * @usedBy GammaDeployment.deployedGammaRuntime
     * @modified 2026-11-04 - 명시 표준 처리 정책을 일회성 준비 지문에 포함
     */
    public String configurationFingerprint() {
        try {
            String material = model + "\n" + effort + "\n"
                + AiConfigConstants.OpenAi.SERVICE_DEFAULT + "\n" + apiKey;
            byte[] hash = java.security.MessageDigest
                .getInstance(AiConfigConstants.Llm.FINGERPRINT_ALGORITHM)
                .digest(material.getBytes(StandardCharsets.UTF_8));
            return java.util.HexFormat.of().formatHex(hash);
        } catch (java.security.NoSuchAlgorithmException failure) {
            throw invalid();
        }
    }

    /**
     * 기존 게이트웨이를 생성할 팩토리를 반환한다. 모델·키는 파일, 호출 상한은 API 정책에서 받는다.
     * @created 2026-11-01
     * @usedBy API 분석 실행 구성, LlmSettingsTest
     * @modified 2026-11-04 - 기본 요청의 표준 처리 등급을 명시
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    public ModelFactory factory(ProviderHttp http, int inputLimit, int outputLimit) {
        return factory(http, inputLimit, outputLimit, AiConfigConstants.OpenAi.SERVICE_DEFAULT);
    }

    /**
     * 별도 비용 상한을 확보한 비교 실행에만 요청 단위 Fast 등급을 전달한다.
     * @created 2026-11-04
     * @usedBy GammaLocalConfig.gammaRuntime, LlmSettings.factory
     */
    public ModelFactory factory(
        ProviderHttp http,
        int inputLimit,
        int outputLimit,
        String serviceTier
    ) {
        return factory(http, inputLimit, outputLimit, serviceTier, null);
    }

    /**
     * 명시 비교의 응답 길이만 전달한다. 미지정 요청의 공급자 기본 동작은 유지한다.
     * @created 2026-11-04
     * @usedBy GammaLocalConfig.gammaRuntime, LlmSettings.factory
     */
    public ModelFactory factory(
        ProviderHttp http,
        int inputLimit,
        int outputLimit,
        String serviceTier,
        String verbosity
    ) {
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
            outputLimit,
            serviceTier,
            verbosity
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
