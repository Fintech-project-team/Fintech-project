package com.payse.api.analysis.service;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants.GammaLocal;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants.Readiness;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.HexFormat;
import java.util.UUID;
import tools.jackson.databind.node.ObjectNode;

/**
 * 유료 호출 없이 배포된 성능 구성을 준비하고 비공개 상태 파일에 관측 사실만 남긴다.
 * @created 2026-11-04
 * @usedBy GammaDeployment, portable_server.py status
 */
final class AnalysisReadiness implements AutoCloseable {
    private final Path directory;
    private final FileChannel channel;
    private final FileLock lock;
    private final ObjectNode profile;
    private ObjectNode status;

    /**
     * 별도 비공개 폴더의 프로세스 잠금을 보유해 두 서버가 같은 기록을 덮지 못하게 한다.
     * @created 2026-11-04
     * @usedBy GammaDeployment.gammaReadiness, AnalysisReadinessTest
     */
    AnalysisReadiness(Path directory) {
        FileChannel opened = null;
        FileLock acquired = null;
        try {
            if (!directory.isAbsolute()
                || !Files.isDirectory(directory, LinkOption.NOFOLLOW_LINKS)) {
                throw invalid();
            }
            for (Path parent = directory; parent != null; parent = parent.getParent()) {
                Path marker = parent.resolve(ApiConfigConstants.Readiness.GIT_MARKER);
                if (Files.isSymbolicLink(parent) || Files.exists(marker)) {
                    throw invalid();
                }
            }
            this.directory = directory;
            Path lockFile = directory.resolve(ApiConfigConstants.Readiness.LOCK_FILE);
            opened = FileChannel.open(lockFile, StandardOpenOption.CREATE,
                StandardOpenOption.WRITE, LinkOption.NOFOLLOW_LINKS);
            acquired = opened.tryLock();
            if (acquired == null) {
                throw invalid();
            }
            try (var resource = AnalysisReadiness.class
                .getResourceAsStream(GammaLocal.PERFORMANCE)) {
                profile = (ObjectNode) AnalysisJson.JSON.readTree(resource);
            }
            String format = profile.path(Readiness.FORMAT).asString();
            String mode = profile.path(Readiness.AGENT).path(Readiness.MODE).asString();
            if (!format.equals(ApiConfigConstants.Readiness.PERFORMANCE_FORMAT)
                || !mode.equals(ApiCodeConstants.Readiness.DIRECT)
                || profile.path(Readiness.AUTOMATIC_RETRIES).asInt() != 0) {
                throw invalid();
            }
            channel = opened;
            lock = acquired;
        } catch (Exception failure) {
            try {
                if (acquired != null) {
                    acquired.close();
                }
                if (opened != null) {
                    opened.close();
                }
            } catch (IOException ignored) {
                // 실패한 준비는 완료 표식을 만들지 않는다.
            }
            throw invalid();
        }
    }

    /**
     * 번들 프로필 사본을 반환한다. 검증되지 않은 모델·에이전트로 자동 대체하지 않는다.
     * @created 2026-11-04
     * @usedBy GammaDeployment.deployedGammaRuntime, gammaCapacity
     */
    ObjectNode profile() {
        return profile.deepCopy();
    }

    /**
     * 프롬프트·실행 설정·키 버전이 같고 설치 파일이 온전하면 최초 준비 시각을 그대로 보존한다.
     * @created 2026-11-04
     * @usedBy GammaDeployment.deployedGammaRuntime
     */
    synchronized void prepare(String prompt, String configuration) {
        if (!profile.path(Readiness.VALIDATED_PROMPT).asString().equals(prompt)) {
            throw invalid();
        }
        try {
            byte[] bytes = AnalysisJson.JSON.writeValueAsBytes(profile);
            String identity = new String(bytes, java.nio.charset.StandardCharsets.UTF_8)
                + configuration;
            byte[] digest = MessageDigest.getInstance(GammaLocal.HASH_ALGORITHM)
                .digest(identity.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            String fingerprint = HexFormat.of().formatHex(digest);
            ObjectNode previous = read(directory.resolve(ApiConfigConstants.Readiness.STATUS_FILE));
            boolean reused = fingerprint.equals(previous.path(Readiness.FINGERPRINT).asString())
                && validRecord(previous)
                && profile.equals(read(directory.resolve(ApiConfigConstants.Readiness.PROFILE_FILE)));
            status = reused ? previous : AnalysisJson.JSON.createObjectNode();
            if (!reused) {
                write(directory.resolve(ApiConfigConstants.Readiness.PROFILE_FILE), profile);
                status.put(Readiness.PREPARED_AT, Instant.now().toString());
                int prior = previous.path(Readiness.PREPARATION_COUNT).asInt(0);
                int count = prior > 0 && prior < Integer.MAX_VALUE ? prior + 1 : 1;
                status.put(Readiness.PREPARATION_COUNT, count);
            }
            status.put(Readiness.FORMAT, ApiConfigConstants.Readiness.READINESS_FORMAT);
            status.put(Readiness.FINGERPRINT, fingerprint);
            status.put(Readiness.PREPARATION, ApiCodeConstants.Readiness.READY);
            status.put(Readiness.PREPARATION_REUSED, reused);
            status.put(Readiness.RUNTIME_STARTED_AT, Instant.now().toString());
            status.put(Readiness.PROCESS_ID, ProcessHandle.current().pid());
            status.put(Readiness.AGENT, ApiCodeConstants.Readiness.DIRECT_BUNDLED);
            status.set(Readiness.PROFILE, profile.deepCopy());
            write(directory.resolve(ApiConfigConstants.Readiness.STATUS_FILE), status);
        } catch (Exception failure) {
            throw invalid();
        }
    }

    /**
     * 본문·식별자 없이 실제 공급자 및 검증 결과 시각만 남긴다. 실패 코드 원문도 저장하지 않는다.
     * @created 2026-11-04
     * @usedBy GammaDeployment.ObservedModel, AnalysisRuntime.analyze
     */
    synchronized void observe(String event) {
        var events = java.util.Set.of(
            ApiCodeConstants.Readiness.PROVIDER_SUCCESS,
            ApiCodeConstants.Readiness.PROVIDER_FAILURE,
            ApiCodeConstants.Readiness.ANALYSIS_VALIDATED,
            ApiCodeConstants.Readiness.ANALYSIS_FAILURE
        );
        if (status == null || !events.contains(event)) {
            throw invalid();
        }
        status.put(event + Readiness.AT_SUFFIX, Instant.now().toString());
        status.put(Readiness.LAST_EVENT, event);
        String countField = event + Readiness.COUNT_SUFFIX;
        status.put(countField, status.path(countField).asLong(0) + 1);
        try {
            write(directory.resolve(ApiConfigConstants.Readiness.STATUS_FILE), status);
        } catch (IOException failure) {
            // 관측 기록 실패로 이미 성공한 유료 호출을 재실행하지 않는다.
            org.slf4j.LoggerFactory.getLogger(AnalysisReadiness.class)
                .warn(ApiMessageConstants.GammaLocal.PREPARATION_FAILED);
        }
    }

    /**
     * 형식이 깨진 완료 표식을 재사용하지 않는다.
     * @created 2026-11-04
     * @usedBy prepare
     */
    private static boolean validRecord(ObjectNode previous) {
        try {
            Instant.parse(previous.path(Readiness.PREPARED_AT).asString());
            return previous.path(Readiness.PREPARATION_COUNT).asInt(0) > 0
                && ApiConfigConstants.Readiness.READINESS_FORMAT
                    .equals(previous.path(Readiness.FORMAT).asString())
                && ApiCodeConstants.Readiness.READY
                    .equals(previous.path(Readiness.PREPARATION).asString());
        } catch (RuntimeException failure) {
            return false;
        }
    }

    /**
     * 손상·과대·링크 파일은 준비되지 않은 상태로 취급한다.
     * @created 2026-11-04
     * @usedBy prepare
     */
    private static ObjectNode read(Path path) {
        try {
            if (Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) && Files.size(path) <= 16384) {
                return (ObjectNode) AnalysisJson.JSON.readTree(path.toFile());
            }
        } catch (Exception ignored) {
            // 손상된 완료 기록은 재사용하지 않는다.
        }
        return AnalysisJson.JSON.createObjectNode();
    }

    /**
     * 완성된 작은 메타데이터만 원자적으로 교체한다.
     * @created 2026-11-04
     * @usedBy prepare, observe
     */
    private static void write(Path target, ObjectNode value) throws IOException {
        String pendingName = target.getFileName() + "." + UUID.randomUUID()
            + ApiConfigConstants.Readiness.NEXT_SUFFIX;
        Path pending = target.resolveSibling(pendingName);
        try {
            byte[] bytes = AnalysisJson.JSON.writeValueAsBytes(value);
            Files.write(pending, bytes, StandardOpenOption.CREATE_NEW);
            Files.move(pending, target, StandardCopyOption.REPLACE_EXISTING,
                StandardCopyOption.ATOMIC_MOVE);
        } finally {
            Files.deleteIfExists(pending);
        }
    }

    /**
     * 정상 종료 시 같은 폴더로 다음 프로세스가 시작할 수 있게 잠금을 해제한다.
     * @created 2026-11-04
     * @usedBy Spring bean 종료, AnalysisReadinessTest
     */
    @Override
    public void close() throws IOException {
        lock.close();
        channel.close();
    }

    /**
     * 비공개 경로·자격 원문을 예외로 내보내지 않는다.
     * @created 2026-11-04
     * @usedBy AnalysisReadiness
     */
    private static IllegalStateException invalid() {
        return new IllegalStateException(ApiMessageConstants.GammaLocal.PREPARATION_FAILED);
    }
}
