package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.junit.jupiter.api.Assertions.assertThrows;

import com.payse.ai.analysis.service.PromptGuide;
import com.payse.ai.analysis.validation.AnalysisContract;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * 실제 파일·잠금으로 준비 재사용, 손상 복구, 변경 무효화와 기록 분리를 확인한다.
 * @created 2026-11-04
 * @usedBy Gradle test
 */
class AnalysisReadinessTest {
    @TempDir
    Path directory;

    /**
     * 실제 번들 지침의 변경을 준비 프로필에 빠뜨리면 시작 전에 발견한다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void acceptsBundledPrompt() throws Exception {
        String version = new PromptGuide(new AnalysisContract().instructions()).version();
        try (var readiness = new AnalysisReadiness(directory)) {
            readiness.prepare(version, "config-a");
        }
    }

    /**
     * 재시작은 준비 시각과 설치 횟수를 유지하고 유료 호출을 만들지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void reusesPreparedProfileAndSeparatesObservations() throws Exception {
        String first;
        try (var readiness = new AnalysisReadiness(directory)) {
            readiness.prepare(readiness.profile().path("validatedPrompt").asString(), "config-a");
            var value = AnalysisJson.JSON.readTree(directory.resolve("ai-status.json").toFile());
            assertEquals(1, value.path("preparationCount").asInt());
            assertFalse(value.has("analysisValidatedAt"));
            first = value.path("preparedAt").asString();
            readiness.observe("providerSuccess");
            readiness.observe("analysisFailure");
            assertThrows(IllegalStateException.class, () -> new AnalysisReadiness(directory));
        }
        try (var readiness = new AnalysisReadiness(directory)) {
            readiness.prepare(readiness.profile().path("validatedPrompt").asString(), "config-a");
            var value = AnalysisJson.JSON.readTree(directory.resolve("ai-status.json").toFile());
            assertEquals(first, value.path("preparedAt").asString());
            assertEquals(1, value.path("preparationCount").asInt());
            assertTrue(value.path("preparationReused").asBoolean());
            assertTrue(value.has("providerSuccessAt"));
            assertFalse(value.has("analysisValidatedAt"));
        }
    }

    /**
     * 비밀 회전·프로필 손상·프롬프트 불일치를 과거 성공으로 처리하지 않는다.
     * @created 2026-11-04
     * @usedBy JUnit
     */
    @Test
    void invalidatesChangedOrMissingConfiguration() throws Exception {
        try (var readiness = new AnalysisReadiness(directory)) {
            readiness.prepare(readiness.profile().path("validatedPrompt").asString(), "config-a");
            readiness.observe("analysisValidated");
            readiness.prepare(readiness.profile().path("validatedPrompt").asString(), "config-b");
            var value = AnalysisJson.JSON.readTree(directory.resolve("ai-status.json").toFile());
            assertEquals(2, value.path("preparationCount").asInt());
            assertFalse(value.has("analysisValidatedAt"));
            Files.writeString(directory.resolve("ai-profile.json"), "{}");
            readiness.prepare(readiness.profile().path("validatedPrompt").asString(), "config-b");
            value = AnalysisJson.JSON.readTree(directory.resolve("ai-status.json").toFile());
            assertEquals(3, value.path("preparationCount").asInt());
            assertThrows(IllegalStateException.class, () -> readiness.prepare("wrong-prompt", "config-b"));
        }
    }
}
