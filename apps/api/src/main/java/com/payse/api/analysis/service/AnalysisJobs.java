package com.payse.api.analysis.service;

import static com.payse.api.analysis.mapper.AnalysisRepository.Table.*;
import static com.payse.api.analysis.service.AnalysisResults.row;
import static com.payse.api.analysis.service.AnalysisResults.time;
import static com.payse.api.analysis.service.AnalysisResults.uuid;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.provider.ModelFailure;
import com.payse.api.analysis.mapper.AnalysisRepository;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialRepository;
import jakarta.annotation.PreDestroy;
import java.time.Clock;
import java.time.Instant;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.function.Function;
import java.util.function.Supplier;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 인증된 분석의 접수·재시도·상태·채택을 짧은 트랜잭션으로 조립한다.
 * @created 2026-11-01
 * @usedBy AnalysisController
 */
@Service
@Profile("database & auth & finance & analysis")
public final class AnalysisJobs {
    private final AuthTransactions transactions;
    private final AuthRepository auth;
    private final AuthCrypto crypto;
    private final FinancialRepository finances;
    private final AnalysisRepository repository;
    private final AnalysisRuntime runtime;
    private final AnalysisResults results;
    private final Clock clock;
    private final AnalysisIdentity identity = new AnalysisIdentity();
    private final AnalysisEvidence evidence = new AnalysisEvidence();
    private final MemoryPolicy retention = new MemoryPolicy();
    private final ExecutorService workers = Executors.newFixedThreadPool(2);

    /**
     * API의 기존 인증·저장소와 요청별 분석 실행 경계를 연결한다.
     * @created 2026-11-01
     * @usedBy Spring 생성자 주입
     */
    public AnalysisJobs(AuthTransactions transactions, AuthRepository auth, AuthCrypto crypto,
            FinancialRepository finances, AnalysisRepository repository, AnalysisRuntime runtime,
            AnalysisResults results, Clock clock) {
        this.transactions = transactions;
        this.auth = auth;
        this.crypto = crypto;
        this.finances = finances;
        this.repository = repository;
        this.runtime = runtime;
        this.results = results;
        this.clock = clock;
    }

    /**
     * 본문 없는 descriptor를 접수한다. recovery만 현재 입력 검증과 기존 결과 재사용을 먼저 한다.
     * @created 2026-11-01
     * @usedBy AnalysisController.accept
     */
    public Reply accept(String token, Supplier<JsonNode> request) {
        return authenticated(token, session -> {
            ObjectNode body = object(request.get());
            fields(body, Set.of("context", "triggerKind", "semanticTaskKind", "items", "inputHashHint",
                "reasonCodes", "idempotencyKey"), Set.of("input", "previousJobId"));
            String trigger = text(body, "triggerKind");
            if (!Set.of("A", "B", "recovery").contains(trigger)) throw invalid();
            validateDescriptor(session.userId(), body);
            String key = key(body);
            String requestHash = commandHash("intake", null, body);
            ObjectNode old = command(session.userId(), key, "intake", requestHash);
            if (old != null) return new Reply(200, status(session.userId(), uuid(old, "job_id")));
            UUID cachedResult = null;
            String cachedHash = null;
            if (trigger.equals("recovery")) {
                UUID previous = parseId(text(body, "previousJobId"));
                ObjectNode previousJob = job(session.userId(), previous);
                if (clock.instant().isBefore(time(previousJob, "guard_expires_at"))) throw conflict();
                ObjectNode input = verified(session.userId(), object(body.get("input")));
                if (!body.path("context").equals(input.path("context"))
                        || !body.path("semanticTaskKind").equals(input.path("semanticTaskKind"))) throw invalid();
                matchItems(body, input);
                if (!identity.hint(input).equals(text(body, "inputHashHint"))) throw invalid();
                AnalysisResults.Selection found = results.select(session.userId(), input, null);
                if (found.state().equals("available")) {
                    cachedResult = uuid(found.header(), "id");
                    cachedHash = identity.boundInputHash(finances.load(session.userId()), input, runtime.versions());
                }
            } else if (body.has("input") || body.has("previousJobId")) throw invalid();
            ObjectNode descriptor = body.deepCopy();
            descriptor.remove(List.of("idempotencyKey", "input", "previousJobId"));
            String descriptorHash = AnalysisJson.digest(descriptor);
            retireExpired(session.userId());
            for (ObjectNode current : repository.find(JOBS, session.userId(), Map.of("descriptor_hash", descriptorHash))) {
                if (live(current)) {
                    remember(session.userId(), key, "intake", requestHash, uuid(current, "id"), null, null,
                        time(current, "guard_expires_at"));
                    return new Reply(200, status(session.userId(), uuid(current, "id")));
                }
            }
            if (cachedResult == null) {
                long[] capacity = repository.capacity(session.userId());
                if (capacity[0] >= 2 || capacity[1] >= 20) throw new FinancialException(429, "RATE_LIMITED");
            }
            Instant now = clock.instant();
            UUID id = UUID.randomUUID();
            ObjectNode stored = row(session.userId(), id).put("semantic_kind", text(body, "semanticTaskKind"))
                .put("trigger_kind", trigger).put("descriptor_hash", descriptorHash).put("accepted_at", now.toString())
                .put("guard_expires_at", retention.normalExpiry(now).toString()).put("state", "queued")
                .put("attempt_count", 0).put("execution_session_id", session.sessionId().toString())
                .put("execution_expires_at", now.plusSeconds(180).toString());
            stored.set("detail", descriptor);
            if (cachedResult != null) stored.put("selected_result_id", cachedResult.toString())
                .put("input_hash", cachedHash).put("state", "succeeded").put("finished_at", now.toString());
            repository.insert(JOBS, session.userId(), stored);
            remember(session.userId(), key, "intake", requestHash, id, null, null, retention.normalExpiry(now));
            return new Reply(cachedResult == null ? 202 : 200, status(session.userId(), id));
        });
    }

    /**
     * 상태 관찰은 모델을 호출하지 않으며 본문은 현재 입력을 검증하는 query에서만 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisController.status
     */
    public Reply read(String token, String id, Runnable requestCheck) {
        return authenticated(token, session -> {
            requestCheck.run();
            return new Reply(200, status(session.userId(), parseId(id)));
        });
    }

    /**
     * 사용자 입력·재시도만 접수하며 중복 요청으로 전송을 늘리지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisController.input, retry
     */
    public Reply submit(String token, String id, boolean retry, Supplier<JsonNode> request) {
        Submission submission = authenticated(token, session -> {
            ObjectNode body = object(request.get());
            fields(body, Set.of("context", "input", "idempotencyKey"), Set.of("permit", "acknowledgeDuplicateRisk"));
            ObjectNode current = job(session.userId(), parseId(id));
            String operation = retry ? "retry" : "input";
            String key = key(body);
            String digest = commandHash(operation, parseId(id), body);
            ObjectNode old = command(session.userId(), key, operation, digest);
            if (old != null) return new Submission(new Reply(200, status(session.userId(), uuid(old, "job_id"))), null);
            if (!clock.instant().isBefore(time(current, "guard_expires_at"))) throw conflict();
            ObjectNode source = finances.load(session.userId());
            ObjectNode input = evidence.verify(session.userId(), source, object(body.get("input")));
            if (!input.path("context").equals(body.path("context"))) throw invalid();
            if (!input.path("semanticTaskKind").asString().equals(current.path("semantic_kind").asString())) throw invalid();
            String hint = identity.hint(input);
            ObjectNode detail = object(current.get("detail"));
            if (!hint.equals(detail.path("inputHashHint").asString())) throw invalid();
            matchItems(detail, input);
            String hash = identity.boundInputHash(source, input, runtime.versions());
            if (current.path("input_hash").isString() && !current.path("input_hash").asString().equals(hash)) {
                throw new FinancialException(409, "STALE_DATA");
            }
            retireExpired(session.userId());
            current = job(session.userId(), parseId(id));
            if (current.path("canonical_job_id").isString()) {
                UUID canonical = uuid(current, "canonical_job_id");
                remember(session.userId(), key, operation, digest, canonical, null, null,
                    time(current, "guard_expires_at"));
                return new Submission(new Reply(200, status(session.userId(), canonical)), null);
            }
            if (current.path("selected_result_id").isString()) {
                remember(session.userId(), key, operation, digest, uuid(current, "id"), null, null,
                    time(current, "guard_expires_at"));
                return new Submission(new Reply(200, status(session.userId(), uuid(current, "id"))), null);
            }
            AnalysisResults.Selection cached = results.select(session.userId(), input, null);
            if (cached.state().equals("available")) {
                selectResult(session.userId(), current, uuid(cached.header(), "id"), hash);
                remember(session.userId(), key, operation, digest, uuid(current, "id"), null, null,
                    time(current, "guard_expires_at"));
                return new Submission(new Reply(200, status(session.userId(), uuid(current, "id"))), null);
            }
            for (ObjectNode running : repository.find(JOBS, session.userId(), Map.of("input_hash", hash))) {
                if (live(running) && running.path("state").asString().equals("running")) {
                    if (!uuid(current, "id").equals(uuid(running, "id"))) {
                        repository.update(JOBS, session.userId(), uuid(current, "id"), AnalysisJson.JSON.createObjectNode()
                            .put("canonical_job_id", running.path("id").asString()).put("input_hash", hash)
                            .put("state", "cancelled").put("finished_at", clock.instant().toString()));
                    }
                    remember(session.userId(), key, operation, digest, uuid(running, "id"), null, null,
                        time(running, "guard_expires_at"));
                    return new Submission(new Reply(200, status(session.userId(), uuid(running, "id"))), null);
                }
            }
            String state = effectiveState(current);
            if (retry) {
                if (!Set.of("failed", "outcomeUnknown", "cancelled").contains(state)) throw conflict();
                if (state.equals("outcomeUnknown") && !body.path("acknowledgeDuplicateRisk").isBoolean()) throw invalid();
                if (state.equals("outcomeUnknown") && !body.path("acknowledgeDuplicateRisk").asBoolean()) throw conflict();
            } else {
                if (!Set.of("queued", "awaitingInput").contains(state)) throw conflict();
                if (!ready(current) || !clock.instant().isBefore(time(current, "execution_expires_at"))) throw conflict();
                if (!current.path("permit_hash").isString() || !body.path("permit").isString()
                        || !body.path("permit").asString().equals(current.path("permit_hash").asString())
                        || !clock.instant().isBefore(time(current, "permit_expires_at"))) throw conflict();
            }
            runtime.requireReady();
            long[] capacity = repository.capacity(session.userId());
            if (capacity[2] >= 1 || capacity[3] >= 2) {
                ObjectNode waiting = status(session.userId(), uuid(current, "id"));
                waiting.put("action", "wait");
                waiting.remove("permit");
                waiting.remove("permitExpiresAt");
                return new Submission(new Reply(200, waiting), null);
            }
            UUID attempt = UUID.randomUUID();
            long count = Math.addExact(current.path("attempt_count").asLong(), 1);
            Instant now = clock.instant();
            ObjectNode row = row(session.userId(), attempt).put("job_id", current.path("id").asString())
                .put("attempt_no", count).put("dispatch_state", "notSent").put("created_at", now.toString());
            repository.insert(ATTEMPTS, session.userId(), row);
            ObjectNode change = AnalysisJson.JSON.createObjectNode().put("state", "running").put("input_hash", hash)
                .put("attempt_count", count).put("execution_session_id", session.sessionId().toString())
                .put("execution_expires_at", (retry ? now.plusSeconds(180) : time(current, "execution_expires_at")).toString());
            change.putNull("finished_at").putNull("permit_expires_at").putNull("permit_hash");
            repository.update(JOBS, session.userId(), uuid(current, "id"), change);
            remember(session.userId(), key, operation, digest, uuid(current, "id"), attempt, null,
                time(current, "guard_expires_at"));
            Work work = new Work(token, session.userId(), uuid(current, "id"), attempt, hash,
                identity.sourceHash(source, input), input);
            return new Submission(new Reply(202, status(session.userId(), uuid(current, "id"))), work);
        });
        if (submission.work() != null) {
            try { workers.execute(() -> execute(submission.work())); }
            catch (java.util.concurrent.RejectedExecutionException rejected) {
                fail(submission.work(), false, "DISPATCH_NOT_STARTED", null);
                throw new FinancialException(503, "TEMPORARILY_UNAVAILABLE");
            }
        }
        return submission.reply();
    }

    /**
     * DB 밖에서 처리하고 저장 전 소유권·관련 원천·삭제를 재검증해 첫 정상 결과만 채택한다.
     * @created 2026-11-01
     * @usedBy submit의 worker
     */
    private void execute(Work work) {
        com.payse.ai.provider.dto.TokenUsage observedUsage = null;
        boolean responseReceived = false;
        try {
            boolean dispatch = authenticated(work.token(), session -> {
                verifyWork(session.userId(), work);
                ObjectNode current = job(session.userId(), work.job());
                ObjectNode attempt = repository.one(ATTEMPTS, session.userId(), Map.of("id", work.attempt())).orElseThrow();
                if (!current.path("state").asString().equals("running")
                        || current.path("selected_result_id").isString()
                        || current.path("attempt_count").asLong() != attempt.path("attempt_no").asLong()
                        || !attempt.path("dispatch_state").asString().equals("notSent")
                        || !clock.instant().isBefore(time(current, "execution_expires_at"))) return false;
                repository.update(ATTEMPTS, session.userId(), work.attempt(), AnalysisJson.JSON.createObjectNode()
                    .put("dispatch_state", "sent"));
                return true;
            });
            if (!dispatch) return;
            AnalysisResult result = runtime.analyze(work.input());
            responseReceived = true;
            observedUsage = result.usage();
            if (result.failure() != null) {
                fail(work, false, result.failure(), result.usage());
                return;
            }
            List<AnalysisResults.Prepared> prepared = results.prepare(work.owner(), work.input(), result);
            authenticated(work.token(), session -> {
                verifyWork(session.userId(), work);
                ObjectNode current = job(session.userId(), work.job());
                if (!clock.instant().isBefore(time(current, "guard_expires_at"))) throw conflict();
                if (current.path("selected_result_id").isNull() || !current.has("selected_result_id")) {
                    AnalysisResults.Selection found = results.select(session.userId(), work.input(), null);
                    UUID chosen = found.state().equals("available") ? uuid(found.header(), "id")
                        : results.save(session.userId(), work.input(), work.hash(), prepared,
                            current.path("trigger_kind").asString().equals("recovery"));
                    selectResult(session.userId(), current, chosen, work.hash());
                }
                ObjectNode settled = AnalysisJson.JSON.createObjectNode().put("dispatch_state", "settled")
                    .put("finished_at", clock.instant().toString());
                ObjectNode usage = settled.putObject("detail").put("usageKnown", result.usage() != null);
                if (result.usage() != null) {
                    usage.put("inputTokens", result.usage().inputTokens()).put("outputTokens", result.usage().outputTokens());
                    if (result.usage().cachedTokens() != null) usage.put("cachedTokens", result.usage().cachedTokens());
                }
                repository.update(ATTEMPTS, session.userId(), work.attempt(), settled);
                return null;
            });
        } catch (ModelFailure failure) {
            fail(work, failure.mayHaveBeenSent(), failure.stage().name(), null);
        } catch (RuntimeException failure) {
            // 정상 응답 이후 저장 실패와 공급자 결과 불명을 구분하며 확인된 사용량은 보존한다.
            fail(work, !responseReceived, responseReceived ? "RESULT_NOT_STORED" : "EXECUTION_UNCONFIRMED", observedUsage);
        }
    }

    /**
     * 실행 실패를 기록하되 이미 채택한 결과와 새 시도를 덮지 않는다. 기록 불가 시 전송 행을 보존한다.
     * @created 2026-11-01
     * @usedBy execute
     */
    private void fail(Work work, boolean unknown, String reason, com.payse.ai.provider.dto.TokenUsage usage) {
        try {
            authenticated(work.token(), session -> {
                ObjectNode attempt = repository.one(ATTEMPTS, session.userId(), Map.of("id", work.attempt())).orElseThrow();
                if (attempt.path("dispatch_state").asString().equals("settled")) return null;
                String dispatch = attempt.path("dispatch_state").asString().equals("notSent") ? "notSent"
                    : unknown ? "outcomeUnknown" : "settled";
                ObjectNode change = AnalysisJson.JSON.createObjectNode().put("dispatch_state", dispatch)
                    .put("finished_at", clock.instant().toString());
                ObjectNode detail = change.putObject("detail").put("reason", reason).put("usageKnown", usage != null);
                if (usage != null) {
                    detail.put("inputTokens", usage.inputTokens()).put("outputTokens", usage.outputTokens());
                    if (usage.cachedTokens() != null) detail.put("cachedTokens", usage.cachedTokens());
                }
                repository.update(ATTEMPTS, session.userId(), work.attempt(), change);
                ObjectNode current = job(session.userId(), work.job());
                if (current.path("state").asString().equals("running")
                        && current.path("attempt_count").asLong() == attempt.path("attempt_no").asLong()) {
                    repository.update(JOBS, session.userId(), work.job(), AnalysisJson.JSON.createObjectNode()
                        .put("state", dispatch.equals("outcomeUnknown") ? "outcomeUnknown" : "failed")
                        .put("finished_at", clock.instant().toString()));
                }
                return null;
            });
        } catch (RuntimeException failure) {
            // DB/인증 장애 시 기존 sent 행이 남으며 deadline 이후 outcomeUnknown으로 관찰한다.
            org.slf4j.LoggerFactory.getLogger(AnalysisJobs.class)
                .warn("Analysis completion was not recorded; persisted dispatch remains unresolved");
        }
    }

    /**
     * 현재 입력으로 결과를 선택하고 복호화 후 자격을 다시 확인하며 조회 중 모델을 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisController.query
     */
    public Reply query(String token, Supplier<JsonNode> request) {
        Read read = authenticated(token, session -> {
            ObjectNode body = object(request.get());
            fields(body, Set.of("context", "semanticTaskKind", "input"), Set.of("resultId"));
            ObjectNode input = verified(session.userId(), object(body.get("input")));
            if (!input.path("context").equals(body.path("context"))
                    || !input.path("semanticTaskKind").equals(body.path("semanticTaskKind"))) throw invalid();
            UUID requested = body.has("resultId") ? parseId(text(body, "resultId")) : null;
            return new Read(session.userId(), input, results.select(session.userId(), input, requested));
        });
        Map<UUID, ObjectNode> plaintext = results.decrypt(read.owner(), read.selection());
        return authenticated(token, session -> {
            verified(session.userId(), read.input());
            UUID selected = read.selection().header() == null ? null : uuid(read.selection().header(), "id");
            AnalysisResults.Selection current = selected == null ? read.selection() : results.select(session.userId(), read.input(), selected);
            return new Reply(200, results.response(read.input(), current, plaintext));
        });
    }

    /**
     * 개별 삭제와 동일 근거의 재보존 차단을 멱등 저장하며 재전송도 사용자 범위를 유지한다.
     * @created 2026-11-01
     * @usedBy AnalysisController.delete
     */
    public void deleteMemory(String token, String item, Supplier<String> requestKey) {
        authenticated(token, session -> {
            UUID id = parseId(item);
            String key = requestKey.get();
            checkKey(key);
            ObjectNode body = AnalysisJson.JSON.createObjectNode().put("itemId", id.toString());
            String digest = commandHash("delete", id, body);
            if (command(session.userId(), key, "delete", digest) != null) return null;
            results.delete(session.userId(), id);
            remember(session.userId(), key, "delete", digest, null, null, id, retention.normalExpiry(clock.instant()));
            return null;
        });
    }

    /**
     * 인증 전에는 본문을 파싱하지 않는다. 무효 토큰도 기존 DB 인증 경계로 문맥을 초기화한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 모든 API·worker 진입점
     */
    private <T> T authenticated(String token, Function<AuthRows.Session, T> operation) {
        return transactions.run(() -> {
            String digest;
            try { digest = crypto.tokenDigest(token); }
            catch (IllegalArgumentException failure) { digest = null; }
            AuthRows.Session session = auth.authorize(digest)
                .orElseThrow(() -> new FinancialException(401, "SESSION_INVALID"));
            cancelOldWaiting(session);
            return operation.apply(session);
        });
    }

    /**
     * 재로그인으로 옛 세션의 대기 허가를 이어받지 않는다. 결과 재조회와 명시 재시도는 별도다.
     * @created 2026-11-01
     * @usedBy authenticated
     */
    private void cancelOldWaiting(AuthRows.Session session) {
        for (String state : List.of("queued", "awaitingInput")) {
            for (ObjectNode pending : repository.find(JOBS, session.userId(), Map.of("state", state))) {
                if (session.sessionId().toString().equals(pending.path("execution_session_id").asString())) continue;
                ObjectNode change = AnalysisJson.JSON.createObjectNode().put("state", "cancelled")
                    .put("finished_at", clock.instant().toString()).putNull("permit_hash").putNull("permit_expires_at");
                repository.update(JOBS, session.userId(), uuid(pending, "id"), change);
            }
        }
    }

    /**
     * 서버 DB의 전체 사용자 원천을 읽되 필요한 공개 근거만 검증하여 AI 입력으로 남긴다.
     * @created 2026-11-01
     * @usedBy submit, query, execute, accept
     */
    private ObjectNode verified(UUID owner, ObjectNode input) { return evidence.verify(owner, finances.load(owner), input); }

    /**
     * 무관한 버전 증가만으로 취소하지 않되 관련 원천·규칙 변경과 연결 해제를 채택 전에 차단한다.
     * @created 2026-11-01
     * @usedBy execute
     */
    private void verifyWork(UUID owner, Work work) {
        ObjectNode source = finances.load(owner);
        if (!identity.sourceHash(source, work.input()).equals(work.basisHash())) {
            throw new FinancialException(409, "STALE_DATA");
        }
        ObjectNode current = work.input().deepCopy();
        ObjectNode context = object(current.get("context"));
        for (String key : List.of("dataVersion", "sourceVersion", "asOf")) context.set(key, source.get(key));
        for (JsonNode candidate : current.path("candidates")) ((ObjectNode) candidate).set("sourceVersion", source.get("sourceVersion"));
        evidence.verify(owner, source, current);
    }

    /**
     * 접수 descriptor는 공개 거래 ID만 사용하며 클라이언트 주장만으로 대기 예외를 승인하지 않는다.
     * @created 2026-11-01
     * @usedBy accept
     */
    private void validateDescriptor(UUID owner, ObjectNode body) {
        if (!Set.of("transactionMeaning", "recurringMeaning").contains(text(body, "semanticTaskKind"))
                || !text(body, "inputHashHint").matches("sha256:[0-9a-f]{64}")
                || !body.path("items").isArray() || body.path("items").isEmpty() || body.path("items").size() > 60
                || !body.path("reasonCodes").isArray() || !body.path("reasonCodes").isEmpty()) throw invalid();
        ObjectNode source = finances.load(owner);
        ObjectNode context = object(body.get("context"));
        for (String version : List.of("dataVersion", "sourceVersion", "ruleVersion", "asOf")) {
            if (!source.path(version).equals(context.path(version))) throw new FinancialException(409, "STALE_DATA");
        }
        Set<String> allIds = new java.util.HashSet<>();
        source.path("transactions").forEach(value -> allIds.add(value.path("transactionId").asString()));
        Set<String> keys = new java.util.HashSet<>();
        for (JsonNode value : body.path("items")) {
            ObjectNode item = object(value);
            fields(item, Set.of("itemKey", "evidenceTransactionIds", "candidateIds"), Set.of());
            if (!keys.add(text(item, "itemKey")) || !item.path("evidenceTransactionIds").isArray()
                    || item.path("evidenceTransactionIds").isEmpty() || item.path("evidenceTransactionIds").size() > 60
                    || !item.path("candidateIds").isArray()) throw invalid();
            for (JsonNode id : item.path("evidenceTransactionIds")) {
                parseId(id.asString());
                if (!allIds.contains(id.asString())) throw new FinancialException(403, "RESOURCE_FORBIDDEN");
            }
            strings(item.path("evidenceTransactionIds"));
            Set<String> candidates = strings(item.path("candidateIds"));
            if (text(body, "semanticTaskKind").equals("transactionMeaning") ? !candidates.isEmpty() : candidates.size() != 1) throw invalid();
        }
        evidence.descriptor(owner, source, body);
    }

    /**
     * 제출 항목과 접수 ID 관계를 대조해 다른 대상으로 바꾸는 요청을 거절한다.
     * @created 2026-11-01
     * @usedBy submit
     */
    private void matchItems(ObjectNode descriptor, ObjectNode input) {
        if (descriptor.path("items").size() != input.path("items").size()) throw invalid();
        for (JsonNode item : input.path("items")) {
            List<JsonNode> found = new java.util.ArrayList<>();
            descriptor.path("items").forEach(old -> { if (old.path("itemKey").equals(item.path("itemKey"))) found.add(old); });
            if (found.size() != 1) throw invalid();
            Set<String> before = strings(found.getFirst().path("evidenceTransactionIds"));
            if (!before.equals(strings(item.path("evidenceTransactionIds")))) throw invalid();
            Set<String> candidates = strings(found.getFirst().path("candidateIds"));
            if (item.path("candidateKey").isNull() ? !candidates.isEmpty()
                : !candidates.equals(Set.of(item.path("candidateKey").asString()))) throw invalid();
        }
    }

    /**
     * 진행 상태와 Q2 조건에 따른 60초 입력 허용 식별을 반환한다. 별도 인증 수단이 아니다.
     * @created 2026-11-01
     * @usedBy read, accept, submit
     */
    private ObjectNode status(UUID owner, UUID id) {
        ObjectNode current = job(owner, id);
        if (current.path("canonical_job_id").isString()) return status(owner, uuid(current, "canonical_job_id"));
        String state = effectiveState(current);
        String action = switch (state) {
            case "succeeded" -> "readResult";
            case "failed", "outcomeUnknown", "cancelled" -> "retry";
            case "expired" -> "refreshInput";
            default -> "wait";
        };
        ObjectNode response = AnalysisJson.JSON.createObjectNode().put("contractVersion", "PAYSE-ANALYSIS-1")
            .put("jobId", id.toString()).put("state", state).put("action", action).put("resultAvailability", "unchecked");
        if (current.path("detail").path("items").isArray()
                && (!current.path("finished_at").isString()
                    || clock.instant().isBefore(time(current, "finished_at").plusSeconds(7L * 86400)))) {
            int accepted = current.path("detail").path("items").size();
            int completed = state.equals("succeeded") ? accepted : 0;
            response.putObject("progress").put("accepted", accepted).put("completed", completed).put("unresolved", accepted - completed);
        }
        if (current.path("selected_result_id").isString()) response.set("resultId", current.get("selected_result_id"));
        if (Set.of("queued", "awaitingInput").contains(state) && ready(current)) {
            if (!current.path("permit_hash").isString() || !clock.instant().isBefore(time(current, "permit_expires_at"))) {
                String permit = AnalysisJson.digest(tools.jackson.databind.node.JsonNodeFactory.instance.textNode(UUID.randomUUID().toString()));
                Instant permitExpiry = clock.instant().plusSeconds(60);
                if (permitExpiry.isAfter(time(current, "execution_expires_at"))) permitExpiry = time(current, "execution_expires_at");
                ObjectNode update = AnalysisJson.JSON.createObjectNode().put("permit_hash", permit)
                    .put("permit_expires_at", permitExpiry.toString()).put("state", "awaitingInput");
                repository.update(JOBS, owner, id, update);
                current.setAll(update);
            }
            response.put("state", "awaitingInput").put("action", "submitInput");
            response.set("permit", current.get("permit_hash"));
            response.set("permitExpiresAt", current.get("permit_expires_at"));
        }
        return response;
    }

    /**
     * 현재 사용자 외의 작업 존재 여부를 같은 403으로 숨긴다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     */
    private ObjectNode job(UUID owner, UUID id) {
        return repository.one(JOBS, owner, Map.of("id", id))
            .orElseThrow(() -> new FinancialException(403, "RESOURCE_FORBIDDEN"));
    }

    /**
     * 만료·결과 불명을 구분하고 옛 토큰이나 자동 재호출로 처리를 재개하지 않는다.
     * @created 2026-11-01
     * @usedBy status, submit
     */
    private String effectiveState(ObjectNode job) {
        if (!clock.instant().isBefore(time(job, "guard_expires_at"))) return "expired";
        String state = job.path("state").asString();
        if (!clock.instant().isBefore(time(job, "execution_expires_at"))) {
            if (state.equals("running")) return "outcomeUnknown";
            if (Set.of("queued", "awaitingInput").contains(state)) return "failed";
        }
        return state;
    }

    /**
     * 확정된 Q2의 10건 또는 60초 조건으로 일반 항목의 실행 준비를 판정한다.
     * @created 2026-11-01
     * @usedBy status, submit
     */
    private boolean ready(ObjectNode job) {
        return job.path("detail").path("items").size() >= 10
            || !clock.instant().isBefore(time(job, "accepted_at").plusSeconds(60));
    }

    /**
     * 종료·만료 상태를 새 진행 작업으로 판단하지 않는다.
     * @created 2026-11-01
     * @usedBy accept, submit
     */
    private boolean live(ObjectNode job) {
        return Set.of("queued", "awaitingInput", "running").contains(effectiveState(job));
    }

    /**
     * 새 쓰기 전 만료된 활성 행을 종료 상태로 옮겨 UNIQUE·용량에 계속 남지 않게 한다.
     * @created 2026-11-01
     * @usedBy accept, submit
     */
    private void retireExpired(UUID owner) {
        for (String state : List.of("queued", "awaitingInput", "running")) {
            for (ObjectNode old : repository.find(JOBS, owner, Map.of("state", state))) {
                String effective = effectiveState(old);
                if (!effective.equals(state)) repository.update(JOBS, owner, uuid(old, "id"),
                    AnalysisJson.JSON.createObjectNode().put("state", effective).put("finished_at", clock.instant().toString()));
            }
        }
    }

    /**
     * 최초 성공 헤더를 고정하며 금융 버전과 원천은 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy execute, submit
     */
    private void selectResult(UUID owner, ObjectNode job, UUID result, String hash) {
        if (job.path("selected_result_id").isString()) {
            if (!uuid(job, "selected_result_id").equals(result)) throw conflict();
            return;
        }
        repository.update(JOBS, owner, uuid(job, "id"), AnalysisJson.JSON.createObjectNode().put("state", "succeeded")
            .put("selected_result_id", result.toString()).put("input_hash", hash).put("finished_at", clock.instant().toString()));
    }

    /**
     * 같은 사용자의 동일 키만 재관찰하고 다른 작업·본문의 재사용은 거절한다.
     * @created 2026-11-01
     * @usedBy accept, submit, deleteMemory
     */
    private ObjectNode command(UUID owner, String key, String operation, String hash) {
        ObjectNode found = repository.one(COMMANDS, owner, Map.of("request_key", key)).orElse(null);
        if (found == null) return null;
        if (!operation.equals(found.path("operation").asString()) || !hash.equals(found.path("request_hash").asString())) throw conflict();
        if (!clock.instant().isBefore(time(found, "expires_at"))) throw conflict();
        return found;
    }

    /**
     * 본문 없는 중복 방지 기록을 고정 기한으로 저장한다.
     * @created 2026-11-01
     * @usedBy accept, submit, deleteMemory
     */
    private void remember(UUID owner, String key, String operation, String hash, UUID job, UUID attempt, UUID item, Instant expiry) {
        ObjectNode row = AnalysisJson.JSON.createObjectNode().put("user_id", owner.toString())
            .put("request_key", key).put("operation", operation).put("request_hash", hash)
            .put("created_at", clock.instant().toString()).put("expires_at", expiry.toString());
        if (job != null) row.put("job_id", job.toString());
        if (attempt != null) row.put("attempt_id", attempt.toString());
        if (item != null) row.put("item_id", item.toString());
        repository.insert(COMMANDS, owner, row);
    }

    /**
     * 세션 갱신으로 별도 효과를 만들지 않고 본문·작업·대상 변경을 구분한다.
     * @created 2026-11-01
     * @usedBy accept, submit, deleteMemory
     */
    private String commandHash(String operation, UUID id, ObjectNode body) {
        ObjectNode copy = body.deepCopy();
        copy.remove("idempotencyKey");
        for (JsonNode context : List.of(copy.path("context"), copy.path("input").path("context"))) {
            if (context instanceof ObjectNode object) object.remove(List.of("localSessionEpoch", "inputRevision"));
        }
        ObjectNode effect = AnalysisJson.JSON.createObjectNode().put("operation", operation);
        if (id != null) effect.put("id", id.toString());
        effect.set("body", copy);
        return AnalysisJson.digest(effect);
    }

    /**
     * 정확히 허용된 필드만 받고 빈 문자열·타입 오류를 검증 실패로 구분한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     */
    private static ObjectNode object(JsonNode value) { if (!(value instanceof ObjectNode object)) throw invalid(); return object; }

    /**
     * 필수 문자열 누락을 임의 기본값으로 대체하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     */
    private static String text(ObjectNode value, String key) {
        if (!value.path(key).isString() || value.path(key).asString().isBlank()) throw invalid();
        return value.path(key).asString();
    }

    /**
     * 허용하지 않은 키를 거절하여 내부 상태 덮어쓰기를 막는다.
     * @created 2026-11-01
     * @usedBy accept, submit, query, validateDescriptor
     */
    private static void fields(ObjectNode body, Set<String> required, Set<String> optional) {
        if (!body.propertyNames().containsAll(required)
                || body.propertyNames().stream().anyMatch(name -> !required.contains(name) && !optional.contains(name))) throw invalid();
    }

    /**
     * 기존 멱등 키 형식을 사용한다.
     * @created 2026-11-01
     * @usedBy accept, submit
     */
    private static String key(ObjectNode body) { String key = text(body, "idempotencyKey"); checkKey(key); return key; }

    /**
     * 요청별 키를 제한하고 공백·제어문자를 허용하지 않는다.
     * @created 2026-11-01
     * @usedBy key, deleteMemory
     */
    private static void checkKey(String key) { if (key == null || !key.matches("[A-Za-z0-9._-]{1,128}")) throw invalid(); }

    /**
     * 표준 UUID만 받고 이름·순서로 대상을 추정하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     */
    private static UUID parseId(String text) {
        try {
            UUID id = UUID.fromString(text);
            if (!id.toString().equals(text)) throw invalid();
            return id;
        } catch (IllegalArgumentException failure) { throw invalid(); }
    }

    /**
     * 근거 집합의 중복을 거절한다.
     * @created 2026-11-01
     * @usedBy matchItems
     */
    private static Set<String> strings(JsonNode values) {
        Set<String> result = new java.util.HashSet<>();
        for (JsonNode value : values) if (!value.isString() || !result.add(value.asString())) throw invalid();
        return result;
    }

    /**
     * 저장 전 업무 검증 실패를 기존 오류로 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     */
    private static FinancialException invalid() { return new FinancialException(422, "VALIDATION_FAILED"); }

    /**
     * 중복 키·상태·기한의 충돌을 성공으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     */
    private static FinancialException conflict() { return new FinancialException(409, "RELATION_CONFLICT"); }

    /**
     * 서버 종료는 새 실행을 막지만 DB의 전송/미확인 기록을 삭제하지 않는다.
     * @created 2026-11-01
     * @usedBy Spring 종료
     */
    @PreDestroy
    public void close() { workers.shutdownNow(); }

    /**
     * HTTP 상태와 이미 검증된 응답의 묶음이다.
     * @created 2026-11-01
     * @usedBy AnalysisController
     */
    public record Reply(int status, ObjectNode body) {
        /**
         * 응답 본문을 디버그 문자열에 노출하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "Reply[status=" + status + ", REDACTED]"; }
    }

    /**
     * 메모리 안에서만 전달하는 작업 입력이다. 토큰·본문을 DB나 로그에 남기지 않는다.
     * @created 2026-11-01
     * @usedBy submit, execute
     */
    private record Work(String token, UUID owner, UUID job, UUID attempt, String hash, String basisHash, ObjectNode input) {
        /**
         * 자동 문자열 표현에 자격·금융 본문을 노출하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "Work[REDACTED]"; }
    }

    /**
     * 커밋 이후에만 작업을 전송하도록 응답과 메모리 작업을 구분한다.
     * @created 2026-11-01
     * @usedBy submit
     */
    private record Submission(Reply reply, Work work) {}

    /**
     * 복호화 전후 인증 트랜잭션을 이어 주되 입력을 저장하지 않는다.
     * @created 2026-11-01
     * @usedBy query
     */
    private record Read(UUID owner, ObjectNode input, AnalysisResults.Selection selection) {
        /**
         * 결과 재검증에 필요한 금융 입력을 문자열로 노출하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "Read[REDACTED]"; }
    }
}
