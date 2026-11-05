package com.payse.api.analysis.service;

import com.payse.api.constants.ApiConfigConstants.Execution;
import com.payse.api.constants.ApiMessageConstants;
import java.io.IOException;
import java.io.StringReader;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Properties;
import java.util.Set;

/**
 * 명시된 비공개 설정 파일만 읽는다. 환경의 개인 로그인 자격을 검색하거나 재사용하지 않는다.
 * @created 2026-11-03
 * @usedBy AnalysisConfiguration
 */
public final class AnalysisSettings {
    private final Properties values;

    /**
     * 중복·미등록 키·상대 경로·누락을 거절하고 활성화 여부를 명시적으로 받는다.
     * @created 2026-11-03
     * @usedBy read
     */
    private AnalysisSettings(Properties values) {
        Set<String> keys = Set.of(
            Execution.ENABLED,
            Execution.LLM_FILE,
            Execution.KMS_FILE,
            Execution.KMS_KEY,
            Execution.PROJECT,
            Execution.PRICING
        );
        if (!values.keySet().equals(keys)
            || !Set.of("true", "false").contains(values.getProperty(Execution.ENABLED))) {
            throw invalid();
        }
        this.values = values;
        if (enabled()) {
            for (String key : keys) {
                if (values.getProperty(key).isBlank()) {
                    throw invalid();
                }
            }
            path(Execution.LLM_FILE);
            path(Execution.KMS_FILE);
            if (!project().matches("[A-Za-z0-9_-]{1,120}")
                || !pricingVersion().matches("[A-Za-z0-9_.-]{1,120}")
                || !kmsKey().matches(
                    "projects/[A-Za-z0-9_-]+/locations/[A-Za-z0-9_-]+/keyRings/[A-Za-z0-9_-]+/cryptoKeys/[A-Za-z0-9_-]+"
                )) {
                throw invalid();
            }
        }
    }

    /**
     * UTF-8 설정을 제한 크기로 읽고 파서 원문 예외를 지운다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration, AnalysisSettingsTest
     */
    public static AnalysisSettings read(Path file) {
        try {
            Properties values = new UniqueProperties();
            values.load(new StringReader(text(file)));
            return new AnalysisSettings(values);
        } catch (IOException | IllegalArgumentException | SecurityException failure) {
            throw invalid();
        }
    }

    /**
     * 운영 활성화는 파일의 명시적 true만 허용한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public boolean enabled() {
        return Boolean.parseBoolean(values.getProperty(Execution.ENABLED));
    }

    /**
     * 별도로 관리하는 공급자 설정 경로를 반환한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public Path llmFile() {
        return path(Execution.LLM_FILE);
    }

    /**
     * 명시된 KMS 키 경로만 허용한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public String kmsKey() {
        return values.getProperty(Execution.KMS_KEY);
    }

    /**
     * 운영 인증 공급자가 갱신한 토큰을 호출마다 다시 읽는다. 자동 로그인·갱신은 수행하지 않는다.
     * @created 2026-11-03
     * @usedBy GoogleKms의 토큰 공급자
     */
    public String kmsToken() {
        try {
            String token = text(path(Execution.KMS_FILE)).strip();
            if (!token.matches("[A-Za-z0-9._~+/\\-]+=*")) {
                throw invalid();
            }
            return token;
        } catch (IOException | IllegalArgumentException | SecurityException failure) {
            throw invalid();
        }
    }

    /**
     * 비용 장부의 프로젝트 식별을 반환한다. API 조직 자격을 대신하지 않는다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public String project() {
        return values.getProperty(Execution.PROJECT);
    }

    /**
     * 운영자가 확인한 단가·환산 정책 버전을 반환한다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration
     */
    public String pricingVersion() {
        return values.getProperty(Execution.PRICING);
    }

    /**
     * 설정 원문과 경로가 로그에 남지 않게 한다.
     * @created 2026-11-03
     * @usedBy Java 문자열 변환
     */
    @Override
    public String toString() {
        return ApiMessageConstants.Execution.REDACTED_SETTINGS;
    }

    /**
     * 실행 폴더 변경으로 다른 자격 파일을 읽지 않도록 절대 경로를 요구한다.
     * @created 2026-11-03
     * @usedBy llmFile, kmsToken, AnalysisSettings
     */
    private Path path(String key) {
        Path value = Path.of(values.getProperty(key));
        if (!value.isAbsolute()) {
            throw invalid();
        }
        return value.normalize();
    }

    /**
     * 파일 하나만 읽고 임시 바이트를 지운다. 네트워크 자격 자동 탐색은 하지 않는다.
     * @created 2026-11-03
     * @usedBy read, kmsToken
     */
    private static String text(Path file) throws IOException {
        if (file == null || !file.isAbsolute()) {
            throw invalid();
        }
        byte[] bytes = null;
        try (var input = Files.newInputStream(file)) {
            bytes = input.readNBytes(16385);
            if (bytes.length > 16384) {
                throw invalid();
            }
            String value = StandardCharsets.UTF_8.newDecoder()
                .decode(ByteBuffer.wrap(bytes))
                .toString();
            return value.startsWith("\uFEFF") ? value.substring(1) : value;
        } finally {
            if (bytes != null) {
                Arrays.fill(bytes, (byte) 0);
            }
        }
    }

    /**
     * 민감값·파서 원인을 제외한 설정 오류만 전달한다.
     * @created 2026-11-03
     * @usedBy AnalysisSettings
     */
    private static IllegalArgumentException invalid() {
        return new IllegalArgumentException(ApiMessageConstants.Execution.INVALID_SETTINGS);
    }

    /**
     * 중복 property가 앞선 설정을 덮어쓰는 것을 막는다.
     * @created 2026-11-03
     * @usedBy read
     */
    private static final class UniqueProperties extends Properties {
        /**
         * 파서가 값을 저장하기 전에 중복을 거절한다.
         * @created 2026-11-03
         * @usedBy Properties.load
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
