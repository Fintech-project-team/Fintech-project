package com.payse.ai.provider.config;

import static org.junit.jupiter.api.Assertions.*;

import com.payse.ai.AiTestConstants.Llm;
import com.payse.ai.AiTestConstants.Schema;
import com.payse.ai.provider.openai.OpenAiGateway;
import com.payse.ai.transport.ProviderHttp;
import java.net.http.HttpClient;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import tools.jackson.databind.json.JsonMapper;

/**
 * 합성 키만으로 설정 차단·비노출·팩토리 구성을 검증한다. 실제 공급자 호출은 하지 않는다.
 * @created 2026-11-01
 * @usedBy JUnit
 */
class LlmSettingsTest {

    @TempDir
    Path directory;

    /**
     * 공유 예시는 연결정보가 비어 있고 비활성 상태이며 팩토리 생성을 막는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-03 - 새 키 파일 예시도 빈 값인지 확인
     */
    @Test
    void blankExampleStaysDisabled() throws Exception {
        Path example = Path.of(Llm.CONFIG_DIRECTORY, Llm.EXAMPLE_FILE);
        var values = new java.util.Properties();
        try (var reader = Files.newBufferedReader(example, StandardCharsets.UTF_8)) {
            values.load(reader);
        }
        var configurationKeys = java.util.List.of(
            Llm.PROVIDER,
            Llm.MODEL,
            Llm.API_KEY,
            Llm.API_KEY_ENV_FILE,
            Llm.REASONING_EFFORT
        );
        for (String key : configurationKeys) {
            assertEquals("", values.getProperty(key));
        }
        var settings = LlmSettings.read(example);
        assertFalse(settings.enabled());
        assertThrows(IllegalStateException.class, () -> settings.factory(null, 6000, 1200));
    }

    /**
     * 합성 설정으로 기존 팩토리·게이트웨이 생성까지만 실행한다. 계수·생성 호출은 하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void createsGatewayWithoutCallingProvider() throws Exception {
        var settings = LlmSettings.read(write(valid()));
        assertTrue(settings.enabled());
        assertEquals(Llm.REDACTED_SETTINGS, settings.toString());
        try (var client = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(1))
            .build()) {
            var http = new ProviderHttp(client, Duration.ofSeconds(2), 1024);
            var factory = settings.factory(http, 6000, 1200);
            var schema = JsonMapper.builder()
                .build()
                .createObjectNode()
                .put(Schema.TYPE_KEY, Schema.OBJECT_TYPE);
            assertInstanceOf(OpenAiGateway.class, factory.create("test instructions", schema));
            assertThrows(IllegalArgumentException.class, () -> settings.factory(http, 0, 1200));
        }
    }

    /**
     * 파일 누락을 개인 환경의 키로 대체하지 않고 경로·원인 예외를 감춘다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합; 상수 타입 명시 참조
     */
    @Test
    void rejectsMissingFileWithoutFallback() {
        var failure = assertThrows(
            IllegalArgumentException.class,
            () -> LlmSettings.read(directory.resolve("private-file-name"))
        );
        assertEquals(Llm.INVALID_CONFIGURATION, failure.getMessage());
        assertNull(failure.getCause());
        assertThrows(IllegalArgumentException.class, () -> LlmSettings.read(null));
    }

    /**
     * 빈 자격·미지원 공급자·중복/오타 키·잘못된 옵션을 호출 전에 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void rejectsIncompleteAndAmbiguousSettings() throws Exception {
        var invalidSettings = java.util.List.of(
            valid().replace("enabled=true", "enabled=yes"),
            valid().replace("provider=openai", "provider=local"),
            valid().replace("apiKey=test-key", "apiKey="),
            valid().replace("apiKey=test-key", "apiKey=test key"),
            valid().replace("model=test-model", "model="),
            valid().replace("reasoningEffort=low", "reasoningEffort=invalid"),
            valid() + "apiKey=replacement-test-key\n",
            valid() + "baseUrl=https://untrusted.invalid\n",
            valid().replace("apiKey=test-key\n", "")
        );
        for (String content : invalidSettings) {
            Path file = write(content);

            var failure = assertThrows(
                IllegalArgumentException.class,
                () -> LlmSettings.read(file)
            );
            assertEquals(Llm.INVALID_CONFIGURATION, failure.getMessage());
            assertNull(failure.getCause());
        }
    }

    /**
     * UTF-8 BOM은 허용하되 비정상 인코딩·파서 원문·과대 파일은 비밀 없이 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 상수 타입 명시 참조
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 독립 테스트 상수 통합
     */
    @Test
    void boundsInputAndSanitizesParseFailures() throws Exception {
        Path bomFile = write("\uFEFF" + valid());
        LlmSettings withBom = LlmSettings.read(bomFile);
        assertTrue(withBom.enabled());
        var malformedSettings = java.util.List.of(
            valid() + "#".repeat(16385),
            valid().replace("test-key", "\\u-not-a-key")
        );
        for (String content : malformedSettings) {
            Path file = write(content);

            var failure = assertThrows(
                IllegalArgumentException.class,
                () -> LlmSettings.read(file)
            );
            assertEquals(Llm.INVALID_CONFIGURATION, failure.getMessage());
            assertNull(failure.getCause());
        }
        Path file = directory.resolve("invalid.properties");
        Files.write(file, new byte[] { (byte) 0xC3, (byte) 0x28 });
        assertThrows(IllegalArgumentException.class, () -> LlmSettings.read(file));
    }

    /**
     * 파일 변경은 다음 명시 로드에만 반영하며 처리 중 구성을 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void reloadsOnlyWhenExplicitlyRequested() throws Exception {
        Path file = write(valid());
        var loaded = LlmSettings.read(file);
        write(valid().replace("enabled=true", "enabled=false"));
        assertTrue(loaded.enabled());
        assertFalse(LlmSettings.read(file).enabled());
    }

    /**
     * 명시한 파일의 리터럴 키만 읽으며 기존 직접 설정과 빈 참조 설정도 유지한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void readsExplicitEnvFile() throws Exception {
        Path env = directory.resolve("private.env");
        for (String content : java.util.List.of(
            "OPENAI_API_KEY=test-key\n",
            "\uFEFF# local only\r\nexport OPENAI_API_KEY = 'test-key'\r\n",
            "UNRELATED_VALUE=ignored\nOPENAI_API_KEY=\"test-key\"\n"
        )) {
            Files.writeString(env, content, StandardCharsets.UTF_8);
            var settings = LlmSettings.read(write(withEnvFile(env)));
            assertTrue(settings.enabled());
            assertEquals("test-model", settings.model());
            assertEquals(Llm.REDACTED_SETTINGS, settings.toString());
        }
        assertTrue(LlmSettings.read(write(valid())).enabled());
        assertTrue(LlmSettings.read(write(valid() + "apiKeyEnvFile=\n")).enabled());
    }

    /**
     * 중복·누락·빈 키·쉘 표현식·비정상 Bearer를 원문 노출 없이 차단한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void rejectsInvalidEnvCredentials() throws Exception {
        Path env = directory.resolve("private.env");
        for (String content : java.util.List.of(
            "OPENAI_API_KEY=test-key\nOPENAI_API_KEY=second-key\n",
            "OPENAI_API_KEY=\nexport OPENAI_API_KEY=test-key\n",
            "OPENAI_API_KEY=\n",
            "OPENAI_API_KEY='test key'\n",
            "OPENAI_API_KEY=${OTHER_KEY}\n",
            "OPENAI_API_KEY=$(echo test-key)\n",
            "# OPENAI_API_KEY=test-key\n",
            "OPENAI_API_KEY=test-key\n" + "#".repeat(16385)
        )) {
            Files.writeString(env, content, StandardCharsets.UTF_8);
            Path settings = write(withEnvFile(env));
            var failure = assertThrows(
                IllegalArgumentException.class,
                () -> LlmSettings.read(settings)
            );
            assertEquals(Llm.INVALID_CONFIGURATION, failure.getMessage());
            assertNull(failure.getCause());
        }
        Files.write(env, new byte[] { (byte) 0xC3, (byte) 0x28 });
        Path settings = write(withEnvFile(env));
        assertThrows(IllegalArgumentException.class, () -> LlmSettings.read(settings));
    }

    /**
     * 자격 출처의 동시 지정·상대 경로·파일 누락을 활성 구성에서 거절한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void rejectsAmbiguousEnvLocations() throws Exception {
        Path env = directory.resolve("private.env");
        Files.writeString(env, "OPENAI_API_KEY=test-key\n", StandardCharsets.UTF_8);
        Path relative = Path.of("").toAbsolutePath().relativize(env.toAbsolutePath());
        for (String content : java.util.List.of(
            withEnvFile(env).replace("apiKey=\n", "apiKey=another-key\n"),
            withEnvFile(relative),
            withEnvFile(directory.resolve("missing.env")),
            withEnvFile(directory),
            withEnvFile(env) + "apiKeyEnvFile=second-file\n"
        )) {
            Path settings = write(content);
            var failure = assertThrows(
                IllegalArgumentException.class,
                () -> LlmSettings.read(settings)
            );
            assertEquals(Llm.INVALID_CONFIGURATION, failure.getMessage());
            assertNull(failure.getCause());
        }
    }

    /**
     * 비활성 구성은 키 파일을 요구하지 않고 활성 구성의 키는 명시 재로드 때만 바뀐다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void readsEnvOnlyOnEnabledLoad() throws Exception {
        Path env = directory.resolve("private.env");
        Path settings = write(withEnvFile(env).replace("enabled=true", "enabled=false"));
        assertFalse(LlmSettings.read(settings).enabled());

        Files.writeString(env, "OPENAI_API_KEY=test-key\n", StandardCharsets.UTF_8);
        settings = write(withEnvFile(env));
        var loaded = LlmSettings.read(settings);
        Files.delete(env);
        assertTrue(loaded.enabled());
        Path reload = settings;
        assertThrows(IllegalArgumentException.class, () -> LlmSettings.read(reload));
    }

    /**
     * 합성 env 파일의 경로만 넣고 properties의 역슬래시 이스케이프를 피한다.
     * @created 2026-11-03
     * @usedBy env 파일 설정 검증
     */
    private String withEnvFile(Path file) {
        String path = file.toString().replace('\\', '/');
        return valid().replace("apiKey=test-key\n", "apiKey=\n")
            + Llm.API_KEY_ENV_FILE + "=" + path + "\n";
    }

    /**
     * 실제 비밀이 아닌 고정 합성 연결정보를 제공한다.
     * @created 2026-11-01
     * @usedBy 설정 검증 테스트
     */
    private String valid() {
        return "enabled=true\nprovider=openai\nmodel=test-model\napiKey=test-key\nreasoningEffort=low\n";
    }

    /**
     * 검증 사례를 JUnit 임시 폴더에만 기록한다.
     * @created 2026-11-01
     * @usedBy 설정 검증 테스트
     */
    private Path write(String content) throws Exception {
        return Files
            .writeString(directory.resolve("llm.properties"), content, StandardCharsets.UTF_8);
    }
}
