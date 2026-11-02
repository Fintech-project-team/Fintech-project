package com.payse.api.finance.service;

import com.payse.api.auth.crypto.AuthCrypto;
import com.payse.api.auth.dto.AuthRows;
import com.payse.api.auth.mapper.AuthRepository;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiFieldConstants.FinanceDb;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.finance.dto.StoredReceipt;
import com.payse.api.finance.dto.WriteChange;
import com.payse.api.finance.error.FinancialException;
import com.payse.api.finance.mapper.FinancialReceipts;
import com.payse.api.finance.mapper.FinancialRepository;
import com.payse.api.finance.mapper.FinancialWrites;
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
    public FinancialService(
        AuthTransactions transactions,
        AuthRepository auth,
        AuthCrypto crypto,
        FinancialRepository repository,
        FinancialWrites writes,
        FinancialReceipts receipts,
        FinancialCursor cursors
    ) {
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
        return transactions.run(
            () -> {
                AuthRows.Session session = authorize(token);
                return snapshot(repository.load(session.userId()), session, cursor.get(), pageOnly);
            }
        );
    }

    /**
     * 형식→멱등→새 요청 버전·권한→저장·영수증을 원자 처리하고 최신 자료를 별도 조회한다.
     * @created 2026-10-29
     * @usedBy FinancialController.write
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    public ObjectNode write(String token, String method, String path, Supplier<JsonNode> body) {
        WriteResult result = transactions.run(
            () -> {
                AuthRows.Session session = authorize(token);
                ObjectNode input = FinancialInput.validate(method, path, body.get());
                String route = canonicalPath(path);
                String key = input.get(ApiFieldConstants.Finance.IDEMPOTENCY_KEY).asString();
                String digest = FinancialJson.requestDigest(method, route, input);
                var existing = receipts.find(session.userId(), key, digest);
                if (existing.isPresent()) {
                    return new WriteResult(existing.get(), true);
                }

                ObjectNode source = repository.load(session.userId());
                if (!input.get(ApiFieldConstants.Finance.EXPECTED_DATA_VERSION)
                    .equals(source.get(ApiFieldConstants.Finance.DATA_VERSION))) {
                    throw new FinancialException(409, ApiCodeConstants.Finance.STALE_DATA);
                }
                if (!input.get(ApiFieldConstants.Finance.RULE_VERSION)
                    .equals(source.get(ApiFieldConstants.Finance.RULE_VERSION))) {
                    throw new FinancialException(
                        409,
                        ApiCodeConstants.Finance.RULE_VERSION_MISMATCH
                    );
                }

                try {
                    WriteChange change = writes.apply(session.userId(), method, route, input);
                    StoredReceipt receipt = receipts.save(
                        session.userId(),
                        key,
                        digest,
                        method + " " + route,
                        change.changedRefs(),
                        change.beforeAfter()
                    );
                    receipts.checkConstraints();
                    return new WriteResult(receipt, false);
                } catch (DataIntegrityViolationException failure) {
                    throw new FinancialException(409, ApiCodeConstants.Finance.RELATION_CONFLICT);
                } catch (PersistenceException failure) {
                    if (new HibernateJpaDialect().translateExceptionIfPossible(
                        failure
                    ) instanceof DataIntegrityViolationException) {
                        throw new FinancialException(
                            409,
                            ApiCodeConstants.Finance.RELATION_CONFLICT
                        );
                    }

                    throw new FinancialException(
                        503,
                        ApiCodeConstants.Finance.TEMPORARILY_UNAVAILABLE
                    );
                }
            }
        );
        // 이미 성공한 저장은 이후 응답 조립 실패로 되돌리지 않는다. 동일 키 재시도로 복구한다.
        ObjectNode snapshot = read(token, () -> null, false);
        ObjectNode receipt = result.stored().receipt();
        receipt.set(
            ApiFieldConstants.Finance.CHANGED_REFS,
            visibleRefs(
                (ArrayNode) receipt.get(ApiFieldConstants.Finance.CHANGED_REFS),
                snapshot,
                result.stored().audit()
            )
        );
        ObjectNode response = json.createObjectNode()
            .put(ApiFieldConstants.Finance.REPLAYED, result.replayed());
        response.set(ApiFieldConstants.Finance.RECEIPT, receipt);
        response.set(ApiFieldConstants.Finance.SNAPSHOT, snapshot);
        return response;
    }

    /**
     * 형식이 틀린 토큰도 DB 인증 함수로 보내 이전 문맥을 비우며 동일 401로 거절한다.
     * @created 2026-10-29
     * @usedBy read, write
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    private AuthRows.Session authorize(String token) {
        String digest;
        try {
            digest = crypto.tokenDigest(token);
        } catch (IllegalArgumentException failure) {
            digest = null;
        }

        return auth.authorize(digest)
            .orElseThrow(
                () -> new FinancialException(401, ApiCodeConstants.Finance.SESSION_INVALID)
            );
    }

    /**
     * 저장 원천에서 공개 범위와 페이지를 조립하고 서명된 위치를 추가한다.
     * @created 2026-10-29
     * @usedBy read
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode snapshot(
        ObjectNode source,
        AuthRows.Session session,
        String cursor,
        boolean pageOnly
    ) {
        Set<String> codes = new HashSet<>();
        for (JsonNode link : source.path(ApiFieldConstants.Finance.INSTITUTION_LINKS)) {
            if (link.path(ApiFieldConstants.Finance.DISCONNECTED_AT).isNull()) {
                codes.add(link.path(ApiFieldConstants.Finance.INSTITUTION_CODE).asString());
            }
        }

        String context = cursors.context(source, codes);
        UUID after = pageOnly
            ? cursors.decode(cursor, session.userId(), session.sessionId(), context)
            : null;
        var slice = projection.project(
            source,
            codes,
            source.get(ApiFieldConstants.Finance.DATA_VERSION).asString(),
            after,
            pageOnly
        );
        ObjectNode answer = slice.body();
        if (answer.has(ApiFieldConstants.Finance.PAGE)) {
            ObjectNode page = (ObjectNode) answer.get(ApiFieldConstants.Finance.PAGE);
            if (slice.hasMore()) {
                page.put(
                    ApiFieldConstants.Finance.NEXT_CURSOR,
                    cursors.encode(session.userId(), session.sessionId(), context, slice.lastId())
                );
            } else {
                page.putNull(ApiFieldConstants.Finance.NEXT_CURSOR);
            }
        }
        return answer;
    }

    /**
     * 현재 공개된 자원의 영수증 참조만 반환한다. 연결 해제로 숨겨진 ID를 다시 노출하지 않는다.
     * @created 2026-10-29
     * @usedBy write
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조·참조 개행 정리; 단일 제어문 본문 중괄호 명시
     */
    private ArrayNode visibleRefs(ArrayNode refs, ObjectNode snapshot, ObjectNode audit) {
        ArrayNode result = json.createArrayNode();
        for (JsonNode ref : refs) {
            String resource = ref.path(ApiFieldConstants.Finance.RESOURCE).asString();
            String array = switch (resource) {
            case ApiCodeConstants.Finance.INSTITUTION_LINK ->
                ApiFieldConstants.Finance.INSTITUTION_LINKS;
            case ApiCodeConstants.Finance.ACCOUNT -> ApiFieldConstants.Finance.ACCOUNTS;
            case ApiCodeConstants.Finance.OBLIGATION -> ApiFieldConstants.Finance.OBLIGATIONS;
            case ApiCodeConstants.Finance.RESERVE -> ApiFieldConstants.Finance.RESERVES;
            case ApiCodeConstants.Finance.ALLOCATION -> ApiFieldConstants.Finance.ALLOCATIONS;
            default -> "";
            };
            boolean visible = ApiCodeConstants.Finance.SETTINGS.equals(resource)
                && snapshot.has(ApiFieldConstants.Finance.SETTINGS);
            String idKey = switch (resource) {
            case ApiCodeConstants.Finance.INSTITUTION_LINK -> ApiFieldConstants.Finance.LINK_ID;
            case ApiCodeConstants.Finance.ACCOUNT -> ApiFieldConstants.Finance.ACCOUNT_ID;
            case ApiCodeConstants.Finance.OBLIGATION -> ApiFieldConstants.Finance.OBLIGATION_ID;
            case ApiCodeConstants.Finance.RESERVE -> ApiFieldConstants.Finance.RESERVE_ID;
            case ApiCodeConstants.Finance.ALLOCATION -> ApiFieldConstants.Finance.ALLOCATION_ID;
            default -> FinanceDb.ID;
            };
            for (JsonNode item : snapshot.path(array)) {
                if (item.path(idKey).equals(ref.path(FinanceDb.ID))) {
                    visible = true;
                }
            }

            if (!visible && ApiCodeConstants.Finance.ALLOCATION.equals(resource)) {
                for (JsonNode change : audit.path(ApiFieldConstants.Finance.CHANGES)) {
                    if (!ApiCodeConstants.Finance.ALLOCATION
                        .equals(change.path(ApiFieldConstants.Finance.RESOURCE).asString())
                        || !ref.path(FinanceDb.ID).equals(change.path(FinanceDb.ID))
                        || !change.path(ApiFieldConstants.Finance.AFTER).isNull()) {
                        continue;
                    }

                    JsonNode before = change.path(ApiFieldConstants.Finance.BEFORE);
                    visible = hasId(
                        snapshot.path(ApiFieldConstants.Finance.RESERVES),
                        ApiFieldConstants.Finance.RESERVE_ID,
                        before.path(FinanceDb.RESERVE_ID)
                    )
                        && hasId(
                            snapshot.path(ApiFieldConstants.Finance.OBLIGATIONS),
                            ApiFieldConstants.Finance.OBLIGATION_ID,
                            before.path(FinanceDb.OBLIGATION_ID)
                        );
                }
            }
            if (visible) {
                result.add(ref.deepCopy());
            }
        }

        return result;
    }

    /**
     * 삭제된 배정의 부모가 현재도 공개되는 경우에만 그 삭제 참조를 알린다.
     * @created 2026-10-29
     * @usedBy visibleRefs
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private boolean hasId(JsonNode rows, String key, JsonNode id) {
        if (!id.isString()) {
            return false;
        }

        for (JsonNode row : rows) {
            if (row.path(key).equals(id)) {
                return true;
            }
        }

        return false;
    }

    /**
     * 검증을 마친 자원 경로의 UUID를 정규 소문자로 통일한다. 본문 값은 지문에서 보존한다.
     * @created 2026-10-29
     * @usedBy write
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private String canonicalPath(String path) {
        String[] parts = path.split("/");
        if (parts.length >= 3) {
            parts[2] = UUID.fromString(parts[2]).toString();
        }
        return String.join("/", parts);
    }

    /**
     * 커밋 결과와 replay 여부를 내부에서 전달한다. 감사 자료를 HTTP로 직렬화하지 않는다.
     * @created 2026-10-29
     * @usedBy write
     */
    private record WriteResult(StoredReceipt stored, boolean replayed) {
    }
}
