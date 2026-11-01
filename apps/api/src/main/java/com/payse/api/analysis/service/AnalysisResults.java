package com.payse.api.analysis.service;

import static com.payse.api.analysis.mapper.AnalysisRepository.Table.*;

import com.payse.ai.analysis.dto.AnalysisResult;
import com.payse.ai.analysis.dto.MemoryDecision;
import com.payse.api.analysis.crypto.EncryptedMemory;
import com.payse.api.analysis.crypto.WrappedKey;
import com.payse.api.analysis.mapper.AnalysisRepository;
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
    public AnalysisResults(AnalysisRepository repository, AnalysisRuntime runtime, Clock clock,
            FinancialRepository finances) {
        this.repository = repository;
        this.runtime = runtime;
        this.clock = clock;
        this.finances = finances;
    }

    /**
     * DB 트랜잭션 밖에서 결과를 항목별로 암호화한다. 반환물에 평문 본문은 없다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.execute
     */
    public List<Prepared> prepare(UUID owner, ObjectNode input, AnalysisResult result) {
        if (result.failure() != null) throw new IllegalStateException("Analysis result is incomplete");
        Map<String, JsonNode> meanings = new HashMap<>();
        result.output().path("items").forEach(item -> meanings.put(item.path("itemKey").asString(), item));
        Map<String, MemoryDecision> decisions = new HashMap<>();
        result.memories().forEach(item -> decisions.put(item.itemKey(), item));
        List<Prepared> prepared = new ArrayList<>();
        for (var item : identity.items(input)) {
            MemoryDecision decision = decisions.get(item.itemKey());
            ObjectNode meaning = ((ObjectNode) meanings.get(item.itemKey())).deepCopy();
            meaning.remove(List.of("itemKey", "candidateKey"));
            ObjectNode body = AnalysisJson.JSON.createObjectNode().put("retentionReason", decision.reason());
            body.set("interpretation", meaning);
            byte[] plaintext = body.toString().getBytes(StandardCharsets.UTF_8);
            UUID id = UUID.randomUUID();
            try {
                Flags flags = new Flags(decision.active(), decision.isReference(), decision.important(), decision.referencePolicy());
                prepared.add(new Prepared(id, item, flags, runtime.encrypt(owner, id, plaintext)));
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
     */
    public UUID save(UUID owner, ObjectNode input, String inputHash, List<Prepared> prepared, boolean recovery) {
        UUID resultId = UUID.randomUUID();
        Instant now = clock.instant();
        String kind = input.path("semanticTaskKind").asString();
        Map<String, AnalysisIdentity.Item> bound = new HashMap<>();
        identity.boundItems(finances.load(owner), input).forEach(item -> bound.put(item.itemKey(), item));
        ObjectNode header = row(owner, resultId).put("semantic_kind", kind).put("input_hash", inputHash)
            .put("committed_at", now.toString());
        ObjectNode provenance = (ObjectNode) input.path("context").deepCopy();
        provenance.set("versions", runtime.versions());
        provenance.put("analysisInputHash", inputHash);
        header.set("provenance", provenance);
        var manifest = header.putArray("accepted_manifest");
        for (Prepared value : prepared) {
            manifest.addObject().put("itemKey", value.identity().itemKey())
                .put("memoryKey", value.identity().key()).put("evidenceHash", bound.get(value.identity().itemKey()).evidenceHash());
        }
        repository.insert(RESULTS, owner, header);
        for (Prepared value : prepared) {
            AnalysisIdentity.Item current = bound.get(value.identity().itemKey());
            Map<String, ?> match = match(kind, current);
            if (repository.one(SUPPRESSIONS, owner, match).isPresent()) continue;
            Instant first = recovery ? now : repository.find(ITEMS, owner, match).stream()
                .map(item -> time(item, "stored_at")).min(Comparator.naturalOrder()).orElse(now);
            EncryptedMemory encrypted = value.encrypted();
            Flags decision = value.decision();
            ObjectNode stored = row(owner, value.id()).put("result_id", resultId.toString())
                .put("item_key", value.identity().itemKey()).put("semantic_kind", kind)
                .put("memory_key", current.key()).put("evidence_hash", current.evidenceHash())
                .put("stored_at", first.toString()).put("normal_expires_at", policy.normalExpiry(first).toString())
                .put("ciphertext", "\\x" + HexFormat.of().formatHex(encrypted.ciphertext()))
                .put("active", decision.active()).put("is_reference", decision.isReference())
                .put("important", decision.important()).put("reference_policy", decision.referencePolicy())
                .put("metadata_version", 1).put("policy_version", "PAYSE-MEMORY-1").put("policy_actor", "ai");
            stored.putObject("crypto_meta").put("keyRef", encrypted.key().keyRef())
                .put("wrappedKey", Base64.getEncoder().encodeToString(encrypted.key().ciphertext()))
                .put("nonce", Base64.getEncoder().encodeToString(encrypted.nonce()));
            repository.insert(ITEMS, owner, stored);
        }
        return resultId;
    }

    /**
     * 현재 입력과 사용자에 맞는 결과만 선택하고 복호화 전 이용 자격을 확인한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs의 결과 재사용·조회
     */
    public Selection select(UUID owner, ObjectNode input, UUID requested) {
        List<AnalysisIdentity.Item> wantedItems = identity.boundItems(finances.load(owner), input);
        Set<String> blocked = new HashSet<>();
        repository.suppressions(owner, input.path("semanticTaskKind").asString(),
            wantedItems.stream().map(AnalysisIdentity.Item::key).toList()).forEach(row ->
                blocked.add(row.path("memory_key").asString() + ":" + row.path("evidence_hash").asString()));
        List<ObjectNode> candidates;
        if (requested != null) {
            ObjectNode result = repository.one(RESULTS, owner, Map.of("id", requested))
                .orElseThrow(() -> new FinancialException(403, "RESOURCE_FORBIDDEN"));
            candidates = List.of(result);
        } else {
            candidates = repository.results(owner, input.path("semanticTaskKind").asString(),
                wantedItems.stream().map(AnalysisIdentity.Item::key).toList());
        }
        Selection best = new Selection(null, List.of(), "missing");
        for (ObjectNode header : candidates) {
            Map<String, ObjectNode> memories = new HashMap<>();
            for (ObjectNode memory : repository.find(ITEMS, owner, Map.of("result_id", uuid(header, "id")))) {
                if (memories.put(memory.path("memory_key").asString(), memory) != null) {
                    throw new IllegalStateException("Repeated result identity");
                }
            }
            List<Entry> entries = new ArrayList<>();
            int available = 0;
            for (var wanted : wantedItems) {
                ObjectNode memory = memories.get(wanted.key());
                String state = availability(header, memory, wanted, input,
                    blocked.contains(wanted.key() + ":" + wanted.evidenceHash()));
                if (state.equals("available")) available++;
                entries.add(new Entry(wanted, memory, state));
            }
            String state = available == entries.size() ? "available" : available > 0 ? "partial" : "missing";
            Selection choice = new Selection(header, entries, state);
            if (state.equals("available")) return choice;
            if (best.header() == null || (!best.state().equals("partial") && state.equals("partial"))) best = choice;
        }
        return best;
    }

    /**
     * 삭제·만료·비활성·관련 근거를 독립 판정하고 실제 사유를 유지한다.
     * @created 2026-11-01
     * @usedBy select
     */
    private String availability(ObjectNode header, ObjectNode memory,
            AnalysisIdentity.Item wanted, ObjectNode input, boolean blocked) {
        if (blocked) {
            return "deleted";
        }
        if (memory == null) return "missing";
        if (!memory.path("deleted_at").isNull() && memory.has("deleted_at")) return "deleted";
        if (memory.path("purge_requested_at").isString()) return "expired";
        if (!memory.path("important").asBoolean() && !clock.instant().isBefore(time(memory, "normal_expires_at"))) return "expired";
        if (!memory.path("active").asBoolean()) return "inactive";
        if (!memory.path("evidence_hash").asString().equals(wanted.evidenceHash())
                || !header.path("provenance").path("versions").equals(runtime.versions())
                || !header.path("provenance").path("ruleVersion").equals(input.path("context").path("ruleVersion"))
                || !header.path("provenance").path("schemaVersion").equals(input.path("context").path("schemaVersion"))) return "stale";
        return "available";
    }

    /**
     * DB 잠금 밖에서 허용된 기억만 복호화하며 반환 직전 호출자가 자격을 다시 확인한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.query
     */
    public Map<UUID, ObjectNode> decrypt(UUID owner, Selection selection) {
        Map<UUID, ObjectNode> bodies = new HashMap<>();
        for (Entry entry : selection.entries()) {
            if (!entry.state().equals("available")) continue;
            ObjectNode memory = entry.memory();
            JsonNode meta = memory.path("crypto_meta");
            EncryptedMemory encrypted = new EncryptedMemory(
                HexFormat.of().parseHex(memory.path("ciphertext").asString().substring(2)),
                Base64.getDecoder().decode(meta.path("nonce").asString()),
                new WrappedKey(meta.path("keyRef").asString(), Base64.getDecoder().decode(meta.path("wrappedKey").asString())));
            UUID id = uuid(memory, "id");
            byte[] plaintext = runtime.decrypt(owner, id, encrypted);
            try { bodies.put(id, (ObjectNode) AnalysisJson.JSON.readTree(plaintext)); }
            finally { Arrays.fill(plaintext, (byte) 0); }
        }
        return bodies;
    }

    /**
     * 현재 itemKey로 복원하며 사용할 수 없는 항목은 본문 없이 사유만 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.query
     */
    public ObjectNode response(ObjectNode input, Selection selection, Map<UUID, ObjectNode> bodies) {
        ObjectNode response = AnalysisJson.JSON.createObjectNode().put("contractVersion", "PAYSE-ANALYSIS-1")
            .put("resultAvailability", selection.state());
        response.set("context", input.path("context").deepCopy());
        if (selection.header() == null) return response;
        response.set("resultId", selection.header().get("id"));
        ObjectNode publicProvenance = response.putObject("provenance");
        JsonNode storedProvenance = selection.header().get("provenance");
        for (String field : List.of("schemaVersion", "dataVersion", "sourceVersion", "ruleVersion", "asOf", "versions", "analysisInputHash")) {
            if (storedProvenance.has(field)) publicProvenance.set(field, storedProvenance.get(field).deepCopy());
        }
        ObjectNode result = response.putObject("result").put("meaningPolicyVersion", "PAYSE-MEANING-1");
        var items = result.putArray("items");
        var statuses = result.putArray("itemAvailability");
        ObjectNode validationOutput = AnalysisJson.JSON.createObjectNode().put("meaningPolicyVersion", "PAYSE-MEANING-1");
        var validationMeanings = validationOutput.putArray("items");
        for (Entry entry : selection.entries()) {
            ObjectNode status = statuses.addObject().put("itemKey", entry.identity().itemKey()).put("state", entry.state());
            if (entry.memory() != null) status.set("itemId", entry.memory().get("id"));
            if (!entry.state().equals("available")) continue;
            UUID id = uuid(entry.memory(), "id");
            ObjectNode body = bodies.get(id);
            if (body == null) throw new IllegalStateException("Memory changed during result delivery");
            ObjectNode meaning = (ObjectNode) body.path("interpretation").deepCopy();
            meaning.put("itemKey", entry.identity().itemKey());
            for (JsonNode item : input.path("items")) {
                if (item.path("itemKey").asString().equals(entry.identity().itemKey())) {
                    if (!item.path("candidateKey").isNull()) {
                        meaning.set("candidateKey", item.get("candidateKey"));
                    }
                }
            }
            validationMeanings.add(meaning.deepCopy());
            ObjectNode returned = items.addObject().put("itemId", id.toString());
            returned.set("interpretation", meaning);
            returned.put("retentionReason", body.path("retentionReason").asString());
            for (String flag : List.of("active", "important")) returned.set(flag, entry.memory().get(flag));
            returned.set("isReference", entry.memory().get("is_reference"));
            returned.set("referencePolicy", entry.memory().get("reference_policy"));
            returned.set("storedAt", entry.memory().get("stored_at"));
            returned.set("normalExpiresAt", entry.memory().get("normal_expires_at"));
        }
        if (!validationMeanings.isEmpty()) new com.payse.ai.analysis.validation.AnalysisContract().outputSubset(input, validationOutput);
        return response;
    }

    /**
     * 같은 기억·근거의 모든 사본을 원자 차단하고 암호문과 감싼 데이터 키를 제거한다.
     * @created 2026-11-01
     * @usedBy AnalysisJobs.deleteMemory
     */
    public void delete(UUID owner, UUID id) {
        ObjectNode item = repository.one(ITEMS, owner, Map.of("id", id))
            .orElseThrow(() -> new FinancialException(403, "RESOURCE_FORBIDDEN"));
        Map<String, ?> match = Map.of("semantic_kind", item.path("semantic_kind").asString(),
            "memory_key", item.path("memory_key").asString(), "evidence_hash", item.path("evidence_hash").asString());
        if (repository.one(SUPPRESSIONS, owner, match).isEmpty()) {
            ObjectNode block = AnalysisJson.JSON.createObjectNode().put("user_id", owner.toString())
                .put("blocked_at", clock.instant().toString());
            match.forEach((key, value) -> block.put(key, value.toString()));
            repository.insert(SUPPRESSIONS, owner, block);
        }
        for (ObjectNode copy : repository.find(ITEMS, owner, match)) {
            if (!copy.path("deleted_at").isNull()) continue;
            ObjectNode change = AnalysisJson.JSON.createObjectNode().put("deleted_at", clock.instant().toString())
                .put("purge_requested_at", clock.instant().toString()).put("active", false)
                .put("metadata_version", Math.addExact(copy.path("metadata_version").asLong(), 1));
            change.putNull("ciphertext").putNull("crypto_meta");
            repository.update(ITEMS, owner, uuid(copy, "id"), change);
        }
    }

    /**
     * 같은 사용자 안에서 기억 삭제·재저장 조건을 구성한다.
     * @created 2026-11-01
     * @usedBy save, availability
     */
    private Map<String, ?> match(String kind, AnalysisIdentity.Item item) {
        return Map.of("semantic_kind", kind, "memory_key", item.key(), "evidence_hash", item.evidenceHash());
    }

    /**
     * 서버 생성 행 ID와 인증 소유자만 초기화한다.
     * @created 2026-11-01
     * @usedBy save, AnalysisJobs
     */
    static ObjectNode row(UUID owner, UUID id) {
        return AnalysisJson.JSON.createObjectNode().put("id", id.toString()).put("user_id", owner.toString());
    }

    /**
     * DB가 타입을 검증한 UUID를 복원한다.
     * @created 2026-11-01
     * @usedBy AnalysisResults, AnalysisJobs
     */
    static UUID uuid(JsonNode row, String key) { return UUID.fromString(row.path(key).asString()); }

    /**
     * PostgreSQL JSON의 오프셋 시각을 Instant로 통일한다.
     * @created 2026-11-01
     * @usedBy AnalysisResults, AnalysisJobs
     */
    static Instant time(JsonNode row, String key) { return java.time.OffsetDateTime.parse(row.path(key).asString()).toInstant(); }

    /**
     * 암호화 이후 짧은 DB 채택 처리로 전달할 항목과 보존 플래그다.
     * @created 2026-11-01
     * @usedBy prepare, save
     */
    public record Prepared(UUID id, AnalysisIdentity.Item identity, Flags decision, EncryptedMemory encrypted) {
        /**
         * 암호문·근거 정보를 자동 로그로 출력하지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "Prepared[REDACTED]"; }
    }

    /**
     * 보존 사유는 암호화하고 이 타입에는 허용된 플래그만 남긴다.
     * @created 2026-11-01
     * @usedBy Prepared, save
     */
    public record Flags(boolean active, boolean isReference, boolean important, String referencePolicy) {}

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
        @Override public String toString() { return "Entry[REDACTED]"; }
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
        @Override public String toString() { return "Selection[REDACTED]"; }
    }
}
