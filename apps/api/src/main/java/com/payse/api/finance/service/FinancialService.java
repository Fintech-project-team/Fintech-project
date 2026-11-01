package com.payse.api.finance.service;

import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.finance.dto.StoredReceipt;
import com.payse.api.finance.dto.WriteChange;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialReceipts;
import com.payse.api.finance.mapper.FinancialRepository;
import com.payse.api.finance.mapper.FinancialWrites;
import com.payse.api.finance.service.FinancialProjection;
import com.payse.api.finance.validation.FinancialInput;
import jakarta.persistence.PersistenceException;
import java.util.HashSet;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;
import org.springframework.context.annotation.Profile;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.orm.jpa.vendor.HibernateJpaDialect;
import org.springframework.stereotype.Service;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 인증된 DB 자료의 조회·설정 저장을 조립한다. 급여일·가용 금액·AI 판단은 계산하지 않는다.
 * @created 2026-10-29
 * @usedBy FinancialController
 */
@Service
@Profile("database & auth & finance")
public final class FinancialService {
    private final AuthTransactions transactions;
    private final AuthRepository auth;
    private final AuthCrypto crypto;
    private final FinancialRepository repository;
    private final FinancialWrites writes;
    private final FinancialReceipts receipts;
    private final FinancialCursor cursors;
    private final FinancialProjection projection = new FinancialProjection();
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 무상태 서비스·저장소를 주입한다. 사용자 자료는 메서드 지역 변수에만 둔다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입
     */
    public FinancialService(AuthTransactions transactions, AuthRepository auth, AuthCrypto crypto,
            FinancialRepository repository, FinancialWrites writes, FinancialReceipts receipts,
            FinancialCursor cursors) {
        this.transactions = transactions;
        this.auth = auth;
        this.crypto = crypto;
        this.repository = repository;
        this.writes = writes;
        this.receipts = receipts;
        this.cursors = cursors;
    }

    /**
     * 사용자 잠금·현재 세션을 확인한 동일 트랜잭션에서 첫/후속 페이지를 읽는다.
     * @created 2026-10-29
     * @usedBy FinancialController.snapshot, page
     */
    public ObjectNode read(String token, Supplier<String> cursor, boolean pageOnly) {
        return transactions.run(() -> {
            AuthRows.Session session = authorize(token);
            return snapshot(repository.load(session.userId()), session, cursor.get(), pageOnly);
        });
    }

    /**
     * 형식→멱등→새 요청 버전·권한→저장·영수증을 원자 처리하고 최신 자료를 별도 조회한다.
     * @created 2026-10-29
     * @usedBy FinancialController.write
     */
    public ObjectNode write(String token, String method, String path, Supplier<JsonNode> body) {
        WriteResult result = transactions.run(() -> {
            AuthRows.Session session = authorize(token);
            ObjectNode input = FinancialInput.validate(method, path, body.get());
            String route = canonicalPath(path);
            String key = input.get("idempotencyKey").asString();
            String digest = FinancialJson.requestDigest(method, route, input);
            var existing = receipts.find(session.userId(), key, digest);
            if (existing.isPresent()) {
                return new WriteResult(existing.get(), true);
            }
            ObjectNode source = repository.load(session.userId());
            if (!input.get("expectedDataVersion").equals(source.get("dataVersion"))) {
                throw new FinancialException(409, "STALE_DATA");
            }
            if (!input.get("ruleVersion").equals(source.get("ruleVersion"))) {
                throw new FinancialException(409, "RULE_VERSION_MISMATCH");
            }
            try {
                WriteChange change = writes.apply(session.userId(), method, route, input);
                StoredReceipt receipt = receipts.save(session.userId(), key, digest, method + " " + route,
                    change.changedRefs(), change.beforeAfter());
                receipts.checkConstraints();
                return new WriteResult(receipt, false);
            } catch (DataIntegrityViolationException failure) {
                throw new FinancialException(409, "RELATION_CONFLICT");
            } catch (PersistenceException failure) {
                if (new HibernateJpaDialect().translateExceptionIfPossible(failure)
                        instanceof DataIntegrityViolationException) {
                    throw new FinancialException(409, "RELATION_CONFLICT");
                }
                throw new FinancialException(503, "TEMPORARILY_UNAVAILABLE");
            }
        });
        // 이미 성공한 저장은 이후 응답 조립 실패로 되돌리지 않는다. 동일 키 재시도로 복구한다.
        ObjectNode snapshot = read(token, () -> null, false);
        ObjectNode receipt = result.stored().receipt();
        receipt.set("changedRefs", visibleRefs((ArrayNode) receipt.get("changedRefs"), snapshot, result.stored().audit()));
        ObjectNode response = json.createObjectNode().put("replayed", result.replayed());
        response.set("receipt", receipt);
        response.set("snapshot", snapshot);
        return response;
    }

    /**
     * 형식이 틀린 토큰도 DB 인증 함수로 보내 이전 문맥을 비우며 동일 401로 거절한다.
     * @created 2026-10-29
     * @usedBy read, write
     */
    private AuthRows.Session authorize(String token) {
        String digest;
        try { digest = crypto.tokenDigest(token); }
        catch (IllegalArgumentException failure) { digest = null; }
        return auth.authorize(digest).orElseThrow(() -> new FinancialException(401, "SESSION_INVALID"));
    }

    /**
     * 저장 원천에서 공개 범위와 페이지를 조립하고 서명된 위치를 추가한다.
     * @created 2026-10-29
     * @usedBy read
     */
    private ObjectNode snapshot(ObjectNode source, AuthRows.Session session, String cursor, boolean pageOnly) {
        Set<String> codes = new HashSet<>();
        for (JsonNode link : source.path("institutionLinks")) {
            if (link.path("disconnectedAt").isNull()) codes.add(link.path("institutionCode").asString());
        }
        String context = cursors.context(source, codes);
        UUID after = pageOnly ? cursors.decode(cursor, session.userId(), session.sessionId(), context) : null;
        var slice = projection.project(source, codes, source.get("dataVersion").asString(), after, pageOnly);
        ObjectNode answer = slice.body();
        if (answer.has("page")) {
            ObjectNode page = (ObjectNode) answer.get("page");
            if (slice.hasMore()) page.put("nextCursor", cursors.encode(session.userId(), session.sessionId(), context, slice.lastId()));
            else page.putNull("nextCursor");
        }
        return answer;
    }

    /**
     * 현재 공개된 자원의 영수증 참조만 반환한다. 연결 해제로 숨겨진 ID를 다시 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy write
     */
    private ArrayNode visibleRefs(ArrayNode refs, ObjectNode snapshot, ObjectNode audit) {
        ArrayNode result = json.createArrayNode();
        for (JsonNode ref : refs) {
            String resource = ref.path("resource").asString();
            String array = switch (resource) {
                case "institutionLink" -> "institutionLinks";
                case "account" -> "accounts";
                case "obligation" -> "obligations";
                case "reserve" -> "reserves";
                case "allocation" -> "allocations";
                default -> "";
            };
            boolean visible = "settings".equals(resource) && snapshot.has("settings");
            String idKey = switch (resource) {
                case "institutionLink" -> "linkId";
                case "account" -> "accountId";
                case "obligation" -> "obligationId";
                case "reserve" -> "reserveId";
                case "allocation" -> "allocationId";
                default -> "id";
            };
            for (JsonNode item : snapshot.path(array)) {
                if (item.path(idKey).equals(ref.path("id"))) visible = true;
            }
            if (!visible && "allocation".equals(resource)) {
                for (JsonNode change : audit.path("changes")) {
                    if (!"allocation".equals(change.path("resource").asString())
                            || !ref.path("id").equals(change.path("id")) || !change.path("after").isNull()) continue;
                    JsonNode before = change.path("before");
                    visible = hasId(snapshot.path("reserves"), "reserveId", before.path("reserve_id"))
                        && hasId(snapshot.path("obligations"), "obligationId", before.path("obligation_id"));
                }
            }
            if (visible) result.add(ref.deepCopy());
        }
        return result;
    }

    /**
     * 삭제된 배정의 부모가 현재도 공개되는 경우에만 그 삭제 참조를 알린다.
     * @created 2026-10-29
     * @usedBy visibleRefs
     */
    private boolean hasId(JsonNode rows, String key, JsonNode id) {
        if (!id.isString()) return false;
        for (JsonNode row : rows) if (row.path(key).equals(id)) return true;
        return false;
    }

    /**
     * 검증을 마친 자원 경로의 UUID를 정규 소문자로 통일한다. 본문 값은 지문에서 보존한다.
     * @created 2026-10-29
     * @usedBy write
     */
    private String canonicalPath(String path) {
        String[] parts = path.split("/");
        if (parts.length >= 3) parts[2] = UUID.fromString(parts[2]).toString();
        return String.join("/", parts);
    }

    /**
     * 커밋 결과와 replay 여부를 내부에서 전달한다. 감사 자료를 HTTP로 직렬화하지 않는다.
     * @created 2026-10-29
     * @usedBy write
     */
    private record WriteResult(StoredReceipt stored, boolean replayed) {}
}
