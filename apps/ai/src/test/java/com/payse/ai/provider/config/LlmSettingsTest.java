package com.payse.ai.provider.config;

import static org.junit.jupiter.api.Assertions.*;

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
     */
    @Test
    void blankExampleStaysDisabled() throws Exception {
        Path example = Path.of("config", "llm.properties.example");
        var values = new java.util.Properties();
        try (var reader = Files.newBufferedReader(example, StandardCharsets.UTF_8)) {
            values.load(reader);
        }
        for (String key : java.util.List.of("provider", "model", "apiKey", "reasoningEffort")) {
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
     */
    @Test
    void createsGatewayWithoutCallingProvider() throws Exception {
        var settings = LlmSettings.read(write(valid()));
        assertTrue(settings.enabled());
        assertEquals("LlmSettings[REDACTED]", settings.toString());
        try (var client = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(1)).build()) {
            var http = new ProviderHttp(client, Duration.ofSeconds(2), 1024);
            var factory = settings.factory(http, 6000, 1200);
            var schema = JsonMapper.builder().build().createObjectNode().put("type", "object");
            assertInstanceOf(OpenAiGateway.class, factory.create("test instructions", schema));
            assertThrows(IllegalArgumentException.class, () -> settings.factory(http, 0, 1200));
        }
    }

    /**
     * 파일 누락을 개인 환경의 키로 대체하지 않고 경로·원인 예외를 감춘다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsMissingFileWithoutFallback() {
        var failure = assertThrows(IllegalArgumentException.class,
            () -> LlmSettings.read(directory.resolve("private-file-name")));
        assertEquals("LLM configuration is invalid or unavailable", failure.getMessage());
        assertNull(failure.getCause());
        assertThrows(IllegalArgumentException.class, () -> LlmSettings.read(null));
    }

    /**
     * 빈 자격·미지원 공급자·중복/오타 키·잘못된 옵션을 호출 전에 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void rejectsIncompleteAndAmbiguousSettings() throws Exception {
        for (String content : java.util.List.of(
                valid().replace("enabled=true", "enabled=yes"),
                valid().replace("provider=openai", "provider=local"),
                valid().replace("apiKey=test-key", "apiKey="),
                valid().replace("apiKey=test-key", "apiKey=test key"),
                valid().replace("model=test-model", "model="),
                valid().replace("reasoningEffort=low", "reasoningEffort=invalid"),
                valid() + "apiKey=replacement-test-key\n",
                valid() + "baseUrl=https://untrusted.invalid\n",
                valid().replace("apiKey=test-key\n", ""))) {
            Path file = write(content);
            var failure = assertThrows(IllegalArgumentException.class, () -> LlmSettings.read(file));
            assertEquals("LLM configuration is invalid or unavailable", failure.getMessage());
            assertNull(failure.getCause());
        }
    }

    /**
     * UTF-8 BOM은 허용하되 비정상 인코딩·파서 원문·과대 파일은 비밀 없이 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     */
    @Test
    void boundsInputAndSanitizesParseFailures() throws Exception {
        assertTrue(LlmSettings.read(write("\uFEFF" + valid())).enabled());
        for (String content : java.util.List.of(valid() + "#".repeat(16385),
                valid().replace("test-key", "\\u-not-a-key"))) {
            Path file = write(content);
            var failure = assertThrows(IllegalArgumentException.class, () -> LlmSettings.read(file));
            assertEquals("LLM configuration is invalid or unavailable", failure.getMessage());
            assertNull(failure.getCause());
        }
        Path file = directory.resolve("invalid.properties");
        Files.write(file, new byte[] {(byte) 0xC3, (byte) 0x28});
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
        return Files.writeString(directory.resolve("llm.properties"), content, StandardCharsets.UTF_8);
    }
}
