package com.payse.api.analysis.service;

import static com.payse.api.analysis.mapper.AnalysisRepository.Table.*;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.dto.MemoryDecision;
import com.payse.api.analysis.crypto.EncryptedMemory;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.mapper.AnalysisRepository;
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants.AnalysisDb;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialRepository;
import java.nio.charset.StandardCharsets;
import java.time.Clock;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Base64;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.HexFormat;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 결과 묶음과 개별 암호화 기억을 구분하고 사용자·근거별 재사용/삭제를 집행한다.
 * @created 2026-11-01
 * @usedBy AnalysisJobs
 */
@Component
@Profile("database & auth & finance & analysis")
public final class AnalysisResults {

    private final AnalysisRepository repository;
    private final AnalysisRuntime runtime;
    private final Clock clock;
    private final FinancialRepository finances;
    private final AnalysisIdentity identity = new AnalysisIdentity();
    private final MemoryPolicy policy = new MemoryPolicy();

    /**
     * 사용자 상태 없는 저장·암호화 구성과 시계를 주입한다.
     * @created 2026-11-01
     * @usedBy Spring 생성자 주입
     */
    public AnalysisResults(
        AnalysisRepository repository,
        AnalysisRuntime runtime,
        Clock clock,
        FinancialRepository finances
    ) {
        this.repository = repository;
        this.runtime = runtime;
        this.clock = clock;
        this.finances = finances;
    }

    /**
     * DB 트랜잭션 밖에서 결과를 항목별로 암호화한다. 반환물에 평문 본문은 없다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.execute
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    public List<Prepared> prepare(UUID owner, ObjectNode input, AnalysisResult result) {
        if (result.failure() != null) {
            throw new IllegalStateException(ApiMessageConstants.Analysis.INCOMPLETE_RESULT);
        }

        Map<String, JsonNode> meanings = new HashMap<>();
        result.output()
            .path(ApiFieldConstants.Analysis.ITEMS)
            .forEach(
                item -> meanings
                    .put(item.path(ApiFieldConstants.Analysis.ITEM_KEY).asString(), item)
            );
        Map<String, MemoryDecision> decisions = new HashMap<>();
        result.memories().forEach(item -> decisions.put(item.itemKey(), item));
        List<Prepared> prepared = new ArrayList<>();
        for (var item : identity.items(input)) {
            MemoryDecision decision = decisions.get(item.itemKey());
            ObjectNode meaning = ((ObjectNode) meanings.get(item.itemKey())).deepCopy();
            meaning.remove(
                List.of(
                    ApiFieldConstants.Analysis.ITEM_KEY,
                    ApiFieldConstants.Analysis.CANDIDATE_KEY
                )
            );
            ObjectNode body = AnalysisJson.JSON.createObjectNode()
                .put(ApiFieldConstants.Analysis.RETENTION_REASON, decision.reason());
            body.set(ApiFieldConstants.Analysis.INTERPRETATION, meaning);
            byte[] plaintext = body.toString().getBytes(StandardCharsets.UTF_8);
            UUID id = UUID.randomUUID();
            try {
                Flags flags = new Flags(
                    decision.active(),
                    decision.isReference(),
                    decision.important(),
                    decision.referencePolicy()
                );
                EncryptedMemory encrypted = runtime.encrypt(owner, id, plaintext);
                prepared.add(new Prepared(id, item, flags, encrypted));
            } finally {
                Arrays.fill(plaintext, (byte) 0);
            }
        }

        return List.copyOf(prepared);
    }

    /**
     * 짧은 채택 트랜잭션에서 항목을 원자 저장하되 삭제된 근거는 본문 없이 제외한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.execute
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 관리 조회의 전체 근거 접근 검증용 불변 참조·지문 저장
     */
    public UUID save(
        UUID owner,
        ObjectNode input,
        String inputHash,
        List<Prepared> prepared,
        boolean recovery
    ) {
        UUID resultId = UUID.randomUUID();
        Instant now = clock.instant();
        String kind = input.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND).asString();
        Map<String, AnalysisIdentity.Item> bound = new HashMap<>();
        ObjectNode source = finances.load(owner);
        identity.boundItems(source, input)
            .forEach(item -> bound.put(item.itemKey(), item));
        ObjectNode header = row(owner, resultId)
            .put(AnalysisDb.SEMANTIC_KIND, kind)
            .put(AnalysisDb.INPUT_HASH, inputHash)
            .put(AnalysisDb.COMMITTED_AT, now.toString());
        ObjectNode provenance = (ObjectNode) input.path(ApiFieldConstants.Analysis.CONTEXT)
            .deepCopy();
        provenance.set(ApiFieldConstants.Analysis.VERSIONS, runtime.versions());
        provenance.put(ApiFieldConstants.Analysis.ANALYSIS_INPUT_HASH, inputHash);
        header.set(ApiFieldConstants.Analysis.PROVENANCE, provenance);
        var manifest = header.putArray(AnalysisDb.ACCEPTED_MANIFEST);
        for (Prepared value : prepared) {
            manifest.addObject()
                .put(ApiFieldConstants.Analysis.ITEM_KEY, value.identity().itemKey())
                .put(ApiFieldConstants.Analysis.MEMORY_KEY, value.identity().key())
                .put(
                    ApiFieldConstants.Analysis.EVIDENCE_HASH,
                    bound.get(value.identity().itemKey()).evidenceHash()
                );
        }

        repository.insert(RESULTS, owner, header);
        for (Prepared value : prepared) {
            AnalysisIdentity.Item current = bound.get(value.identity().itemKey());
            Map<String, ?> match = match(kind, current);
            if (repository.one(SUPPRESSIONS, owner, match).isPresent()) {
                continue;
            }

            Instant first = recovery ? now
                : repository.find(ITEMS, owner, match)
                    .stream()
                    .map(item -> time(item, AnalysisDb.STORED_AT))
                    .min(Comparator.naturalOrder())
                    .orElse(now);
            EncryptedMemory encrypted = value.encrypted();
            Flags decision = value.decision();
            ObjectNode stored = row(owner, value.id())
                .put(AnalysisDb.RESULT_ID, resultId.toString())
                .put(AnalysisDb.ITEM_KEY, value.identity().itemKey())
                .put(AnalysisDb.SEMANTIC_KIND, kind)
                .put(AnalysisDb.MEMORY_KEY, current.key())
                .put(AnalysisDb.EVIDENCE_HASH, current.evidenceHash())
                .put(AnalysisDb.STORED_AT, first.toString())
                .put(AnalysisDb.NORMAL_EXPIRES_AT, policy.normalExpiry(first).toString())
                .put(
                    ApiFieldConstants.Analysis.CIPHERTEXT,
                    "\\x" + HexFormat.of().formatHex(encrypted.ciphertext())
                )
                .put(ApiFieldConstants.Analysis.ACTIVE, decision.active())
                .put(AnalysisDb.IS_REFERENCE, decision.isReference())
                .put(ApiFieldConstants.Analysis.IMPORTANT, decision.important())
                .put(AnalysisDb.REFERENCE_POLICY, decision.referencePolicy())
                .put(AnalysisDb.METADATA_VERSION, 1)
                .put(AnalysisDb.POLICY_VERSION, ApiConfigConstants.Analysis.MEMORY_CONTRACT)
                .put(AnalysisDb.POLICY_ACTOR, ApiCodeConstants.Analysis.AI);
            List<UUID> refs = identity.sourceRefs(input, value.identity().itemKey());
            var referenceIds = stored.putArray(ApiFieldConstants.AnalysisDb.SOURCE_REFS);
            refs.forEach(id -> referenceIds.add(id.toString()));
            stored.put(
                ApiFieldConstants.AnalysisDb.SOURCE_HASH,
                identity.referenceHash(source, refs)
            );
            stored.putObject(AnalysisDb.CRYPTO_META)
                .put(ApiFieldConstants.Analysis.KEY_REF, encrypted.key().keyRef())
                .put(
                    ApiFieldConstants.Analysis.WRAPPED_KEY,
                    Base64.getEncoder().encodeToString(encrypted.key().ciphertext())
                )
                .put(
                    ApiFieldConstants.Analysis.NONCE,
                    Base64.getEncoder().encodeToString(encrypted.nonce())
                );

            repository.insert(ITEMS, owner, stored);
        }

        return resultId;
    }

    /**
     * 현재 입력과 사용자에 맞는 결과만 선택하고 복호화 전 이용 자격을 확인한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 결과 재사용·조회
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 키 접근 의미를 유지하며 null 수신자 메서드 참조 경고 해소
     */
    public Selection select(UUID owner, ObjectNode input, UUID requested) {
        List<AnalysisIdentity.Item> wantedItems = identity.boundItems(finances.load(owner), input);
        Set<String> blocked = new HashSet<>();
        String kind = input.path(ApiFieldConstants.Analysis.SEMANTIC_TASK_KIND).asString();
        List<String> memoryKeys = wantedItems.stream()
            .map(item -> item.key())
            .toList();
        repository.suppressions(owner, kind, memoryKeys)
            .forEach(
                row -> blocked.add(
                    row.path(AnalysisDb.MEMORY_KEY).asString() + ":"
                        + row.path(AnalysisDb.EVIDENCE_HASH).asString()
                )
            );
        List<ObjectNode> candidates;
        if (requested != null) {
            ObjectNode result = repository.one(RESULTS, owner, Map.of(AnalysisDb.ID, requested))
                .orElseThrow(
                    () -> new FinancialException(403, ApiCodeConstants.Analysis.RESOURCE_FORBIDDEN)
                );
            candidates = List.of(result);
        } else {
            candidates = repository.results(owner, kind, memoryKeys);
        }
        Selection best = new Selection(null, List.of(), ApiCodeConstants.Analysis.MISSING);
        for (ObjectNode header : candidates) {
            Map<String, ObjectNode> memories = new HashMap<>();
            UUID resultId = uuid(header, AnalysisDb.ID);
            List<ObjectNode> resultItems = repository
                .find(ITEMS, owner, Map.of(AnalysisDb.RESULT_ID, resultId));
            for (ObjectNode memory : resultItems) {
                if (memories.put(memory.path(AnalysisDb.MEMORY_KEY).asString(), memory) != null) {
                    throw new IllegalStateException(ApiMessageConstants.Analysis.DUPLICATE_RESULT);
                }
            }

            List<Entry> entries = new ArrayList<>();
            int available = 0;
            for (var wanted : wantedItems) {
                ObjectNode memory = memories.get(wanted.key());
                String state = availability(
                    header,
                    memory,
                    wanted,
                    input,
                    blocked.contains(wanted.key() + ":" + wanted.evidenceHash())
                );
                if (state.equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                    available++;
                }
                entries.add(new Entry(wanted, memory, state));
            }

            String state = available == entries.size() ? ApiCodeConstants.Analysis.AVAILABLE
                : available > 0 ? ApiCodeConstants.Analysis.PARTIAL
                    : ApiCodeConstants.Analysis.MISSING;
            Selection choice = new Selection(header, entries, state);
            if (state.equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                return choice;
            }

            if (best.header() == null || (!best.state().equals(ApiCodeConstants.Analysis.PARTIAL)
                && state.equals(ApiCodeConstants.Analysis.PARTIAL))) {
                best = choice;
            }
        }

        return best;
    }

    /**
     * 삭제·만료·비활성·관련 근거를 독립 판정하고 실제 사유를 유지한다.
     * @created 2026-11-01
     * @usedBy select
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private String availability(
        ObjectNode header,
        ObjectNode memory,
        AnalysisIdentity.Item wanted,
        ObjectNode input,
        boolean blocked
    ) {
        if (blocked) {
            return ApiCodeConstants.Analysis.DELETED;
        }
        if (memory == null) {
            return ApiCodeConstants.Analysis.MISSING;
        }
        if (!memory.path(AnalysisDb.DELETED_AT).isNull() && memory.has(AnalysisDb.DELETED_AT)) {
            return ApiCodeConstants.Analysis.DELETED;
        }
        if (memory.path(AnalysisDb.PURGE_REQUESTED_AT).isString()) {
            return ApiCodeConstants.Analysis.EXPIRED;
        }
        if (!memory.path(ApiFieldConstants.Analysis.IMPORTANT).asBoolean()
            && !clock.instant().isBefore(time(memory, AnalysisDb.NORMAL_EXPIRES_AT))) {
            return ApiCodeConstants.Analysis.EXPIRED;
        }
        if (!memory.path(ApiFieldConstants.Analysis.ACTIVE).asBoolean()) {
            return ApiCodeConstants.Analysis.INACTIVE;
        }
        if (!memory.path(AnalysisDb.EVIDENCE_HASH)
            .asString()
            .equals(wanted.evidenceHash())
            || !header.path(ApiFieldConstants.Analysis.PROVENANCE)
                .path(ApiFieldConstants.Analysis.VERSIONS)
                .equals(runtime.versions())
            || !header.path(ApiFieldConstants.Analysis.PROVENANCE)
                .path(ApiFieldConstants.Analysis.RULE_VERSION)
                .equals(
                    input.path(ApiFieldConstants.Analysis.CONTEXT)
                        .path(ApiFieldConstants.Analysis.RULE_VERSION)
                )
            || !header.path(ApiFieldConstants.Analysis.PROVENANCE)
                .path(ApiFieldConstants.Analysis.SCHEMA_VERSION)
                .equals(
                    input.path(ApiFieldConstants.Analysis.CONTEXT)
                        .path(ApiFieldConstants.Analysis.SCHEMA_VERSION)
                )) {
            return ApiCodeConstants.Analysis.STALE;
        }

        return ApiCodeConstants.Analysis.AVAILABLE;
    }

    /**
     * DB 잠금 밖에서 허용된 기억만 복호화하며 반환 직전 호출자가 자격을 다시 확인한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.query
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     * @modified 2026-11-02 - 관리 목록과 단일 기억 복호화 구현 공유
     */
    public Map<UUID, ObjectNode> decrypt(UUID owner, Selection selection) {
        Map<UUID, ObjectNode> bodies = new HashMap<>();
        for (Entry entry : selection.entries()) {
            if (!entry.state().equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                continue;
            }

            ObjectNode memory = entry.memory();
            UUID id = uuid(memory, AnalysisDb.ID);
            bodies.put(id, decryptMemory(owner, memory));
        }

        return bodies;
    }

    /**
     * 호출자가 현재 열람 자격을 확인한 기억 하나만 사용자·항목 AAD로 복호화한다.
     * @created 2026-11-01
     * @usedBy decrypt, MemoryCatalog.read
     * @modified 2026-11-02 - 최신 암호화 필드 상수와 단일 기억 복호화 경계를 통합
     */
    public ObjectNode decryptMemory(UUID owner, ObjectNode memory) {
        JsonNode meta = memory.path(AnalysisDb.CRYPTO_META);
        byte[] ciphertext = HexFormat.of()
            .parseHex(
                memory.path(ApiFieldConstants.Analysis.CIPHERTEXT)
                    .asString()
                    .substring(2)
            );
        byte[] nonce = Base64.getDecoder()
            .decode(meta.path(ApiFieldConstants.Analysis.NONCE).asString());
        String keyRef = meta.path(ApiFieldConstants.Analysis.KEY_REF).asString();
        byte[] wrappedBytes = Base64.getDecoder()
            .decode(meta.path(ApiFieldConstants.Analysis.WRAPPED_KEY).asString());
        WrappedKey wrapped = new WrappedKey(keyRef, wrappedBytes);
        EncryptedMemory encrypted = new EncryptedMemory(ciphertext, nonce, wrapped);
        byte[] plaintext = runtime.decrypt(owner, uuid(memory, AnalysisDb.ID), encrypted);
        try {
            return (ObjectNode) AnalysisJson.JSON.readTree(plaintext);
        } finally {
            Arrays.fill(plaintext, (byte) 0);
        }
    }

    /**
     * 현재 itemKey로 복원하며 사용할 수 없는 항목은 본문 없이 사유만 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.query
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    public ObjectNode response(
        ObjectNode input,
        Selection selection,
        Map<UUID, ObjectNode> bodies
    ) {
        ObjectNode response = AnalysisJson.JSON.createObjectNode()
            .put(
                ApiFieldConstants.Analysis.CONTRACT_VERSION,
                ApiConfigConstants.Analysis.ANALYSIS_CONTRACT
            )
            .put(ApiFieldConstants.Analysis.RESULT_AVAILABILITY, selection.state());
        response.set(
            ApiFieldConstants.Analysis.CONTEXT,
            input.path(ApiFieldConstants.Analysis.CONTEXT).deepCopy()
        );
        if (selection.header() == null) {
            return response;
        }

        response.set(ApiFieldConstants.Analysis.RESULT_ID, selection.header().get(AnalysisDb.ID));
        ObjectNode publicProvenance = response.putObject(ApiFieldConstants.Analysis.PROVENANCE);
        JsonNode storedProvenance = selection.header().get(ApiFieldConstants.Analysis.PROVENANCE);
        List<String> provenanceFields = List.of(
            ApiFieldConstants.Analysis.SCHEMA_VERSION,
            ApiFieldConstants.Analysis.DATA_VERSION,
            ApiFieldConstants.Analysis.SOURCE_VERSION,
            ApiFieldConstants.Analysis.RULE_VERSION,
            ApiFieldConstants.Analysis.AS_OF,
            ApiFieldConstants.Analysis.VERSIONS,
            ApiFieldConstants.Analysis.ANALYSIS_INPUT_HASH
        );
        for (String field : provenanceFields) {
            if (storedProvenance.has(field)) {
                publicProvenance.set(field, storedProvenance.get(field).deepCopy());
            }
        }

        ObjectNode result = response.putObject(ApiFieldConstants.Analysis.RESULT)
            .put(
                ApiFieldConstants.Analysis.MEANING_POLICY_VERSION,
                ApiConfigConstants.Analysis.MEANING_POLICY
            );
        var items = result.putArray(ApiFieldConstants.Analysis.ITEMS);
        var statuses = result.putArray(ApiFieldConstants.Analysis.ITEM_AVAILABILITY);
        ObjectNode validationOutput = AnalysisJson.JSON.createObjectNode()
            .put(
                ApiFieldConstants.Analysis.MEANING_POLICY_VERSION,
                ApiConfigConstants.Analysis.MEANING_POLICY
            );
        var validationMeanings = validationOutput.putArray(ApiFieldConstants.Analysis.ITEMS);
        for (Entry entry : selection.entries()) {
            ObjectNode status = statuses.addObject()
                .put(ApiFieldConstants.Analysis.ITEM_KEY, entry.identity().itemKey())
                .put(ApiFieldConstants.Analysis.STATE, entry.state());
            if (entry.memory() != null) {
                status.set(ApiFieldConstants.Analysis.ITEM_ID, entry.memory().get(AnalysisDb.ID));
            }
            if (!entry.state().equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                continue;
            }

            UUID id = uuid(entry.memory(), AnalysisDb.ID);
            ObjectNode body = bodies.get(id);
            if (body == null) {
                throw new IllegalStateException(ApiMessageConstants.Analysis.MEMORY_CHANGED);
            }

            ObjectNode meaning = (ObjectNode) body.path(ApiFieldConstants.Analysis.INTERPRETATION)
                .deepCopy();
            meaning.put(ApiFieldConstants.Analysis.ITEM_KEY, entry.identity().itemKey());
            for (JsonNode item : input.path(ApiFieldConstants.Analysis.ITEMS)) {
                if (item.path(ApiFieldConstants.Analysis.ITEM_KEY)
                    .asString()
                    .equals(entry.identity().itemKey())) {
                    if (!item.path(ApiFieldConstants.Analysis.CANDIDATE_KEY).isNull()) {
                        meaning.set(
                            ApiFieldConstants.Analysis.CANDIDATE_KEY,
                            item.get(ApiFieldConstants.Analysis.CANDIDATE_KEY)
                        );
                    }
                }
            }

            validationMeanings.add(meaning.deepCopy());
            ObjectNode returned = items.addObject()
                .put(ApiFieldConstants.Analysis.ITEM_ID, id.toString());
            returned.set(ApiFieldConstants.Analysis.INTERPRETATION, meaning);
            returned.put(
                ApiFieldConstants.Analysis.RETENTION_REASON,
                body.path(ApiFieldConstants.Analysis.RETENTION_REASON).asString()
            );
            for (String flag : List
                .of(ApiFieldConstants.Analysis.ACTIVE, ApiFieldConstants.Analysis.IMPORTANT)) {
                returned.set(flag, entry.memory().get(flag));
            }

            returned.set(
                ApiFieldConstants.Analysis.IS_REFERENCE,
                entry.memory().get(AnalysisDb.IS_REFERENCE)
            );
            returned.set(
                ApiFieldConstants.Analysis.REFERENCE_POLICY,
                entry.memory().get(AnalysisDb.REFERENCE_POLICY)
            );
            returned.set(
                ApiFieldConstants.Analysis.STORED_AT,
                entry.memory().get(AnalysisDb.STORED_AT)
            );
            returned.set(
                ApiFieldConstants.Analysis.NORMAL_EXPIRES_AT,
                entry.memory().get(AnalysisDb.NORMAL_EXPIRES_AT)
            );
        }

        if (!validationMeanings.isEmpty()) {
            new com.payse.ai.analysis.validation.AnalysisContract()
                .outputSubset(input, validationOutput);
        }
        return response;
    }

    /**
     * 같은 기억·근거의 모든 사본을 원자 차단하고 암호문과 감싼 데이터 키를 제거한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.deleteMemory
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    public void delete(UUID owner, UUID id) {
        ObjectNode item = repository.one(ITEMS, owner, Map.of(AnalysisDb.ID, id))
            .orElseThrow(
                () -> new FinancialException(403, ApiCodeConstants.Analysis.RESOURCE_FORBIDDEN)
            );
        Map<String, ?> match = Map.of(
            AnalysisDb.SEMANTIC_KIND,
            item.path(AnalysisDb.SEMANTIC_KIND).asString(),
            AnalysisDb.MEMORY_KEY,
            item.path(AnalysisDb.MEMORY_KEY).asString(),
            AnalysisDb.EVIDENCE_HASH,
            item.path(AnalysisDb.EVIDENCE_HASH).asString()
        );
        if (repository.one(SUPPRESSIONS, owner, match).isEmpty()) {
            ObjectNode block = AnalysisJson.JSON.createObjectNode()
                .put(AnalysisDb.USER_ID, owner.toString())
                .put(AnalysisDb.BLOCKED_AT, clock.instant().toString());
            match.forEach((key, value) -> block.put(key, value.toString()));

            repository.insert(SUPPRESSIONS, owner, block);
        }
        List<ObjectNode> copies = repository.find(ITEMS, owner, match);
        for (ObjectNode copy : copies) {
            if (!copy.path(AnalysisDb.DELETED_AT).isNull()) {
                continue;
            }

            ObjectNode change = AnalysisJson.JSON.createObjectNode()
                .put(AnalysisDb.DELETED_AT, clock.instant().toString())
                .put(AnalysisDb.PURGE_REQUESTED_AT, clock.instant().toString())
                .put(ApiFieldConstants.Analysis.ACTIVE, false)
                .put(
                    AnalysisDb.METADATA_VERSION,
                    Math.addExact(copy.path(AnalysisDb.METADATA_VERSION).asLong(), 1)
                );
            change.putNull(ApiFieldConstants.Analysis.CIPHERTEXT).putNull(AnalysisDb.CRYPTO_META);

            repository.update(ITEMS, owner, uuid(copy, AnalysisDb.ID), change);
        }
    }

    /**
     * 같은 사용자 안에서 기억 삭제·재저장 조건을 구성한다.
     * @created 2026-11-01
     * @usedBy save, availability
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    private Map<String, ?> match(String kind, AnalysisIdentity.Item item) {
        return Map.of(
            AnalysisDb.SEMANTIC_KIND,
            kind,
            AnalysisDb.MEMORY_KEY,
            item.key(),
            AnalysisDb.EVIDENCE_HASH,
            item.evidenceHash()
        );
    }

    /**
     * 서버 생성 행 ID와 인증 소유자만 초기화한다.
     * @created 2026-11-01
     * @usedBy save, AnalysisJobs
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리
     */
    static ObjectNode row(UUID owner, UUID id) {
        return AnalysisJson.JSON.createObjectNode()
            .put(AnalysisDb.ID, id.toString())
            .put(AnalysisDb.USER_ID, owner.toString());
    }

    /**
     * DB가 타입을 검증한 UUID를 복원한다.
     * @created 2026-11-01
     * @usedBy AnalysisResults, AnalysisJobs
     */
    static UUID uuid(JsonNode row, String key) {
        return UUID.fromString(row.path(key).asString());
    }

    /**
     * PostgreSQL JSON의 오프셋 시각을 Instant로 통일한다.
     * @created 2026-11-01
     * @usedBy AnalysisResults, AnalysisJobs
     */
    static Instant time(JsonNode row, String key) {
        return java.time.OffsetDateTime.parse(row.path(key).asString()).toInstant();
    }

    /**
     * 암호화 이후 짧은 DB 채택 처리로 전달할 항목과 보존 플래그다.
     * @created 2026-11-01
     * @usedBy prepare, save
     */
    public record Prepared(
        UUID id,
        AnalysisIdentity.Item identity,
        Flags decision,
        EncryptedMemory encrypted
    ) {
        /**
         * 암호문·근거 정보를 자동 로그로 출력하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override
        public String toString() {
            return "Prepared[REDACTED]";
        }
    }

    /**
     * 보존 사유는 암호화하고 이 타입에는 허용된 플래그만 남긴다.
     * @created 2026-11-01
     * @usedBy Prepared, save
     */
    public record Flags(
        boolean active,
        boolean isReference,
        boolean important,
        String referencePolicy
    ) {
    }

    /**
     * 복호화 전후 재검사에서 확인할 항목의 현재 자격이다.
     * @created 2026-11-01
     * @usedBy select, decrypt, response
     */
    public record Entry(AnalysisIdentity.Item identity, ObjectNode memory, String state) {
        /**
         * DB 암호문·키 참조를 자동 로그로 출력하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override
        public String toString() {
            return ApiMessageConstants.Analysis.MEMORY_ENTRY_REDACTED;
        }
    }

    /**
     * 본문 없는 결과 헤더와 현재 사용 자격이다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.query
     */
    public record Selection(ObjectNode header, List<Entry> entries, String state) {
        /**
         * 조회 출처·암호화 메타데이터를 자동 로그로 출력하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override
        public String toString() {
            return "Selection[REDACTED]";
        }
    }
}
