package com.payse.api.analysis.service;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;

import com.payse.api.analysis.mapper.AnalysisCosts;
import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

/**
 * 비공개 경로 명시·중복 설정 차단·원문 비노출과 기본 비활성을 검사한다.
 * @created 2026-11-03
 * @usedBy Gradle JUnit
 */
class AnalysisSettingsTest {
    @TempDir
    Path directory;

    /**
     * 설정 없는 서버는 장부나 외부 공급자에 접근하지 않는다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void staysClosedWithoutSettings() {
        AnalysisCosts costs = mock(AnalysisCosts.class);
        AnalysisRuntime runtime = new AnalysisConfiguration().analysisRuntime("", costs);
        assertThrows(FinancialException.class, runtime::requireReady);
        verifyNoInteractions(costs);
    }

    /**
     * disabled 예시는 자격이 없어도 명시 비활성으로 읽고 문자열에 설정을 노출하지 않는다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void acceptsExplicitDisabledAndRejectsDuplicates() throws Exception {
        Path file = directory.resolve("analysis.properties");
        String source = """
            enabled=false
            llmSettingsFile=
            kmsTokenFile=
            kmsKey=
            projectId=
            pricingVersion=
            """;
        Files.writeString(file, source);
        AnalysisSettings settings = AnalysisSettings.read(file);
        assertFalse(settings.enabled());
        assertEquals("AnalysisSettings[REDACTED]", settings.toString());
        Files.writeString(file, source + "enabled=true\napiKey=never-print-this\n");
        var failure = assertThrows(
            IllegalArgumentException.class,
            () -> AnalysisSettings.read(file)
        );
        assertFalse(failure.toString().contains("never-print-this"));
        assertEquals(null, failure.getCause());
    }

    /**
     * 운영자가 갱신한 토큰 파일만 다시 읽고 상대 경로·크기 초과를 거절한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void readsOnlyExplicitCredentialFile() throws Exception {
        Path file = directory.resolve("analysis.properties");
        Path token = directory.resolve("kms.token");
        Files.writeString(token, "test-only-first");
        String source = """
            enabled=true
            llmSettingsFile=%s
            kmsTokenFile=%s
            kmsKey=projects/test/locations/global/keyRings/test/cryptoKeys/test
            projectId=test-project
            pricingVersion=test-v1
            """.formatted(
                directory.resolve("llm.properties").toString().replace('\\', '/'),
                token.toString().replace('\\', '/')
            );
        Files.writeString(file, source);
        AnalysisSettings settings = AnalysisSettings.read(file);
        assertTrue(settings.enabled());
        assertEquals("test-only-first", settings.kmsToken());
        Files.writeString(token, "test-only-second");
        assertEquals("test-only-second", settings.kmsToken());
        Files.writeString(token, "bad\nheader");
        assertThrows(IllegalArgumentException.class, settings::kmsToken);
        Files.writeString(file, "x".repeat(16385));
        assertThrows(IllegalArgumentException.class, () -> AnalysisSettings.read(file));
        assertThrows(
            IllegalArgumentException.class,
            () -> AnalysisSettings.read(Path.of("relative.properties"))
        );
    }
}
