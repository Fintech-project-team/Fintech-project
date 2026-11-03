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
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants.AnalysisDb;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
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
    public AnalysisJobs(
        AuthTransactions transactions,
        AuthRepository auth,
        AuthCrypto crypto,
        FinancialRepository finances,
        AnalysisRepository repository,
        AnalysisRuntime runtime,
        AnalysisResults results,
        Clock clock
    ) {
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
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    public Reply accept(String token, Supplier<JsonNode> request) {
        return authenticated(
            token,
            session -> {
                ObjectNode body = object(request.get());
                fields(
                    body,
                    Set.of(
                        ApiFieldConstants.Analysis.CONTEXT,
                        ApiFieldConstants.Analysis.TRIGGER_KIND,
                        ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND,
                        ApiFieldConstants.Analysis.ITEMS,
                        ApiFieldConstants.Analysis.INPUT_HASH_HINT,
                        ApiFieldConstants.Analysis.REASON_CODES,
                        ApiFieldConstants.Analysis.IDEMPOTENCY_KEY
                    ),
                    Set.of(
                        ApiFieldConstants.Analysis.INPUT,
                        ApiFieldConstants.Analysis.PREVIOUS_JOB_ID
                    )
                );
                String trigger = text(body, ApiFieldConstants.Analysis.TRIGGER_KIND);
                if (!Set.of(
                    ApiCodeConstants.Analysis.TRIGGER_A,
                    ApiCodeConstants.Analysis.TRIGGER_B,
                    ApiCodeConstants.Analysis.RECOVERY
                ).contains(trigger)) {
                    throw invalid();
                }

                validateDescriptor(session.userId(), body);
                String key = key(body);
                String requestHash = commandHash(ApiCodeConstants.Analysis.INTAKE, null, body);
                ObjectNode old = command(
                    session.userId(),
                    key,
                    ApiCodeConstants.Analysis.INTAKE,
                    requestHash
                );
                if (old != null) {
                    return new Reply(200, status(session.userId(), uuid(old, AnalysisDb.JOB_ID)));
                }

                UUID cachedResult = null;
                String cachedHash = null;
                if (trigger.equals(ApiCodeConstants.Analysis.RECOVERY)) {
                    UUID previous = parseId(text(body, ApiFieldConstants.Analysis.PREVIOUS_JOB_ID));
                    ObjectNode previousJob = job(session.userId(), previous);
                    if (clock.instant().isBefore(time(previousJob, AnalysisDb.GUARD_EXPIRES_AT))) {
                        throw conflict();
                    }

                    ObjectNode input = verified(
                        session.userId(),
                        object(body.get(ApiFieldConstants.Analysis.INPUT))
                    );
                    if (!body.path(ApiFieldConstants.Analysis.CONTEXT)
                        .equals(input.path(ApiFieldConstants.Analysis.CONTEXT))
                        || !body.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND)
                            .equals(input.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND))) {
                        throw invalid();
                    }

                    matchItems(body, input);
                    if (!identity.hint(input)
                        .equals(text(body, ApiFieldConstants.Analysis.INPUT_HASH_HINT))) {
                        throw invalid();
                    }

                    AnalysisResults.Selection found = results.select(session.userId(), input, null);
                    if (found.state().equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                        cachedResult = uuid(found.header(), AnalysisDb.ID);
                        cachedHash = identity
                            .boundInputHash(
                                finances.load(session.userId()),
                                input,
                                runtime.versions()
                            );
                    }
                } else if (body.has(ApiFieldConstants.Analysis.INPUT)
                    || body.has(ApiFieldConstants.Analysis.PREVIOUS_JOB_ID)) {
                    throw invalid();
                }

                ObjectNode descriptor = body.deepCopy();
                descriptor.remove(
                    List.of(
                        ApiFieldConstants.Analysis.IDEMPOTENCY_KEY,
                        ApiFieldConstants.Analysis.INPUT,
                        ApiFieldConstants.Analysis.PREVIOUS_JOB_ID
                    )
                );
                String descriptorHash = AnalysisJson.digest(descriptor);
                retireExpired(session.userId());
                List<ObjectNode> matchingJobs = repository
                    .find(
                        JOBS,
                        session.userId(),
                        Map.of(AnalysisDb.DESCRIPTOR_HASH, descriptorHash)
                    );
                for (ObjectNode current : matchingJobs) {
                    if (live(current)) {
                        remember(
                            session.userId(),
                            key,
                            ApiCodeConstants.Analysis.INTAKE,
                            requestHash,
                            uuid(current, AnalysisDb.ID),
                            null,
                            null,
                            time(current, AnalysisDb.GUARD_EXPIRES_AT)
                        );
                        return new Reply(
                            200,
                            status(session.userId(), uuid(current, AnalysisDb.ID))
                        );
                    }
                }

                if (cachedResult == null) {
                    long[] capacity = repository.capacity(session.userId());
                    if (capacity[0] >= 2 || capacity[1] >= 20) {
                        throw new FinancialException(429, ApiCodeConstants.Analysis.RATE_LIMITED);
                    }
                }

                Instant now = clock.instant();
                UUID id = UUID.randomUUID();
                ObjectNode stored = row(session.userId(), id)
                    .put(
                        AnalysisDb.SEMANTIC_KIND,
                        text(body, ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND)
                    )
                    .put(AnalysisDb.TRIGGER_KIND, trigger)
                    .put(AnalysisDb.DESCRIPTOR_HASH, descriptorHash)
                    .put(AnalysisDb.ACCEPTED_AT, now.toString())
                    .put(AnalysisDb.GUARD_EXPIRES_AT, retention.normalExpiry(now).toString())
                    .put(ApiFieldConstants.Analysis.STATE, ApiCodeConstants.Analysis.QUEUED)
                    .put(AnalysisDb.ATTEMPT_COUNT, 0)
                    .put(AnalysisDb.EXECUTION_SESSION_ID, session.sessionId().toString())
                    .put(AnalysisDb.EXECUTION_EXPIRES_AT, now.plusSeconds(180).toString());
                stored.set(ApiFieldConstants.Analysis.DETAIL, descriptor);
                if (cachedResult != null) {
                    stored.put(AnalysisDb.SELECTED_RESULT_ID, cachedResult.toString())
                        .put(AnalysisDb.INPUT_HASH, cachedHash)
                        .put(ApiFieldConstants.Analysis.STATE, ApiCodeConstants.Analysis.SUCCEEDED)
                        .put(AnalysisDb.FINISHED_AT, now.toString());
                }

                repository.insert(JOBS, session.userId(), stored);
                remember(
                    session.userId(),
                    key,
                    ApiCodeConstants.Analysis.INTAKE,
                    requestHash,
                    id,
                    null,
                    null,
                    retention.normalExpiry(now)
                );
                return new Reply(cachedResult == null ? 202 : 200, status(session.userId(), id));
            }
        );
    }

    /**
     * 상태 관찰은 모델을 호출하지 않으며 본문은 현재 입력을 검증하는 query에서만 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisController.status
     */
    public Reply read(String token, String id, Runnable requestCheck) {
        return authenticated(
            token,
            session -> {
                requestCheck.run();
                return new Reply(200, status(session.userId(), parseId(id)));
            }
        );
    }

    /**
     * 사용자 입력·재시도만 접수하며 중복 요청으로 전송을 늘리지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisController.input, retry
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-03 - 분석 시도와 비용 예약을 원자 접수하고 DB 원천을 별도 투영
     */
    public Reply submit(String token, String id, boolean retry, Supplier<JsonNode> request) {
        Submission submission = authenticated(
            token,
            session -> {
                ObjectNode body = object(request.get());
                fields(
                    body,
                    Set.of(
                        ApiFieldConstants.Analysis.CONTEXT,
                        ApiFieldConstants.Analysis.INPUT,
                        ApiFieldConstants.Analysis.IDEMPOTENCY_KEY
                    ),
                    Set.of(
                        ApiFieldConstants.Analysis.PERMIT,
                        ApiFieldConstants.Analysis.ACKNOWLEDGE_DUPLICATE_RISK
                    )
                );
                ObjectNode current = job(session.userId(), parseId(id));
                String operation = retry ? ApiCodeConstants.Analysis.RETRY
                    : ApiCodeConstants.Analysis.INPUT_OPERATION;
                String key = key(body);
                String digest = commandHash(operation, parseId(id), body);
                ObjectNode old = command(session.userId(), key, operation, digest);
                if (old != null) {
                    return new Submission(
                        new Reply(200, status(session.userId(), uuid(old, AnalysisDb.JOB_ID))),
                        null
                    );
                }
                if (!clock.instant().isBefore(time(current, AnalysisDb.GUARD_EXPIRES_AT))) {
                    throw conflict();
                }

                ObjectNode source = finances.load(session.userId());
                ObjectNode input = evidence.verify(
                    session.userId(),
                    source,
                    object(body.get(ApiFieldConstants.Analysis.INPUT))
                );
                if (!input.path(ApiFieldConstants.Analysis.CONTEXT)
                    .equals(body.path(ApiFieldConstants.Analysis.CONTEXT))) {
                    throw invalid();
                }
                if (!input.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND)
                    .asString()
                    .equals(current.path(AnalysisDb.SEMANTIC_KIND).asString())) {
                    throw invalid();
                }

                String hint = identity.hint(input);
                ObjectNode detail = object(current.get(ApiFieldConstants.Analysis.DETAIL));
                if (!hint
                    .equals(detail.path(ApiFieldConstants.Analysis.INPUT_HASH_HINT).asString())) {
                    throw invalid();
                }

                matchItems(detail, input);
                String hash = identity.boundInputHash(source, input, runtime.versions());
                if (current.path(AnalysisDb.INPUT_HASH).isString()
                    && !current.path(AnalysisDb.INPUT_HASH)
                        .asString()
                        .equals(hash)) {
                    throw new FinancialException(409, ApiCodeConstants.Analysis.STALE_DATA);
                }

                retireExpired(session.userId());
                current = job(session.userId(), parseId(id));
                if (current.path(AnalysisDb.CANONICAL_JOB_ID).isString()) {
                    UUID canonical = uuid(current, AnalysisDb.CANONICAL_JOB_ID);
                    remember(
                        session.userId(),
                        key,
                        operation,
                        digest,
                        canonical,
                        null,
                        null,
                        time(current, AnalysisDb.GUARD_EXPIRES_AT)
                    );
                    return new Submission(
                        new Reply(200, status(session.userId(), canonical)),
                        null
                    );
                }
                if (current.path(AnalysisDb.SELECTED_RESULT_ID).isString()) {
                    remember(
                        session.userId(),
                        key,
                        operation,
                        digest,
                        uuid(current, AnalysisDb.ID),
                        null,
                        null,
                        time(current, AnalysisDb.GUARD_EXPIRES_AT)
                    );
                    return new Submission(
                        new Reply(200, status(session.userId(), uuid(current, AnalysisDb.ID))),
                        null
                    );
                }
                AnalysisResults.Selection cached = results.select(session.userId(), input, null);
                if (cached.state().equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                    selectResult(
                        session.userId(),
                        current,
                        uuid(cached.header(), AnalysisDb.ID),
                        hash
                    );
                    remember(
                        session.userId(),
                        key,
                        operation,
                        digest,
                        uuid(current, AnalysisDb.ID),
                        null,
                        null,
                        time(current, AnalysisDb.GUARD_EXPIRES_AT)
                    );
                    return new Submission(
                        new Reply(200, status(session.userId(), uuid(current, AnalysisDb.ID))),
                        null
                    );
                }
                List<ObjectNode> matchingInputs = repository
                    .find(JOBS, session.userId(), Map.of(AnalysisDb.INPUT_HASH, hash));
                for (ObjectNode running : matchingInputs) {
                    if (live(running) && running.path(ApiFieldConstants.Analysis.STATE)
                        .asString()
                        .equals(ApiCodeConstants.Analysis.RUNNING)) {
                        if (!uuid(current, AnalysisDb.ID).equals(uuid(running, AnalysisDb.ID))) {
                            repository.update(
                                JOBS,
                                session.userId(),
                                uuid(current, AnalysisDb.ID),
                                AnalysisJson.JSON.createObjectNode()
                                    .put(
                                        AnalysisDb.CANONICAL_JOB_ID,
                                        running.path(AnalysisDb.ID).asString()
                                    )
                                    .put(AnalysisDb.INPUT_HASH, hash)
                                    .put(
                                        ApiFieldConstants.Analysis.STATE,
                                        ApiCodeConstants.Analysis.CANCELLED
                                    )
                                    .put(AnalysisDb.FINISHED_AT, clock.instant().toString())
                            );
                        }

                        remember(
                            session.userId(),
                            key,
                            operation,
                            digest,
                            uuid(running, AnalysisDb.ID),
                            null,
                            null,
                            time(running, AnalysisDb.GUARD_EXPIRES_AT)
                        );
                        return new Submission(
                            new Reply(200, status(session.userId(), uuid(running, AnalysisDb.ID))),
                            null
                        );
                    }
                }

                String state = effectiveState(current);
                if (retry) {
                    if (!Set.of(
                        ApiCodeConstants.Analysis.FAILED,
                        ApiCodeConstants.Analysis.OUTCOME_UNKNOWN,
                        ApiCodeConstants.Analysis.CANCELLED
                    ).contains(state)) {
                        throw conflict();
                    }
                    if (state.equals(ApiCodeConstants.Analysis.OUTCOME_UNKNOWN)
                        && !body.path(ApiFieldConstants.Analysis.ACKNOWLEDGE_DUPLICATE_RISK)
                            .isBoolean()) {
                        throw invalid();
                    }
                    if (state.equals(ApiCodeConstants.Analysis.OUTCOME_UNKNOWN)
                        && !body.path(ApiFieldConstants.Analysis.ACKNOWLEDGE_DUPLICATE_RISK)
                            .asBoolean()) {
                        throw conflict();
                    }
                } else {
                    if (!Set
                        .of(
                            ApiCodeConstants.Analysis.QUEUED,
                            ApiCodeConstants.Analysis.AWAITING_INPUT
                        )
                        .contains(state)) {
                        throw conflict();
                    }
                    if (!ready(current)
                        || !clock.instant()
                            .isBefore(time(current, AnalysisDb.EXECUTION_EXPIRES_AT))) {
                        throw conflict();
                    }
                    if (!current.path(AnalysisDb.PERMIT_HASH).isString()
                        || !body.path(ApiFieldConstants.Analysis.PERMIT).isString()
                        || !body.path(ApiFieldConstants.Analysis.PERMIT)
                            .asString()
                            .equals(current.path(AnalysisDb.PERMIT_HASH).asString())
                        || !clock.instant().isBefore(time(current, AnalysisDb.PERMIT_EXPIRES_AT))) {
                        throw conflict();
                    }
                }
                runtime.requireReady();
                long[] capacity = repository.capacity(session.userId());
                if (capacity[2] >= 1 || capacity[3] >= 2) {
                    ObjectNode waiting = status(session.userId(), uuid(current, AnalysisDb.ID));
                    waiting.put(ApiFieldConstants.Analysis.ACTION, ApiCodeConstants.Analysis.WAIT);
                    waiting.remove(ApiFieldConstants.Analysis.PERMIT);
                    waiting.remove(ApiFieldConstants.Analysis.PERMIT_EXPIRES_AT);
                    return new Submission(new Reply(200, waiting), null);
                }
                UUID attempt = UUID.randomUUID();
                long count = Math.addExact(current.path(AnalysisDb.ATTEMPT_COUNT).asLong(), 1);
                Instant now = clock.instant();
                ObjectNode row = row(session.userId(), attempt)
                    .put(AnalysisDb.JOB_ID, current.path(AnalysisDb.ID).asString())
                    .put(AnalysisDb.ATTEMPT_NO, count)
                    .put(AnalysisDb.DISPATCH_STATE, ApiCodeConstants.Analysis.NOT_SENT)
                    .put(AnalysisDb.CREATED_AT, now.toString());
                repository.insert(ATTEMPTS, session.userId(), row);
                runtime.reserve(attempt);
                ObjectNode change = AnalysisJson.JSON.createObjectNode()
                    .put(ApiFieldConstants.Analysis.STATE, ApiCodeConstants.Analysis.RUNNING)
                    .put(AnalysisDb.INPUT_HASH, hash)
                    .put(AnalysisDb.ATTEMPT_COUNT, count)
                    .put(AnalysisDb.EXECUTION_SESSION_ID, session.sessionId().toString())
                    .put(
                        AnalysisDb.EXECUTION_EXPIRES_AT,
                        (retry ? now.plusSeconds(180)
                            : time(current, AnalysisDb.EXECUTION_EXPIRES_AT))
                            .toString()
                    );
                change.putNull(AnalysisDb.FINISHED_AT)
                    .putNull(AnalysisDb.PERMIT_EXPIRES_AT)
                    .putNull(AnalysisDb.PERMIT_HASH);

                repository.update(JOBS, session.userId(), uuid(current, AnalysisDb.ID), change);
                remember(
                    session.userId(),
                    key,
                    operation,
                    digest,
                    uuid(current, AnalysisDb.ID),
                    attempt,
                    null,
                    time(current, AnalysisDb.GUARD_EXPIRES_AT)
                );
                Work work = new Work(
                    token,
                    session.userId(),
                    uuid(current, AnalysisDb.ID),
                    attempt,
                    hash,
                    identity.sourceHash(source, input),
                    input,
                    evidence.modelFacts(session.userId(), source, input)
                );
                return new Submission(
                    new Reply(202, status(session.userId(), uuid(current, AnalysisDb.ID))),
                    work
                );
            }
        );
        if (submission.work() != null) {
            try {
                workers.execute(() -> execute(submission.work()));
            } catch (java.util.concurrent.RejectedExecutionException rejected) {
                runtime.cancel(submission.work().attempt());
                fail(
                    submission.work(),
                    false,
                    ApiCodeConstants.Analysis.DISPATCH_NOT_STARTED,
                    null
                );
                throw new FinancialException(
                    503,
                    ApiCodeConstants.Analysis.TEMPORARILY_UNAVAILABLE
                );
            }
        }
        return submission.reply();
    }

    /**
     * DB 밖에서 처리하고 저장 전 소유권·관련 원천·삭제를 재검증해 첫 정상 결과만 채택한다.
     * @created 2026-11-01
     * @usedBy submit의 worker
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-03 - 비용을 독립 정산하는 실행 경계와 전송 전 예약 취소 연결
     */
    private void execute(Work work) {
        com.payse.ai.provider.dto.TokenUsage observedUsage = null;
        boolean responseReceived = false;
        boolean runtimeEntered = false;
        try {
            boolean dispatch = authenticated(
                work.token(),
                session -> {
                    verifyWork(session.userId(), work);
                    ObjectNode current = job(session.userId(), work.job());
                    ObjectNode attempt = repository
                        .one(ATTEMPTS, session.userId(), Map.of(AnalysisDb.ID, work.attempt()))
                        .orElseThrow();
                    if (!current.path(ApiFieldConstants.Analysis.STATE)
                        .asString()
                        .equals(ApiCodeConstants.Analysis.RUNNING)
                        || current.path(AnalysisDb.SELECTED_RESULT_ID).isString()
                        || current.path(AnalysisDb.ATTEMPT_COUNT)
                            .asLong() != attempt.path(AnalysisDb.ATTEMPT_NO).asLong()
                        || !attempt.path(AnalysisDb.DISPATCH_STATE)
                            .asString()
                            .equals(ApiCodeConstants.Analysis.NOT_SENT)
                        || !clock.instant()
                            .isBefore(time(current, AnalysisDb.EXECUTION_EXPIRES_AT))) {
                        return false;
                    }

                    repository.update(
                        ATTEMPTS,
                        session.userId(),
                        work.attempt(),
                        AnalysisJson.JSON.createObjectNode()
                            .put(AnalysisDb.DISPATCH_STATE, ApiCodeConstants.Analysis.SENT)
                    );
                    return true;
                }
            );
            if (!dispatch) {
                return;
            }

            runtimeEntered = true;
            AnalysisResult result = runtime.analyze(
                work.attempt(),
                work.input(),
                work.modelFacts()
            );
            responseReceived = true;
            observedUsage = result.usage();
            if (result.failure() != null) {
                fail(work, false, result.failure(), result.usage());
                return;
            }
            List<AnalysisResults.Prepared> prepared = results
                .prepare(work.owner(), work.input(), result);
            authenticated(
                work.token(),
                session -> {
                    verifyWork(session.userId(), work);
                    ObjectNode current = job(session.userId(), work.job());
                    if (!clock.instant().isBefore(time(current, AnalysisDb.GUARD_EXPIRES_AT))) {
                        throw conflict();
                    }

                    if (current.path(AnalysisDb.SELECTED_RESULT_ID).isNull()
                        || !current.has(AnalysisDb.SELECTED_RESULT_ID)) {
                        AnalysisResults.Selection found = results
                            .select(session.userId(), work.input(), null);
                        UUID chosen = found.state().equals(ApiCodeConstants.Analysis.AVAILABLE)
                            ? uuid(found.header(), AnalysisDb.ID)
                            : results.save(
                                session.userId(),
                                work.input(),
                                work.hash(),
                                prepared,
                                current.path(AnalysisDb.TRIGGER_KIND)
                                    .asString()
                                    .equals(ApiCodeConstants.Analysis.RECOVERY)
                            );
                        selectResult(session.userId(), current, chosen, work.hash());
                    }
                    ObjectNode settled = AnalysisJson.JSON.createObjectNode()
                        .put(AnalysisDb.DISPATCH_STATE, ApiCodeConstants.Analysis.SETTLED)
                        .put(AnalysisDb.FINISHED_AT, clock.instant().toString());
                    ObjectNode usage = settled.putObject(ApiFieldConstants.Analysis.DETAIL)
                        .put(ApiFieldConstants.Analysis.USAGE_KNOWN, result.usage() != null);
                    if (result.usage() != null) {
                        usage
                            .put(
                                ApiFieldConstants.Analysis.INPUT_TOKENS,
                                result.usage().inputTokens()
                            )
                            .put(
                                ApiFieldConstants.Analysis.OUTPUT_TOKENS,
                                result.usage().outputTokens()
                            );
                        if (result.usage().cachedTokens() != null) {
                            usage.put(
                                ApiFieldConstants.Analysis.CACHED_TOKENS,
                                result.usage().cachedTokens()
                            );
                        }
                    }

                    repository.update(ATTEMPTS, session.userId(), work.attempt(), settled);
                    return null;
                }
            );
        } catch (ModelFailure failure) {
            fail(work, failure.mayHaveBeenSent(), failure.stage().name(), null);
        } catch (RuntimeException failure) {
            // 정상 응답 이후 저장 실패와 공급자 결과 불명을 구분하며 확인된 사용량은 보존한다.
            fail(
                work,
                !responseReceived,
                responseReceived ? ApiCodeConstants.Analysis.RESULT_NOT_STORED
                    : ApiCodeConstants.Analysis.EXECUTION_UNCONFIRMED,
                observedUsage
            );
        } finally {
            if (!runtimeEntered) {
                runtime.cancel(work.attempt());
            }
        }
    }

    /**
     * 실행 실패를 기록하되 이미 채택한 결과와 새 시도를 덮지 않는다. 기록 불가 시 전송 행을 보존한다.
     * @created 2026-11-01
     * @usedBy execute
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private void fail(
        Work work,
        boolean unknown,
        String reason,
        com.payse.ai.provider.dto.TokenUsage usage
    ) {
        try {
            authenticated(
                work.token(),
                session -> {
                    ObjectNode attempt = repository
                        .one(ATTEMPTS, session.userId(), Map.of(AnalysisDb.ID, work.attempt()))
                        .orElseThrow();
                    if (attempt.path(AnalysisDb.DISPATCH_STATE)
                        .asString()
                        .equals(ApiCodeConstants.Analysis.SETTLED)) {
                        return null;
                    }

                    String dispatch = attempt.path(AnalysisDb.DISPATCH_STATE)
                        .asString()
                        .equals(ApiCodeConstants.Analysis.NOT_SENT)
                            ? ApiCodeConstants.Analysis.NOT_SENT
                            : unknown ? ApiCodeConstants.Analysis.OUTCOME_UNKNOWN
                                : ApiCodeConstants.Analysis.SETTLED;
                    ObjectNode change = AnalysisJson.JSON.createObjectNode()
                        .put(AnalysisDb.DISPATCH_STATE, dispatch)
                        .put(AnalysisDb.FINISHED_AT, clock.instant().toString());
                    ObjectNode detail = change.putObject(ApiFieldConstants.Analysis.DETAIL)
                        .put(ApiFieldConstants.Analysis.REASON, reason)
                        .put(ApiFieldConstants.Analysis.USAGE_KNOWN, usage != null);
                    if (usage != null) {
                        detail.put(ApiFieldConstants.Analysis.INPUT_TOKENS, usage.inputTokens())
                            .put(ApiFieldConstants.Analysis.OUTPUT_TOKENS, usage.outputTokens());
                        if (usage.cachedTokens() != null) {
                            detail.put(
                                ApiFieldConstants.Analysis.CACHED_TOKENS,
                                usage.cachedTokens()
                            );
                        }
                    }

                    repository.update(ATTEMPTS, session.userId(), work.attempt(), change);
                    ObjectNode current = job(session.userId(), work.job());
                    if (current.path(ApiFieldConstants.Analysis.STATE)
                        .asString()
                        .equals(ApiCodeConstants.Analysis.RUNNING)
                        && current.path(AnalysisDb.ATTEMPT_COUNT)
                            .asLong() == attempt.path(AnalysisDb.ATTEMPT_NO).asLong()) {
                        repository.update(
                            JOBS,
                            session.userId(),
                            work.job(),
                            AnalysisJson.JSON.createObjectNode()
                                .put(
                                    ApiFieldConstants.Analysis.STATE,
                                    dispatch.equals(ApiCodeConstants.Analysis.OUTCOME_UNKNOWN)
                                        ? ApiCodeConstants.Analysis.OUTCOME_UNKNOWN
                                        : ApiCodeConstants.Analysis.FAILED
                                )
                                .put(AnalysisDb.FINISHED_AT, clock.instant().toString())
                        );
                    }
                    return null;
                }
            );
        } catch (RuntimeException failure) {
            // DB/인증 장애 시 기존 sent 행이 남으며 deadline 이후 outcomeUnknown으로 관찰한다.
            org.slf4j.LoggerFactory.getLogger(AnalysisJobs.class)
                .warn(ApiMessageConstants.Analysis.COMPLETION_UNRECORDED);
        }
    }

    /**
     * 현재 입력으로 결과를 선택하고 복호화 후 자격을 다시 확인하며 조회 중 모델을 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisController.query
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    public Reply query(String token, Supplier<JsonNode> request) {
        Read read = authenticated(
            token,
            session -> {
                ObjectNode body = object(request.get());
                fields(
                    body,
                    Set.of(
                        ApiFieldConstants.Analysis.CONTEXT,
                        ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND,
                        ApiFieldConstants.Analysis.INPUT
                    ),
                    Set.of(ApiFieldConstants.Analysis.RESULT_ID)
                );
                ObjectNode input = verified(
                    session.userId(),
                    object(body.get(ApiFieldConstants.Analysis.INPUT))
                );
                if (!input.path(ApiFieldConstants.Analysis.CONTEXT)
                    .equals(body.path(ApiFieldConstants.Analysis.CONTEXT))
                    || !input.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND)
                        .equals(body.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND))) {
                    throw invalid();
                }

                UUID requested = body.has(ApiFieldConstants.Analysis.RESULT_ID)
                    ? parseId(text(body, ApiFieldConstants.Analysis.RESULT_ID))
                    : null;
                return new Read(
                    session.userId(),
                    input,
                    results.select(session.userId(), input, requested)
                );
            }
        );

        Map<UUID, ObjectNode> plaintext = results.decrypt(read.owner(), read.selection());

        return authenticated(
            token,
            session -> {
                verified(session.userId(), read.input());
                UUID selected = read.selection().header() == null ? null
                    : uuid(read.selection().header(), AnalysisDb.ID);
                AnalysisResults.Selection current = selected == null ? read.selection()
                    : results.select(session.userId(), read.input(), selected);
                return new Reply(200, results.response(read.input(), current, plaintext));
            }
        );
    }

    /**
     * 개별 삭제와 동일 근거의 재보존 차단을 멱등 저장하며 재전송도 사용자 범위를 유지한다.
     * @created 2026-11-01
     * @usedBy AnalysisController.delete
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    public void deleteMemory(String token, String item, Supplier<String> requestKey) {
        authenticated(
            token,
            session -> {
                UUID id = parseId(item);
                String key = requestKey.get();
                checkKey(key);
                ObjectNode body = AnalysisJson.JSON.createObjectNode()
                    .put(ApiFieldConstants.Analysis.ITEM_ID, id.toString());
                String digest = commandHash(ApiCodeConstants.Analysis.DELETE, id, body);
                if (command(
                    session.userId(),
                    key,
                    ApiCodeConstants.Analysis.DELETE,
                    digest
                ) != null) {
                    return null;
                }

                results.delete(session.userId(), id);

                remember(
                    session.userId(),
                    key,
                    ApiCodeConstants.Analysis.DELETE,
                    digest,
                    null,
                    null,
                    id,
                    retention.normalExpiry(clock.instant())
                );
                return null;
            }
        );
    }

    /**
     * 인증 전에는 본문을 파싱하지 않는다. 무효 토큰도 기존 DB 인증 경계로 문맥을 초기화한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 모든 API·worker 진입점
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private <T> T authenticated(String token, Function<AuthRows.Session, T> operation) {
        return transactions.run(
            () -> {
                String digest;
                try {
                    digest = crypto.tokenDigest(token);
                } catch (IllegalArgumentException failure) {
                    digest = null;
                }

                AuthRows.Session session = auth.authorize(digest)
                    .orElseThrow(
                        () -> new FinancialException(401, ApiCodeConstants.Analysis.SESSION_INVALID)
                    );
                cancelOldWaiting(session);
                return operation.apply(session);
            }
        );
    }

    /**
     * 재로그인으로 옛 세션의 대기 허가를 이어받지 않는다. 결과 재조회와 명시 재시도는 별도다.
     * @created 2026-11-01
     * @usedBy authenticated
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private void cancelOldWaiting(AuthRows.Session session) {
        for (String state : List
            .of(ApiCodeConstants.Analysis.QUEUED, ApiCodeConstants.Analysis.AWAITING_INPUT)) {
            List<ObjectNode> waitingJobs = repository
                .find(JOBS, session.userId(), Map.of(ApiFieldConstants.Analysis.STATE, state));
            for (ObjectNode pending : waitingJobs) {
                if (session.sessionId()
                    .toString()
                    .equals(pending.path(AnalysisDb.EXECUTION_SESSION_ID).asString())) {
                    continue;
                }

                ObjectNode change = AnalysisJson.JSON.createObjectNode()
                    .put(ApiFieldConstants.Analysis.STATE, ApiCodeConstants.Analysis.CANCELLED)
                    .put(AnalysisDb.FINISHED_AT, clock.instant().toString())
                    .putNull(AnalysisDb.PERMIT_HASH)
                    .putNull(AnalysisDb.PERMIT_EXPIRES_AT);
                repository.update(JOBS, session.userId(), uuid(pending, AnalysisDb.ID), change);
            }
        }
    }

    /**
     * 서버 DB의 전체 사용자 원천을 읽되 필요한 공개 근거만 검증하여 AI 입력으로 남긴다.
     * @created 2026-11-01
     * @usedBy submit, query, execute, accept
     */
    private ObjectNode verified(UUID owner, ObjectNode input) {
        return evidence.verify(owner, finances.load(owner), input);
    }

    /**
     * 무관한 버전 증가만으로 취소하지 않되 관련 원천·규칙 변경과 연결 해제를 채택 전에 차단한다.
     * @created 2026-11-01
     * @usedBy execute
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private void verifyWork(UUID owner, Work work) {
        ObjectNode source = finances.load(owner);
        if (!identity.sourceHash(source, work.input()).equals(work.basisHash())) {
            throw new FinancialException(409, ApiCodeConstants.Analysis.STALE_DATA);
        }

        ObjectNode current = work.input().deepCopy();
        ObjectNode context = object(current.get(ApiFieldConstants.Analysis.CONTEXT));
        var contextFields = List.of(
            ApiFieldConstants.Analysis.DATA_VERSION,
            ApiFieldConstants.Analysis.SOURCE_VERSION,
            ApiFieldConstants.Analysis.AS_OF
        );
        for (String key : contextFields) {
            context.set(key, source.get(key));
        }
        for (JsonNode candidate : current.path(ApiFieldConstants.Analysis.CANDIDATES)) {
            ((ObjectNode) candidate).set(
                ApiFieldConstants.Analysis.SOURCE_VERSION,
                source.get(ApiFieldConstants.Analysis.SOURCE_VERSION)
            );
        }

        evidence.verify(owner, source, current);
    }

    /**
     * 접수 descriptor는 공개 거래 ID만 사용하며 클라이언트 주장만으로 대기 예외를 승인하지 않는다.
     * @created 2026-11-01
     * @usedBy accept
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 단일 제어문 본문 중괄호 명시
     */
    private void validateDescriptor(UUID owner, ObjectNode body) {
        if (!Set
            .of(
                ApiCodeConstants.Analysis.TRANSACTION_MEANING,
                ApiCodeConstants.Analysis.RECURRING_MEANING
            )
            .contains(text(body, ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND))
            || !text(body, ApiFieldConstants.Analysis.INPUT_HASH_HINT)
                .matches("sha256:[0-9a-f]{64}")
            || !body.path(ApiFieldConstants.Analysis.ITEMS).isArray()
            || body.path(ApiFieldConstants.Analysis.ITEMS).isEmpty()
            || body.path(ApiFieldConstants.Analysis.ITEMS).size() > 60
            || !body.path(ApiFieldConstants.Analysis.REASON_CODES).isArray()
            || !body.path(ApiFieldConstants.Analysis.REASON_CODES).isEmpty()) {
            throw invalid();
        }

        ObjectNode source = finances.load(owner);
        ObjectNode context = object(body.get(ApiFieldConstants.Analysis.CONTEXT));
        var versionFields = List.of(
            ApiFieldConstants.Analysis.DATA_VERSION,
            ApiFieldConstants.Analysis.SOURCE_VERSION,
            ApiFieldConstants.Analysis.RULE_VERSION,
            ApiFieldConstants.Analysis.AS_OF
        );
        for (String version : versionFields) {
            if (!source.path(version).equals(context.path(version))) {
                throw new FinancialException(409, ApiCodeConstants.Analysis.STALE_DATA);
            }
        }

        Set<String> allIds = new java.util.HashSet<>();
        source.path(ApiFieldConstants.Analysis.TRANSACTIONS)
            .forEach(
                value -> allIds
                    .add(value.path(ApiFieldConstants.Analysis.TRANSACTION_ID).asString())
            );
        Set<String> keys = new java.util.HashSet<>();
        for (JsonNode value : body.path(ApiFieldConstants.Analysis.ITEMS)) {
            ObjectNode item = object(value);
            fields(
                item,
                Set.of(
                    ApiFieldConstants.Analysis.ITEM_KEY,
                    ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS,
                    ApiFieldConstants.Analysis.CANDIDATE_IDS
                ),
                Set.of()
            );
            if (!keys.add(text(item, ApiFieldConstants.Analysis.ITEM_KEY))
                || !item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS).isArray()
                || item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS).isEmpty()
                || item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS).size() > 60
                || !item.path(ApiFieldConstants.Analysis.CANDIDATE_IDS).isArray()) {
                throw invalid();
            }

            for (JsonNode id : item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS)) {
                parseId(id.asString());
                if (!allIds.contains(id.asString())) {
                    throw new FinancialException(403, ApiCodeConstants.Analysis.RESOURCE_FORBIDDEN);
                }
            }

            strings(item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS));
            Set<String> candidates = strings(item.path(ApiFieldConstants.Analysis.CANDIDATE_IDS));
            if (text(body, ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND)
                .equals(ApiCodeConstants.Analysis.TRANSACTION_MEANING) ? !candidates.isEmpty()
                    : candidates.size() != 1) {
                throw invalid();
            }
        }

        evidence.descriptor(owner, source, body);
    }

    /**
     * 제출 항목과 접수 ID 관계를 대조해 다른 대상으로 바꾸는 요청을 거절한다.
     * @created 2026-11-01
     * @usedBy submit
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private void matchItems(ObjectNode descriptor, ObjectNode input) {
        if (descriptor.path(ApiFieldConstants.Analysis.ITEMS)
            .size() != input.path(ApiFieldConstants.Analysis.ITEMS).size()) {
            throw invalid();
        }

        for (JsonNode item : input.path(ApiFieldConstants.Analysis.ITEMS)) {
            List<JsonNode> found = new java.util.ArrayList<>();
            descriptor.path(ApiFieldConstants.Analysis.ITEMS)
                .forEach(
                    old -> {
                        if (old.path(ApiFieldConstants.Analysis.ITEM_KEY)
                            .equals(item.path(ApiFieldConstants.Analysis.ITEM_KEY))) {
                            found.add(old);
                        }
                    }
                );
            if (found.size() != 1) {
                throw invalid();
            }

            Set<String> before = strings(
                found.getFirst().path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS)
            );
            if (!before
                .equals(strings(item.path(ApiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS)))) {
                throw invalid();
            }

            Set<String> candidates = strings(
                found.getFirst().path(ApiFieldConstants.Analysis.CANDIDATE_IDS)
            );
            if (item.path(ApiFieldConstants.Analysis.CANDIDATE_KEY).isNull() ? !candidates.isEmpty()
                : !candidates.equals(
                    Set.of(item.path(ApiFieldConstants.Analysis.CANDIDATE_KEY).asString())
                )) {
                throw invalid();
            }
        }
    }

    /**
     * 진행 상태와 Q2 조건에 따른 60초 입력 허용 식별을 반환한다. 별도 인증 수단이 아니다.
     * @created 2026-11-01
     * @usedBy read, accept, submit
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 동일 구현의 Jackson 문자열 노드 생성 메서드로 교체
     */
    private ObjectNode status(UUID owner, UUID id) {
        ObjectNode current = job(owner, id);
        if (current.path(AnalysisDb.CANONICAL_JOB_ID).isString()) {
            return status(owner, uuid(current, AnalysisDb.CANONICAL_JOB_ID));
        }

        String state = effectiveState(current);
        String action = switch (state) {
        case ApiCodeConstants.Analysis.SUCCEEDED -> ApiCodeConstants.Analysis.READ_RESULT;
        case ApiCodeConstants.Analysis.FAILED, ApiCodeConstants.Analysis.OUTCOME_UNKNOWN,
            ApiCodeConstants.Analysis.CANCELLED -> ApiCodeConstants.Analysis.RETRY;
        case ApiCodeConstants.Analysis.EXPIRED -> ApiCodeConstants.Analysis.REFRESH_INPUT;
        default -> ApiCodeConstants.Analysis.WAIT;
        };
        ObjectNode response = AnalysisJson.JSON.createObjectNode()
            .put(
                ApiFieldConstants.Analysis.CONTRACT_VERSION,
                ApiConfigConstants.Analysis.ANALYSIS_CONTRACT
            )
            .put(ApiFieldConstants.Analysis.JOB_ID, id.toString())
            .put(ApiFieldConstants.Analysis.STATE, state)
            .put(ApiFieldConstants.Analysis.ACTION, action)
            .put(
                ApiFieldConstants.Analysis.RESULT_AVAILABILITY,
                ApiCodeConstants.Analysis.UNCHECKED
            );
        if (current.path(ApiFieldConstants.Analysis.DETAIL)
            .path(ApiFieldConstants.Analysis.ITEMS)
            .isArray()
            && (!current.path(AnalysisDb.FINISHED_AT).isString()
                || clock.instant()
                    .isBefore(time(current, AnalysisDb.FINISHED_AT).plusSeconds(7L * 86400)))) {
            int accepted = current.path(ApiFieldConstants.Analysis.DETAIL)
                .path(ApiFieldConstants.Analysis.ITEMS)
                .size();
            int completed = state.equals(ApiCodeConstants.Analysis.SUCCEEDED) ? accepted : 0;
            response.putObject(ApiFieldConstants.Analysis.PROGRESS)
                .put(ApiFieldConstants.Analysis.ACCEPTED, accepted)
                .put(ApiFieldConstants.Analysis.COMPLETED, completed)
                .put(ApiFieldConstants.Analysis.UNRESOLVED, accepted - completed);
        }
        if (current.path(AnalysisDb.SELECTED_RESULT_ID).isString()) {
            response.set(
                ApiFieldConstants.Analysis.RESULT_ID,
                current.get(AnalysisDb.SELECTED_RESULT_ID)
            );
        }
        if (Set.of(ApiCodeConstants.Analysis.QUEUED, ApiCodeConstants.Analysis.AWAITING_INPUT)
            .contains(state) && ready(current)) {
            if (!current.path(AnalysisDb.PERMIT_HASH).isString()
                || !clock.instant().isBefore(time(current, AnalysisDb.PERMIT_EXPIRES_AT))) {
                String permit = AnalysisJson.digest(
                    tools.jackson.databind.node.JsonNodeFactory.instance
                        .stringNode(UUID.randomUUID().toString())
                );
                Instant permitExpiry = clock.instant().plusSeconds(60);
                if (permitExpiry.isAfter(time(current, AnalysisDb.EXECUTION_EXPIRES_AT))) {
                    permitExpiry = time(current, AnalysisDb.EXECUTION_EXPIRES_AT);
                }
                ObjectNode update = AnalysisJson.JSON.createObjectNode()
                    .put(AnalysisDb.PERMIT_HASH, permit)
                    .put(AnalysisDb.PERMIT_EXPIRES_AT, permitExpiry.toString())
                    .put(
                        ApiFieldConstants.Analysis.STATE,
                        ApiCodeConstants.Analysis.AWAITING_INPUT
                    );
                repository.update(JOBS, owner, id, update);
                current.setAll(update);
            }
            response.put(ApiFieldConstants.Analysis.STATE, ApiCodeConstants.Analysis.AWAITING_INPUT)
                .put(ApiFieldConstants.Analysis.ACTION, ApiCodeConstants.Analysis.SUBMIT_INPUT);
            response.set(ApiFieldConstants.Analysis.PERMIT, current.get(AnalysisDb.PERMIT_HASH));
            response.set(
                ApiFieldConstants.Analysis.PERMIT_EXPIRES_AT,
                current.get(AnalysisDb.PERMIT_EXPIRES_AT)
            );
        }
        return response;
    }

    /**
     * 현재 사용자 외의 작업 존재 여부를 같은 403으로 숨긴다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    private ObjectNode job(UUID owner, UUID id) {
        return repository.one(JOBS, owner, Map.of(AnalysisDb.ID, id))
            .orElseThrow(
                () -> new FinancialException(403, ApiCodeConstants.Analysis.RESOURCE_FORBIDDEN)
            );
    }

    /**
     * 만료·결과 불명을 구분하고 옛 토큰이나 자동 재호출로 처리를 재개하지 않는다.
     * @created 2026-11-01
     * @usedBy status, submit
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private String effectiveState(ObjectNode job) {
        if (!clock.instant().isBefore(time(job, AnalysisDb.GUARD_EXPIRES_AT))) {
            return ApiCodeConstants.Analysis.EXPIRED;
        }

        String state = job.path(ApiFieldConstants.Analysis.STATE).asString();
        if (!clock.instant().isBefore(time(job, AnalysisDb.EXECUTION_EXPIRES_AT))) {
            if (state.equals(ApiCodeConstants.Analysis.RUNNING)) {
                return ApiCodeConstants.Analysis.OUTCOME_UNKNOWN;
            }
            if (Set.of(ApiCodeConstants.Analysis.QUEUED, ApiCodeConstants.Analysis.AWAITING_INPUT)
                .contains(state)) {
                return ApiCodeConstants.Analysis.FAILED;
            }
        }
        return state;
    }

    /**
     * 확정된 Q2의 10건 또는 60초 조건으로 일반 항목의 실행 준비를 판정한다.
     * @created 2026-11-01
     * @usedBy status, submit
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    private boolean ready(ObjectNode job) {
        return job.path(ApiFieldConstants.Analysis.DETAIL)
            .path(ApiFieldConstants.Analysis.ITEMS)
            .size() >= 10
            || !clock.instant().isBefore(time(job, AnalysisDb.ACCEPTED_AT).plusSeconds(60));
    }

    /**
     * 종료·만료 상태를 새 진행 작업으로 판단하지 않는다.
     * @created 2026-11-01
     * @usedBy accept, submit
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private boolean live(ObjectNode job) {
        return Set.of(
            ApiCodeConstants.Analysis.QUEUED,
            ApiCodeConstants.Analysis.AWAITING_INPUT,
            ApiCodeConstants.Analysis.RUNNING
        ).contains(effectiveState(job));
    }

    /**
     * 새 쓰기 전 만료된 활성 행을 종료 상태로 옮겨 UNIQUE·용량에 계속 남지 않게 한다.
     * @created 2026-11-01
     * @usedBy accept, submit
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private void retireExpired(UUID owner) {
        var openStates = List.of(
            ApiCodeConstants.Analysis.QUEUED,
            ApiCodeConstants.Analysis.AWAITING_INPUT,
            ApiCodeConstants.Analysis.RUNNING
        );
        for (String state : openStates) {
            List<ObjectNode> activeJobs = repository
                .find(JOBS, owner, Map.of(ApiFieldConstants.Analysis.STATE, state));
            for (ObjectNode old : activeJobs) {
                String effective = effectiveState(old);
                if (!effective.equals(state)) {
                    repository.update(
                        JOBS,
                        owner,
                        uuid(old, AnalysisDb.ID),
                        AnalysisJson.JSON.createObjectNode()
                            .put(ApiFieldConstants.Analysis.STATE, effective)
                            .put(AnalysisDb.FINISHED_AT, clock.instant().toString())
                    );
                }
            }
        }
    }

    /**
     * 최초 성공 헤더를 고정하며 금융 버전과 원천은 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy execute, submit
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private void selectResult(UUID owner, ObjectNode job, UUID result, String hash) {
        if (job.path(AnalysisDb.SELECTED_RESULT_ID).isString()) {
            if (!uuid(job, AnalysisDb.SELECTED_RESULT_ID).equals(result)) {
                throw conflict();
            }

            return;
        }

        repository.update(
            JOBS,
            owner,
            uuid(job, AnalysisDb.ID),
            AnalysisJson.JSON.createObjectNode()
                .put(ApiFieldConstants.Analysis.STATE, ApiCodeConstants.Analysis.SUCCEEDED)
                .put(AnalysisDb.SELECTED_RESULT_ID, result.toString())
                .put(AnalysisDb.INPUT_HASH, hash)
                .put(AnalysisDb.FINISHED_AT, clock.instant().toString())
        );
    }

    /**
     * 같은 사용자의 동일 키만 재관찰하고 다른 작업·본문의 재사용은 거절한다.
     * @created 2026-11-01
     * @usedBy accept, submit, deleteMemory
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode command(UUID owner, String key, String operation, String hash) {
        ObjectNode found = repository.one(COMMANDS, owner, Map.of(AnalysisDb.REQUEST_KEY, key))
            .orElse(null);
        if (found == null) {
            return null;
        }
        if (!operation.equals(found.path(ApiFieldConstants.Analysis.OPERATION).asString())
            || !hash.equals(found.path(AnalysisDb.REQUEST_HASH).asString())) {
            throw conflict();
        }
        if (!clock.instant().isBefore(time(found, AnalysisDb.EXPIRES_AT))) {
            throw conflict();
        }

        return found;
    }

    /**
     * 본문 없는 중복 방지 기록을 고정 기한으로 저장한다.
     * @created 2026-11-01
     * @usedBy accept, submit, deleteMemory
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private void remember(
        UUID owner,
        String key,
        String operation,
        String hash,
        UUID job,
        UUID attempt,
        UUID item,
        Instant expiry
    ) {
        ObjectNode row = AnalysisJson.JSON.createObjectNode()
            .put(AnalysisDb.USER_ID, owner.toString())
            .put(AnalysisDb.REQUEST_KEY, key)
            .put(ApiFieldConstants.Analysis.OPERATION, operation)
            .put(AnalysisDb.REQUEST_HASH, hash)
            .put(AnalysisDb.CREATED_AT, clock.instant().toString())
            .put(AnalysisDb.EXPIRES_AT, expiry.toString());
        if (job != null) {
            row.put(AnalysisDb.JOB_ID, job.toString());
        }
        if (attempt != null) {
            row.put(AnalysisDb.ATTEMPT_ID, attempt.toString());
        }
        if (item != null) {
            row.put(AnalysisDb.ITEM_ID, item.toString());
        }

        repository.insert(COMMANDS, owner, row);
    }

    /**
     * 세션 갱신으로 별도 효과를 만들지 않고 본문·작업·대상 변경을 구분한다.
     * @created 2026-11-01
     * @usedBy accept, submit, deleteMemory
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private String commandHash(String operation, UUID id, ObjectNode body) {
        ObjectNode copy = body.deepCopy();
        copy.remove(ApiFieldConstants.Analysis.IDEMPOTENCY_KEY);
        for (JsonNode context : List.of(
            copy.path(ApiFieldConstants.Analysis.CONTEXT),
            copy.path(ApiFieldConstants.Analysis.INPUT).path(ApiFieldConstants.Analysis.CONTEXT)
        )) {
            if (context instanceof ObjectNode object) {
                object.remove(
                    List.of(
                        ApiFieldConstants.Analysis.LOCAL_SESSION_EPOCH,
                        ApiFieldConstants.Analysis.INPUT_REVISION
                    )
                );
            }
        }

        ObjectNode effect = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.OPERATION, operation);
        if (id != null) {
            effect.put(AnalysisDb.ID, id.toString());
        }
        effect.set(ApiFieldConstants.Analysis.BODY, copy);
        return AnalysisJson.digest(effect);
    }

    /**
     * 정확히 허용된 필드만 받고 빈 문자열·타입 오류를 검증 실패로 구분한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static ObjectNode object(JsonNode value) {
        if (!(value instanceof ObjectNode object)) {
            throw invalid();
        }

        return object;
    }

    /**
     * 필수 문자열 누락을 임의 기본값으로 대체하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static String text(ObjectNode value, String key) {
        if (!value.path(key).isString() || value.path(key)
            .asString()
            .isBlank()) {
            throw invalid();
        }

        return value.path(key).asString();
    }

    /**
     * 허용하지 않은 키를 거절하여 내부 상태 덮어쓰기를 막는다.
     * @created 2026-11-01
     * @usedBy accept, submit, query, validateDescriptor
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void fields(ObjectNode body, Set<String> required, Set<String> optional) {
        if (!body.propertyNames().containsAll(required)
            || body.propertyNames()
                .stream()
                .anyMatch(name -> !required.contains(name) && !optional.contains(name))) {
            throw invalid();
        }
    }

    /**
     * 기존 멱등 키 형식을 사용한다.
     * @created 2026-11-01
     * @usedBy accept, submit
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private static String key(ObjectNode body) {
        String key = text(body, ApiFieldConstants.Analysis.IDEMPOTENCY_KEY);
        checkKey(key);
        return key;
    }

    /**
     * 요청별 키를 제한하고 공백·제어문자를 허용하지 않는다.
     * @created 2026-11-01
     * @usedBy key, deleteMemory
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static void checkKey(String key) {
        if (key == null || !key.matches("[A-Za-z0-9._-]{1,128}")) {
            throw invalid();
        }
    }

    /**
     * 표준 UUID만 받고 이름·순서로 대상을 추정하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static UUID parseId(String text) {
        try {
            UUID id = UUID.fromString(text);
            if (!id.toString().equals(text)) {
                throw invalid();
            }

            return id;
        } catch (IllegalArgumentException failure) {
            throw invalid();
        }
    }

    /**
     * 근거 집합의 중복을 거절한다.
     * @created 2026-11-01
     * @usedBy matchItems
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private static Set<String> strings(JsonNode values) {
        Set<String> result = new java.util.HashSet<>();
        for (JsonNode value : values) {
            if (!value.isString() || !result.add(value.asString())) {
                throw invalid();
            }
        }

        return result;
    }

    /**
     * 저장 전 업무 검증 실패를 기존 오류로 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private static FinancialException invalid() {
        return new FinancialException(422, ApiCodeConstants.Analysis.VALIDATION_FAILED);
    }

    /**
     * 중복 키·상태·기한의 충돌을 성공으로 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private static FinancialException conflict() {
        return new FinancialException(409, ApiCodeConstants.Analysis.RELATION_CONFLICT);
    }

    /**
     * 서버 종료는 새 실행을 막지만 DB의 전송/미확인 기록을 삭제하지 않는다.
     * @created 2026-11-01
     * @usedBy Spring 종료
     */
    @PreDestroy
    public void close() {
        workers.shutdownNow();
    }

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
        @Override
        public String toString() {
            return "Reply[status=" + status + ", REDACTED]";
        }
    }

    /**
     * 메모리 안에서만 전달하는 작업 입력이다. 토큰·본문을 DB나 로그에 남기지 않는다.
     * @created 2026-11-01
     * @usedBy submit, execute
     * @modified 2026-11-03 - 공개 입력과 모델 전용 원천 근거를 분리 보관
     */
    private record Work(
        String token,
        UUID owner,
        UUID job,
        UUID attempt,
        String hash,
        String basisHash,
        ObjectNode input,
        ObjectNode modelFacts
    ) {
        /**
         * 자동 문자열 표현에 자격·금융 본문을 노출하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override
        public String toString() {
            return "Work[REDACTED]";
        }
    }

    /**
     * 커밋 이후에만 작업을 전송하도록 응답과 메모리 작업을 구분한다.
     * @created 2026-11-01
     * @usedBy submit
     */
    private record Submission(Reply reply, Work work) {
    }

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
        @Override
        public String toString() {
            return "Read[REDACTED]";
        }
    }
}
