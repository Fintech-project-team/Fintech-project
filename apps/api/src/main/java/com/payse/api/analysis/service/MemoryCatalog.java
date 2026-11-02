package com.payse.api.analysis.service;

import static com.payse.api.analysis.service.AnalysisResults.time;
import static com.payse.api.analysis.service.AnalysisResults.uuid;

import com.payse.api.analysis.mapper.AnalysisRepository;
import com.payse.api.analysis.vo.MemoryQuery;
import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants.Analysis;
import com.payse.api.constants.ApiFieldConstants.AnalysisDb;
import com.payse.api.constants.ApiFieldConstants.Finance;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.constants.ApiMessageConstants;
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
    public MemoryCatalog(
        AuthTransactions transactions,
        AuthRepository auth,
        AuthCrypto crypto,
        FinancialRepository finances,
        AnalysisRepository repository,
        AnalysisResults results,
        FinancialCursor cursors,
        Clock clock
    ) {
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
     * @modified 2026-11-02 - 기존 상수 재사용 및 복호화 전후 검증 순서를 보존한 식 정리
     */
    public ObjectNode read(String token, Supplier<MemoryQuery> query) {
        Page before = authenticated(token, session -> select(session, query.get()));
        Map<UUID, ObjectNode> bodies = new HashMap<>();
        for (Entry entry : before.entries()) {
            if (entry.state().equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                UUID itemId = uuid(entry.row(), AnalysisDb.ID);
                ObjectNode body = results.decryptMemory(before.owner(), entry.row());
                bodies.put(itemId, body);
            }
        }

        return authenticated(
            token,
            session -> {
                Page after = select(session, before.query());
                if (!before.context().equals(after.context())
                    || !before.entries().equals(after.entries())
                    || !before.session().equals(after.session())) {
                    throw new FinancialException(409, ApiCodeConstants.Analysis.STALE_DATA);
                }

                return response(after, bodies);
            }
        );
    }

    /**
     * SQL에서 기간·ID 페이지를 한정하고 본문과 분리된 문맥·현재 접근 자격을 확인한다.
     * @created 2026-11-01
     * @usedBy read
     * @modified 2026-11-02 - 기존 필드 상수를 재사용하고 조회·페이지 구성 단계를 정리
     */
    private Page select(AuthRows.Session session, MemoryQuery query) {
        UUID owner = session.userId();
        ObjectNode source = finances.load(owner);
        Set<String> connected = new HashSet<>();
        for (JsonNode link : source.path(Analysis.INSTITUTION_LINKS)) {
            if (link.path(Analysis.DISCONNECTED_AT).isNull()) {
                connected.add(link.path(Analysis.INSTITUTION_CODE).asString());
            }
        }

        ObjectNode context = AnalysisJson.JSON.createObjectNode()
            .put(ApiFieldConstants.Analysis.PURPOSE, ApiConfigConstants.Analysis.MEMORIES_PURPOSE)
            .put(Finance.SIZE, PAGE_SIZE)
            .put(ApiFieldConstants.Analysis.FINANCE, cursors.context(source, connected));
        String memoryContext = repository.memoryContext(
            owner,
            query.start(),
            query.end(),
            clock.instant()
        );
        context.put(ApiFieldConstants.Analysis.MEMORIES, memoryContext);
        context.put(
            ApiFieldConstants.Analysis.START_DATE,
            query.startDate() == null ? null : query.startDate().toString()
        );
        context.put(
            ApiFieldConstants.Analysis.END_DATE,
            query.endDate() == null ? null : query.endDate().toString()
        );
        String digest = AnalysisJson.digest(context);
        UUID afterId = query.cursor() == null ? null
            : cursors.decode(
                query.cursor(),
                owner,
                session.sessionId(),
                digest,
                PAGE_SIZE
            );
        List<ObjectNode> found = repository.memoryPage(
            owner,
            query.start(),
            query.end(),
            afterId,
            PAGE_SIZE
        );

        boolean hasMore = found.size() > PAGE_SIZE;
        List<ObjectNode> rows = found.subList(0, Math.min(PAGE_SIZE, found.size()));
        Set<String> blocked = blocked(owner, rows);
        List<Entry> entries = new ArrayList<>();
        for (ObjectNode row : rows) {
            boolean isBlocked = blocked.contains(blockKey(row));
            entries.add(entry(owner, source, row, isBlocked));
        }

        String next = hasMore ? cursors.encode(
            owner,
            session.sessionId(),
            digest,
            uuid(rows.getLast(), AnalysisDb.ID),
            PAGE_SIZE
        ) : null;
        return new Page(
            owner,
            session.sessionId(),
            query,
            digest,
            List.copyOf(entries),
            next
        );
    }

    /**
     * 같은 페이지의 업무별 삭제 차단을 묶어 조회하여 항목별 SQL 반복을 피한다.
     * @created 2026-11-01
     * @usedBy select
     * @modified 2026-11-02 - 기존 DB 필드 상수를 재사용하고 묶음 조회 식 정리
     */
    private Set<String> blocked(UUID owner, List<ObjectNode> rows) {
        Map<String, List<String>> keys = new HashMap<>();
        for (ObjectNode row : rows) {
            keys.computeIfAbsent(
                row.path(AnalysisDb.SEMANTIC_KIND).asString(),
                ignored -> new ArrayList<>()
            ).add(row.path(AnalysisDb.MEMORY_KEY).asString());
        }

        Set<String> blocked = new HashSet<>();
        keys.forEach(
            (kind, values) -> {
                List<ObjectNode> suppressions = repository.suppressions(owner, kind, values);
                suppressions.forEach(row -> blocked.add(blockKey(row)));
            }
        );
        return blocked;
    }

    /**
     * 삭제·만료·현재 근거 권한을 본문 복호화 전에 확인하며 비활성은 관리 열람을 막지 않는다.
     * @created 2026-11-01
     * @usedBy select
     * @modified 2026-11-02 - 기존 상태·DB 상수를 재사용하고 만료 조건의 단락 평가 유지
     */
    private Entry entry(UUID owner, ObjectNode source, ObjectNode row, boolean blocked) {
        if (blocked || !row.path(AnalysisDb.DELETED_AT).isNull()) {
            return new Entry(row, ApiCodeConstants.Analysis.DELETED, null);
        }
        if (!row.path(AnalysisDb.PURGE_REQUESTED_AT).isNull()
            || (!row.path(Analysis.IMPORTANT).asBoolean()
                && !clock.instant().isBefore(time(row, AnalysisDb.NORMAL_EXPIRES_AT)))) {
            return new Entry(row, ApiCodeConstants.Analysis.EXPIRED, null);
        }
        if (row.path(ApiFieldConstants.AnalysisDb.SOURCE_REFS).isNull()
            || row.path(ApiFieldConstants.AnalysisDb.SOURCE_HASH).isNull()) {
            return new Entry(row, ApiCodeConstants.Analysis.UNVERIFIED, null);
        }

        List<UUID> refs = new ArrayList<>();
        for (JsonNode id : row.path(ApiFieldConstants.AnalysisDb.SOURCE_REFS)) {
            refs.add(UUID.fromString(id.asString()));
        }

        try {
            evidence.references(owner, source, refs);
        } catch (FinancialException failure) {
            if (failure.status() == 403) {
                return new Entry(row, ApiCodeConstants.Analysis.RESTRICTED, null);
            }

            throw failure;
        }

        return new Entry(
            row,
            ApiCodeConstants.Analysis.AVAILABLE,
            identity.referenceHash(source, refs)
        );
    }

    /**
     * 허용한 관리 메타만 공개하며 권한이 있는 본문에도 실제 적용 자격은 unchecked로 남긴다.
     * @created 2026-11-01
     * @usedBy read
     * @modified 2026-11-02 - 기존 응답·DB·상태 상수를 재사용하고 응답 구성 식 정리
     */
    private ObjectNode response(Page page, Map<UUID, ObjectNode> bodies) {
        ObjectNode response = AnalysisJson.JSON.createObjectNode()
            .put(
                Analysis.CONTRACT_VERSION,
                ApiConfigConstants.Analysis.ANALYSIS_CONTRACT
            );
        var items = response.putArray(Analysis.ITEMS);
        for (Entry entry : page.entries()) {
            ObjectNode row = entry.row();
            ObjectNode item = items.addObject()
                .put(Analysis.ITEM_ID, row.path(AnalysisDb.ID).asString())
                .put(Analysis.RESULT_ID, row.path(AnalysisDb.RESULT_ID).asString())
                .put(Analysis.SEMANTIC_TASK_KIND, row.path(AnalysisDb.SEMANTIC_KIND).asString())
                .put(ApiFieldConstants.Analysis.CONTENT_AVAILABILITY, entry.state())
                .put(Analysis.RESULT_AVAILABILITY, ApiCodeConstants.Analysis.UNCHECKED)
                .put(Analysis.ACTIVE, row.path(Analysis.ACTIVE).asBoolean())
                .put(Analysis.IS_REFERENCE, row.path(AnalysisDb.IS_REFERENCE).asBoolean())
                .put(Analysis.IMPORTANT, row.path(Analysis.IMPORTANT).asBoolean())
                .put(Analysis.REFERENCE_POLICY, row.path(AnalysisDb.REFERENCE_POLICY).asString())
                .put(Analysis.STORED_AT, time(row, AnalysisDb.STORED_AT).toString())
                .put(Analysis.NORMAL_EXPIRES_AT, time(row, AnalysisDb.NORMAL_EXPIRES_AT).toString())
                .put(
                    ApiFieldConstants.Analysis.METADATA_VERSION,
                    row.path(AnalysisDb.METADATA_VERSION).asLong()
                );
            if (!entry.state().equals(ApiCodeConstants.Analysis.AVAILABLE)) {
                continue;
            }

            ObjectNode body = bodies.get(uuid(row, AnalysisDb.ID));
            if (body == null) {
                throw new IllegalStateException(ApiMessageConstants.Analysis.MISSING_MEMORY_BODY);
            }

            item.set(Analysis.INTERPRETATION, body.path(Analysis.INTERPRETATION).deepCopy());
            item.set(Analysis.RETENTION_REASON, body.path(Analysis.RETENTION_REASON).deepCopy());
            boolean sourceChanged = !entry.sourceHash()
                .equals(row.path(ApiFieldConstants.AnalysisDb.SOURCE_HASH).asString());
            item.put(ApiFieldConstants.Analysis.SOURCE_CHANGED, sourceChanged);
        }

        response.putObject(ApiFieldConstants.Analysis.PAGE_INFO)
            .put(Finance.NEXT_CURSOR, page.nextCursor())
            .put(ApiFieldConstants.Analysis.HAS_MORE, page.nextCursor() != null);
        return response;
    }

    /**
     * 파서 실행보다 토큰·세션·계정 잠금 및 소유자 RLS 설정을 먼저 수행한다.
     * @created 2026-11-01
     * @usedBy read
     * @modified 2026-11-02 - 기존 인증 오류 상수를 재사용하고 토큰 실패 처리 순서 유지
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
                return operation.apply(session);
            }
        );
    }

    /**
     * 업무 종류가 다른 동일 지문을 혼동하지 않는 내부 삭제 차단 키다.
     * @created 2026-11-01
     * @usedBy blocked, select
     * @modified 2026-11-02 - 기존 DB 필드 상수 재사용
     */
    private String blockKey(JsonNode row) {
        return row.path(AnalysisDb.SEMANTIC_KIND).asString() + ":"
            + row.path(AnalysisDb.MEMORY_KEY).asString() + ":"
            + row.path(AnalysisDb.EVIDENCE_HASH).asString();
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
        @Override
        public String toString() {
            return ApiMessageConstants.Analysis.MEMORY_ENTRY_REDACTED;
        }
    }

    /**
     * 한 요청의 인증·기간·페이지 상태이며 공유 필드나 DB에 저장하지 않는다.
     * @created 2026-11-01
     * @usedBy select, read
     */
    private record Page(
        UUID owner,
        UUID session,
        MemoryQuery query,
        String context,
        List<Entry> entries,
        String nextCursor
    ) {
        /**
         * 사용자·암호문·페이지 토큰을 자동 로그에 남기지 않는다.
         * @created 2026-11-01
         * @usedBy Java 문자열 변환
         */
        @Override
        public String toString() {
            return ApiMessageConstants.Analysis.MEMORY_PAGE_REDACTED;
        }
    }
}
