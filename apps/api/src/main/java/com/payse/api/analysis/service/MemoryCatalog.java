package com.payse.api.analysis.service;

import static com.payse.api.analysis.service.AnalysisResults.time;
import static com.payse.api.analysis.service.AnalysisResults.uuid;

import com.payse.api.analysis.mapper.AnalysisRepository;
import com.payse.api.analysis.vo.MemoryQuery;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialRepository;
import com.payse.api.finance.service.FinancialCursor;
import java.time.Clock;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Function;
import java.util.function.Supplier;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Service;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 날짜별 기억 관리 목록을 제공한다. 현재 분석 입력이 없으므로 재사용 가능으로 판정하지 않는다.
 * @created 2026-11-01
 * @usedBy MemoryController.list
 */
@Service
@Profile("database & auth & finance & analysis")
public final class MemoryCatalog {
    private static final int PAGE_SIZE = 20;
    private final AuthTransactions transactions;
    private final AuthRepository auth;
    private final AuthCrypto crypto;
    private final FinancialRepository finances;
    private final AnalysisRepository repository;
    private final AnalysisResults results;
    private final FinancialCursor cursors;
    private final Clock clock;
    private final AnalysisIdentity identity = new AnalysisIdentity();
    private final AnalysisEvidence evidence = new AnalysisEvidence();

    /**
     * 기존 사용자 잠금·RLS·암호화 서비스를 재사용하고 요청 상태는 필드에 남기지 않는다.
     * @created 2026-11-01
     * @usedBy Spring 생성자 주입
     */
    public MemoryCatalog(AuthTransactions transactions, AuthRepository auth, AuthCrypto crypto,
            FinancialRepository finances, AnalysisRepository repository, AnalysisResults results,
            FinancialCursor cursors, Clock clock) {
        this.transactions = transactions;
        this.auth = auth;
        this.crypto = crypto;
        this.finances = finances;
        this.repository = repository;
        this.results = results;
        this.cursors = cursors;
        this.clock = clock;
    }

    /**
     * DB 밖에서 페이지 본문만 복호화한 뒤 인증·권한·만료·삭제를 다시 검사한다.
     * @created 2026-11-01
     * @usedBy MemoryController.list
     */
    public ObjectNode read(String token, Supplier<MemoryQuery> query) {
        Page before = authenticated(token, session -> select(session, query.get()));
        Map<UUID, ObjectNode> bodies = new HashMap<>();
        for (Entry entry : before.entries()) {
            if (entry.state().equals("available")) {
                bodies.put(uuid(entry.row(), "id"), results.decryptMemory(before.owner(), entry.row()));
            }
        }
        return authenticated(token, session -> {
            Page after = select(session, before.query());
            if (!before.context().equals(after.context()) || !before.entries().equals(after.entries())
                    || !before.session().equals(after.session())) {
                throw new FinancialException(409, "STALE_DATA");
            }
            return response(after, bodies);
        });
    }

    /**
     * SQL에서 기간·ID 페이지를 한정하고 본문과 분리된 문맥·현재 접근 자격을 확인한다.
     * @created 2026-11-01
     * @usedBy read
     */
    private Page select(AuthRows.Session session, MemoryQuery query) {
        UUID owner = session.userId();
        ObjectNode source = finances.load(owner);
        Set<String> connected = new HashSet<>();
        for (JsonNode link : source.path("institutionLinks")) {
            if (link.path("disconnectedAt").isNull()) connected.add(link.path("institutionCode").asString());
        }
        ObjectNode context = AnalysisJson.JSON.createObjectNode().put("purpose", "analysis-memories")
            .put("size", PAGE_SIZE).put("finance", cursors.context(source, connected))
            .put("memories", repository.memoryContext(owner, query.start(), query.end(), clock.instant()));
        context.put("startDate", query.startDate() == null ? null : query.startDate().toString());
        context.put("endDate", query.endDate() == null ? null : query.endDate().toString());
        String digest = AnalysisJson.digest(context);
        UUID afterId = query.cursor() == null ? null
            : cursors.decode(query.cursor(), owner, session.sessionId(), digest, PAGE_SIZE);
        List<ObjectNode> found = repository.memoryPage(owner, query.start(), query.end(), afterId, PAGE_SIZE);
        boolean hasMore = found.size() > PAGE_SIZE;
        List<ObjectNode> rows = found.subList(0, Math.min(PAGE_SIZE, found.size()));
        Set<String> blocked = blocked(owner, rows);
        List<Entry> entries = new ArrayList<>();
        for (ObjectNode row : rows) entries.add(entry(owner, source, row, blocked.contains(blockKey(row))));
        String next = hasMore ? cursors.encode(owner, session.sessionId(), digest,
            uuid(rows.getLast(), "id"), PAGE_SIZE) : null;
        return new Page(owner, session.sessionId(), query, digest, List.copyOf(entries), next);
    }

    /**
     * 같은 페이지의 업무별 삭제 차단을 묶어 조회하여 항목별 SQL 반복을 피한다.
     * @created 2026-11-01
     * @usedBy select
     */
    private Set<String> blocked(UUID owner, List<ObjectNode> rows) {
        Map<String, List<String>> keys = new HashMap<>();
        for (ObjectNode row : rows) keys.computeIfAbsent(row.path("semantic_kind").asString(), ignored -> new ArrayList<>())
            .add(row.path("memory_key").asString());
        Set<String> blocked = new HashSet<>();
        keys.forEach((kind, values) -> repository.suppressions(owner, kind, values).forEach(row -> blocked.add(blockKey(row))));
        return blocked;
    }

    /**
     * 삭제·만료·현재 근거 권한을 본문 복호화 전에 확인하며 비활성은 관리 열람을 막지 않는다.
     * @created 2026-11-01
     * @usedBy select
     */
    private Entry entry(UUID owner, ObjectNode source, ObjectNode row, boolean blocked) {
        if (blocked || !row.path("deleted_at").isNull()) return new Entry(row, "deleted", null);
        if (!row.path("purge_requested_at").isNull()
                || (!row.path("important").asBoolean() && !clock.instant().isBefore(time(row, "normal_expires_at")))) {
            return new Entry(row, "expired", null);
        }
        if (row.path("source_refs").isNull() || row.path("source_hash").isNull()) return new Entry(row, "unverified", null);
        List<UUID> refs = new ArrayList<>();
        for (JsonNode id : row.path("source_refs")) refs.add(UUID.fromString(id.asString()));
        try { evidence.references(owner, source, refs); }
        catch (FinancialException failure) {
            if (failure.status() == 403) return new Entry(row, "restricted", null);
            throw failure;
        }
        return new Entry(row, "available", identity.referenceHash(source, refs));
    }

    /**
     * 허용한 관리 메타만 공개하며 권한이 있는 본문에도 실제 적용 자격은 unchecked로 남긴다.
     * @created 2026-11-01
     * @usedBy read
     */
    private ObjectNode response(Page page, Map<UUID, ObjectNode> bodies) {
        ObjectNode response = AnalysisJson.JSON.createObjectNode().put("contractVersion", "PAYSE-ANALYSIS-1");
        var items = response.putArray("items");
        for (Entry entry : page.entries()) {
            ObjectNode row = entry.row();
            ObjectNode item = items.addObject().put("itemId", row.path("id").asString())
                .put("resultId", row.path("result_id").asString()).put("semanticTaskKind", row.path("semantic_kind").asString())
                .put("contentAvailability", entry.state()).put("resultAvailability", "unchecked")
                .put("active", row.path("active").asBoolean()).put("isReference", row.path("is_reference").asBoolean())
                .put("important", row.path("important").asBoolean()).put("referencePolicy", row.path("reference_policy").asString())
                .put("storedAt", time(row, "stored_at").toString()).put("normalExpiresAt", time(row, "normal_expires_at").toString())
                .put("metadataVersion", row.path("metadata_version").asLong());
            if (!entry.state().equals("available")) continue;
            ObjectNode body = bodies.get(uuid(row, "id"));
            if (body == null) throw new IllegalStateException("Missing authorized memory body");
            item.set("interpretation", body.path("interpretation").deepCopy());
            item.set("retentionReason", body.path("retentionReason").deepCopy());
            item.put("sourceChanged", !entry.sourceHash().equals(row.path("source_hash").asString()));
        }
        response.putObject("pageInfo").put("nextCursor", page.nextCursor()).put("hasMore", page.nextCursor() != null);
        return response;
    }

    /**
     * 파서 실행보다 토큰·세션·계정 잠금 및 소유자 RLS 설정을 먼저 수행한다.
     * @created 2026-11-01
     * @usedBy read
     */
    private <T> T authenticated(String token, Function<AuthRows.Session, T> operation) {
        return transactions.run(() -> {
            String digest;
            try { digest = crypto.tokenDigest(token); }
            catch (IllegalArgumentException failure) { digest = null; }
            AuthRows.Session session = auth.authorize(digest)
                .orElseThrow(() -> new FinancialException(401, "SESSION_INVALID"));
            return operation.apply(session);
        });
    }

    /**
     * 업무 종류가 다른 동일 지문을 혼동하지 않는 내부 삭제 차단 키다.
     * @created 2026-11-01
     * @usedBy blocked, select
     */
    private String blockKey(JsonNode row) {
        return row.path("semantic_kind").asString() + ":" + row.path("memory_key").asString() + ":" + row.path("evidence_hash").asString();
    }

    /**
     * 비공개 DB 행과 검증 상태를 복호화 전후 비교한다.
     * @created 2026-11-01
     * @usedBy select, read
     */
    private record Entry(ObjectNode row, String state, String sourceHash) {
        /**
         * 암호문·근거 지문을 자동 로그에 남기지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "Entry[REDACTED]"; }
    }

    /**
     * 한 요청의 인증·기간·페이지 상태이며 공유 필드나 DB에 저장하지 않는다.
     * @created 2026-11-01
     * @usedBy select, read
     */
    private record Page(UUID owner, UUID session, MemoryQuery query, String context, List<Entry> entries, String nextCursor) {
        /**
         * 사용자·암호문·페이지 토큰을 자동 로그에 남기지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override public String toString() { return "Page[REDACTED]"; }
    }
}
