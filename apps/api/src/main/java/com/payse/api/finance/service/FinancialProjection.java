package com.payse.api.finance.service;

import com.payse.api.constants.ApiCodeConstants;
import com.payse.api.constants.ApiConfigConstants;
import com.payse.api.constants.ApiFieldConstants;
import com.payse.api.finance.dto.PageSlice;
import com.payse.api.finance.error.FinancialException;
import java.time.LocalDate;
import java.time.OffsetDateTime;
import java.time.YearMonth;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.JsonNodeFactory;
import tools.jackson.databind.node.ObjectNode;

/**
 * 저장 원천을 변경하지 않고 기관 권한과 해당 버전의 공개 관계를 요청별로 투영한다.
 * @created 2026-10-29
 * @usedBy FinancialService
 */
public final class FinancialProjection {

    private static final List<String> HEADERS = List.of(
        "userId",
        "schemaVersion",
        "currency",
        "dataVersion",
        "sourceVersion",
        "ruleVersion",
        "asOf"
    );
    private static final Map<String, String> IDS = Map.ofEntries(
        Map.entry("accounts", "accountId"),
        Map.entry("cards", "cardId"),
        Map.entry("transactions", "transactionId"),
        Map.entry("statements", "statementId"),
        Map.entry("obligations", "obligationId"),
        Map.entry("reserves", "reserveId"),
        Map.entry("allocations", "allocationId"),
        Map.entry("settlements", "linkId"),
        Map.entry("recurringPlans", "planId"),
        Map.entry("recurringPlanRevisions", "revisionId"),
        Map.entry("recurringDecisions", "decisionId")
    );

    /**
     * 현재 저장 상태를 새 응답에 복사하고 페이지에 필요한 근거만 제공한다.
     * 연결 전에는 금융 배열을 빈 값으로 채우지 않고 계약의 열 키만 반환한다.
     * @created 2026-10-29
     * @usedBy FinancialService의 조회 및 쓰기 후 Snapshot 조립
     * @param source 같은 인증 트랜잭션에서 읽은 전체 사용자 원천·설정
     * @param connectedCodes 현재 활성 연결 집합
     * @param dataVersion 현재 사용자 저장 버전
     * @param afterId 첫 조회는 null, 후속 조회는 검증한 cursor의 마지막 UUID
     * @param pageOnly 후속 거래 페이지 여부
     * @return cursor 서명 전 응답과 마지막 거래 ID·다음 페이지 여부
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    public PageSlice project(
        ObjectNode source,
        Set<String> connectedCodes,
        String dataVersion,
        UUID afterId,
        boolean pageOnly
    ) {
        try {
            Context context = new Context(source, connectedCodes, dataVersion);
            ObjectNode visible = context.build();
            if (connectedCodes.isEmpty()) {
                if (pageOnly || afterId != null) {
                    throw unavailable();
                }

                return new PageSlice(visible, null, false);
            }
            return FinancialPages.slice(visible, afterId, pageOnly);
        } catch (FinancialException failure) {
            throw failure;
        } catch (RuntimeException failure) {
            throw unavailable();
        }
    }

    /**
     * 요청마다 별도 인덱스·제한 목록을 만들어 사용자 간 가변 상태 공유를 막는다.
     * @created 2026-10-29
     * @usedBy FinancialProjection.project
     */
    private static final class Context {
        private final ObjectNode source;
        private final ObjectNode result;
        private final Set<String> connected;
        private final Map<String, Map<String, ObjectNode>> indexes = new HashMap<>();
        private final Map<String, Set<String>> visible = new HashMap<>();
        private final Set<String> hiddenIds = new HashSet<>();
        private final Map<String, ObjectNode> restrictions = new LinkedHashMap<>();
        private final Map<String, String> institutionKinds = new HashMap<>();
        private final String userId;
        private final boolean billingItems;

        /**
         * 원천 복사본의 사용자·버전·자원 ID와 필수 부모를 조회용 인덱스로 준비한다.
         * @created 2026-10-29
         * @usedBy FinancialProjection.project
         * @modified 2026-10-30 - 원천 v3/v4와 공개 응답 버전을 일치시켜 청구 항목 계약을 보존
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private Context(ObjectNode input, Set<String> connectedCodes, String dataVersion) {
            if (input == null || connectedCodes == null || dataVersion == null
                || !dataVersion.matches("[1-9][0-9]{0,18}")) {
                throw unavailable();
            }

            source = input.deepCopy();
            FinancialShape.validate(source);
            connected = Set.copyOf(connectedCodes);
            String schema = text(source, ApiFieldConstants.Finance.SCHEMA_VERSION);
            if (!Set.of(ApiConfigConstants.Finance.DRAFT_V3, ApiConfigConstants.Finance.DRAFT_V4)
                .contains(schema)
                || !ApiConfigConstants.Finance.KRW
                    .equals(text(source, ApiFieldConstants.Finance.CURRENCY))) {
                throw unavailable();
            }

            billingItems = schema.equals(ApiConfigConstants.Finance.DRAFT_V4);
            userId = id(source, ApiFieldConstants.Finance.USER_ID);
            OffsetDateTime.parse(text(source, ApiFieldConstants.Finance.AS_OF));
            result = object();
            for (String key : HEADERS) {
                result.set(key, required(source, key).deepCopy());
            }

            result.put(
                ApiFieldConstants.Finance.SCHEMA_VERSION,
                billingItems ? ApiConfigConstants.Finance.API_V4 : ApiConfigConstants.Finance.API_V3
            );
            result.put(ApiFieldConstants.Finance.DATA_VERSION, dataVersion);
            for (ObjectNode institution : rows(source, ApiFieldConstants.Finance.INSTITUTIONS)) {
                String code = text(institution, ApiFieldConstants.Finance.CODE);
                String kind = text(institution, ApiFieldConstants.Finance.KIND);
                if (!Set.of(ApiFieldConstants.Finance.BANK, ApiCodeConstants.Finance.CARD)
                    .contains(kind)
                    || institutionKinds.putIfAbsent(code, kind) != null) {
                    throw unavailable();
                }
            }

            if (!institutionKinds.keySet().containsAll(connected)) {
                throw unavailable();
            }

            // DB 저장에서는 본문/보조 거래가 같은 테이블이다. 기존 fixture 입력도 한 인덱스로 합친다.
            ArrayNode transactions = array();
            Map<String, ObjectNode> merged = new LinkedHashMap<>();
            for (String key : List.of(
                ApiFieldConstants.Finance.TRANSACTIONS,
                ApiFieldConstants.Finance.RELATED_TRANSACTIONS
            )) {
                for (ObjectNode transaction : rows(source, key)) {
                    String transactionId = id(
                        transaction,
                        ApiFieldConstants.Finance.TRANSACTION_ID
                    );
                    ObjectNode old = merged.putIfAbsent(transactionId, transaction);
                    if (old != null && !old.equals(transaction)) {
                        throw unavailable();
                    }
                }
            }

            merged.values().forEach(transactions::add);
            source.set(ApiFieldConstants.Finance.TRANSACTIONS, transactions);
            source.set(ApiFieldConstants.Finance.RELATED_TRANSACTIONS, array());
            IDS.forEach(
                (key, idKey) -> {
                    Map<String, ObjectNode> index = new LinkedHashMap<>();
                    for (ObjectNode row : rows(source, key)) {
                        if (!userId.equals(id(row, ApiFieldConstants.Finance.USER_ID))
                            || index.putIfAbsent(id(row, idKey), row) != null) {
                            throw unavailable();
                        }
                        if (Set.of(
                            ApiFieldConstants.Finance.ACCOUNTS,
                            ApiFieldConstants.Finance.CARDS,
                            ApiFieldConstants.Finance.TRANSACTIONS,
                            ApiFieldConstants.Finance.STATEMENTS
                        ).contains(key)
                            && !text(source, ApiFieldConstants.Finance.SOURCE_VERSION)
                                .equals(text(row, ApiFieldConstants.Finance.SOURCE_VERSION))) {
                            throw unavailable();
                        }
                    }

                    indexes.put(key, index);
                    visible.put(key, new LinkedHashSet<>());
                }
            );
            validateReferences();
        }

        /**
         * 소유권이 일치해도 잘못된 부모 관계를 정상 미연결 상태로 설명하지 않는다.
         * @created 2026-10-29
         * @usedBy Context 생성자
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         * @modified 2026-11-02 - 계획·버전 동시 존재 조건을 기존 참조 검사에 명시
         */
        private void validateReferences() {
            for (ObjectNode account : all(ApiFieldConstants.Finance.ACCOUNTS)) {
                institution(account, ApiFieldConstants.Finance.BANK);
            }
            for (ObjectNode card : all(ApiFieldConstants.Finance.CARDS)) {
                institution(card, ApiCodeConstants.Finance.CARD);
                knownOptional(
                    card,
                    ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID,
                    ApiFieldConstants.Finance.ACCOUNTS
                );
            }
            for (ObjectNode transaction : all(ApiFieldConstants.Finance.TRANSACTIONS)) {
                knownOptional(
                    transaction,
                    ApiFieldConstants.Finance.ACCOUNT_ID,
                    ApiFieldConstants.Finance.ACCOUNTS
                );
                knownOptional(
                    transaction,
                    ApiFieldConstants.Finance.CARD_ID,
                    ApiFieldConstants.Finance.CARDS
                );
                String kind = text(transaction, ApiFieldConstants.Finance.RECORD_KIND);
                if (kind.equals(ApiCodeConstants.Finance.ACCOUNT_ENTRY)) {
                    known(
                        transaction,
                        ApiFieldConstants.Finance.ACCOUNT_ID,
                        ApiFieldConstants.Finance.ACCOUNTS
                    );
                } else if (Set.of(
                    ApiCodeConstants.Finance.CARD_PURCHASE,
                    ApiCodeConstants.Finance.CARD_REFUND,
                    ApiCodeConstants.Finance.CARD_CANCELLATION
                ).contains(kind)) {
                    known(
                        transaction,
                        ApiFieldConstants.Finance.CARD_ID,
                        ApiFieldConstants.Finance.CARDS
                    );
                } else {
                    throw unavailable();
                }
            }
            for (ObjectNode statement : all(ApiFieldConstants.Finance.STATEMENTS)) {
                known(
                    statement,
                    ApiFieldConstants.Finance.CARD_ID,
                    ApiFieldConstants.Finance.CARDS
                );
            }
            for (ObjectNode revision : all(ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS)) {
                known(
                    revision,
                    ApiFieldConstants.Finance.PLAN_ID,
                    ApiFieldConstants.Finance.RECURRING_PLANS
                );
                known(
                    revision,
                    ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID,
                    ApiFieldConstants.Finance.ACCOUNTS
                );
                knownOptional(
                    revision,
                    ApiFieldConstants.Finance.CARD_ID,
                    ApiFieldConstants.Finance.CARDS
                );
            }
            for (ObjectNode obligation : all(ApiFieldConstants.Finance.OBLIGATIONS)) {
                known(
                    obligation,
                    ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID,
                    ApiFieldConstants.Finance.ACCOUNTS
                );
                knownOptional(
                    obligation,
                    ApiFieldConstants.Finance.STATEMENT_ID,
                    ApiFieldConstants.Finance.STATEMENTS
                );
                knownOptional(
                    obligation,
                    ApiFieldConstants.Finance.RECURRING_PLAN_ID,
                    ApiFieldConstants.Finance.RECURRING_PLANS
                );
                knownOptional(
                    obligation,
                    ApiFieldConstants.Finance.PLAN_REVISION_ID,
                    ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS
                );
                String plan = nullableText(obligation, ApiFieldConstants.Finance.RECURRING_PLAN_ID);
                String revision = nullableText(
                    obligation,
                    ApiFieldConstants.Finance.PLAN_REVISION_ID
                );
                if ((plan == null) != (revision == null)) {
                    throw unavailable();
                }
                if (plan != null && revision != null && !plan.equals(
                    text(
                        indexes.get(ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS)
                            .get(revision),
                        ApiFieldConstants.Finance.PLAN_ID
                    )
                )) {
                    throw unavailable();
                }
            }
            for (ObjectNode reserve : all(ApiFieldConstants.Finance.RESERVES)) {
                known(
                    reserve,
                    ApiFieldConstants.Finance.ACCOUNT_ID,
                    ApiFieldConstants.Finance.ACCOUNTS
                );
            }
            for (ObjectNode settlement : all(ApiFieldConstants.Finance.SETTLEMENTS)) {
                known(
                    settlement,
                    ApiFieldConstants.Finance.OBLIGATION_ID,
                    ApiFieldConstants.Finance.OBLIGATIONS
                );
                known(
                    settlement,
                    ApiFieldConstants.Finance.TRANSACTION_ID,
                    ApiFieldConstants.Finance.TRANSACTIONS
                );
            }
            for (ObjectNode allocation : all(ApiFieldConstants.Finance.ALLOCATIONS)) {
                known(
                    allocation,
                    ApiFieldConstants.Finance.RESERVE_ID,
                    ApiFieldConstants.Finance.RESERVES
                );
                known(
                    allocation,
                    ApiFieldConstants.Finance.OBLIGATION_ID,
                    ApiFieldConstants.Finance.OBLIGATIONS
                );
                for (ObjectNode proof : rows(
                    allocation,
                    ApiFieldConstants.Finance.RELEASE_EVIDENCE
                )) {
                    known(
                        proof,
                        ApiFieldConstants.Finance.SETTLEMENT_LINK_ID,
                        ApiFieldConstants.Finance.SETTLEMENTS
                    );
                    ObjectNode settlement = indexes.get(ApiFieldConstants.Finance.SETTLEMENTS)
                        .get(text(proof, ApiFieldConstants.Finance.SETTLEMENT_LINK_ID));
                    if (!text(allocation, ApiFieldConstants.Finance.OBLIGATION_ID)
                        .equals(text(settlement, ApiFieldConstants.Finance.OBLIGATION_ID))) {
                        throw unavailable();
                    }
                }
            }
            for (ObjectNode link : rows(source, ApiFieldConstants.Finance.INSTITUTION_LINKS)) {
                if (!userId.equals(id(link, ApiFieldConstants.Finance.USER_ID)) || !institutionKinds
                    .containsKey(text(link, ApiFieldConstants.Finance.INSTITUTION_CODE))) {
                    throw unavailable();
                }
            }
        }

        /**
         * 종속 공개 순서대로 원천·설정·관계를 조립하고 숨겨진 ID 잔류를 검사한다.
         * @created 2026-10-29
         * @usedBy FinancialProjection.project
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private ObjectNode build() {
            result.set(
                ApiFieldConstants.Finance.INSTITUTIONS,
                required(source, ApiFieldConstants.Finance.INSTITUTIONS).deepCopy()
            );
            ArrayNode links = array();
            for (ObjectNode link : rows(source, ApiFieldConstants.Finance.INSTITUTION_LINKS)) {
                if (link.get(ApiFieldConstants.Finance.DISCONNECTED_AT).isNull()
                    && connected.contains(text(link, ApiFieldConstants.Finance.INSTITUTION_CODE))) {
                    links.add(link);
                }
            }

            result.set(ApiFieldConstants.Finance.INSTITUTION_LINKS, links);
            if (connected.isEmpty()) {
                result.set(ApiFieldConstants.Finance.COVERAGE, array());
                return result;
            }
            accounts();
            cards();
            transactions();
            statements();
            plans();
            obligations();
            reserves();
            settlements();
            allocations();
            overrides();
            decisions();
            relations();
            occurrenceLinks();
            settings();
            coverage();
            result.set(ApiFieldConstants.Finance.REFERENCE_RESOLUTIONS, array());
            result.set(ApiFieldConstants.Finance.RELATED_TRANSACTIONS, array());
            ArrayNode marks = array();
            restrictions.values().forEach(marks::add);
            result.set(ApiFieldConstants.Finance.ACCESS_RESTRICTIONS, marks);
            ensurePrivateIdsAbsent(result);
            return result;
        }

        /**
         * 원천 계좌의 은행 연결과 저장된 선택 여부를 분리하여 제공한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void accounts() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.ACCOUNTS)) {
                if (connected.contains(text(row, ApiFieldConstants.Finance.INSTITUTION_CODE))) {
                    keep(out, ApiFieldConstants.Finance.ACCOUNTS, row);
                } else {
                    hide(ApiFieldConstants.Finance.ACCOUNTS, row, ApiCodeConstants.Finance.ACCOUNT);
                }
            }

            result.set(ApiFieldConstants.Finance.ACCOUNTS, out);
        }

        /**
         * 카드 연결과 출금 은행의 권한을 따로 검사하여 숨겨진 계좌 키만 생략한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조
         */
        private void cards() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.CARDS)) {
                if (!connected.contains(text(row, ApiFieldConstants.Finance.INSTITUTION_CODE))) {
                    hide(ApiFieldConstants.Finance.CARDS, row, ApiCodeConstants.Finance.CARD);
                    continue;
                }
                redact(
                    row,
                    ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID,
                    ApiFieldConstants.Finance.ACCOUNTS,
                    ApiCodeConstants.Finance.CARD,
                    id(row, ApiFieldConstants.Finance.CARD_ID),
                    ApiCodeConstants.Finance.ACCOUNT
                );
                keep(out, ApiFieldConstants.Finance.CARDS, row);
            }

            result.set(ApiFieldConstants.Finance.CARDS, out);
        }

        /**
         * 입출금은 은행, 구매·환불·취소는 카드사를 기준으로 공개하며 원거래 권한도 검사한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void transactions() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.TRANSACTIONS)) {
                boolean accountEntry = ApiCodeConstants.Finance.ACCOUNT_ENTRY
                    .equals(text(row, ApiFieldConstants.Finance.RECORD_KIND));
                String parent = text(
                    row,
                    accountEntry ? ApiFieldConstants.Finance.ACCOUNT_ID
                        : ApiFieldConstants.Finance.CARD_ID
                );
                if (!shown(
                    accountEntry ? ApiFieldConstants.Finance.ACCOUNTS
                        : ApiFieldConstants.Finance.CARDS,
                    parent
                )) {
                    hide(
                        ApiFieldConstants.Finance.TRANSACTIONS,
                        row,
                        ApiCodeConstants.Finance.TRANSACTION
                    );
                    continue;
                }
                redact(
                    row,
                    accountEntry ? ApiFieldConstants.Finance.CARD_ID
                        : ApiFieldConstants.Finance.ACCOUNT_ID,
                    accountEntry ? ApiFieldConstants.Finance.CARDS
                        : ApiFieldConstants.Finance.ACCOUNTS,
                    ApiCodeConstants.Finance.TRANSACTION,
                    id(row, ApiFieldConstants.Finance.TRANSACTION_ID),
                    accountEntry ? ApiCodeConstants.Finance.CARD : ApiCodeConstants.Finance.ACCOUNT
                );
                keep(out, ApiFieldConstants.Finance.TRANSACTIONS, row);
            }
            for (JsonNode value : out) {
                ObjectNode row = (ObjectNode) value;
                String original = nullableText(
                    row,
                    ApiFieldConstants.Finance.ORIGINAL_TRANSACTION_ID
                );
                if (original == null) {
                    continue;
                }
                if (!indexes.get(ApiFieldConstants.Finance.TRANSACTIONS).containsKey(original)) {
                    throw unavailable();
                }

                redact(
                    row,
                    ApiFieldConstants.Finance.ORIGINAL_TRANSACTION_ID,
                    ApiFieldConstants.Finance.TRANSACTIONS,
                    ApiCodeConstants.Finance.TRANSACTION,
                    id(row, ApiFieldConstants.Finance.TRANSACTION_ID),
                    ApiCodeConstants.Finance.TRANSACTION
                );
            }

            result.set(ApiFieldConstants.Finance.TRANSACTIONS, out);
        }

        /**
         * 청구 원천의 버전을 유지하고 청구 항목·포함 거래의 공개 권한을 함께 적용한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-10-30 - v4 항목의 nullable 연결·제한 표식과 숨긴 항목 ID 비노출 지원
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void statements() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.STATEMENTS)) {
                if (!shown(
                    ApiFieldConstants.Finance.CARDS,
                    text(row, ApiFieldConstants.Finance.CARD_ID)
                )) {
                    hide(ApiFieldConstants.Finance.STATEMENTS, row, ApiCodeConstants.Finance.CARD);
                    if (billingItems) {
                        for (ObjectNode item : rows(row, ApiFieldConstants.Finance.ITEMS)) {
                            hiddenIds.add(id(item, ApiFieldConstants.Finance.ITEM_ID));
                        }
                    }
                    continue;
                }
                if (billingItems) {
                    statementItems(row);
                    keep(out, ApiFieldConstants.Finance.STATEMENTS, row);
                    continue;
                }
                ArrayNode refs = array();
                for (String transaction : strings(
                    row,
                    ApiFieldConstants.Finance.INCLUDED_TRANSACTION_REFS
                )) {
                    if (!indexes.get(ApiFieldConstants.Finance.TRANSACTIONS)
                        .containsKey(transaction)) {
                        throw unavailable();
                    }

                    if (shown(ApiFieldConstants.Finance.TRANSACTIONS, transaction)) {
                        refs.add(transaction);
                    } else {
                        restrict(
                            ApiCodeConstants.Finance.STATEMENT,
                            id(row, ApiFieldConstants.Finance.STATEMENT_ID),
                            ApiFieldConstants.Finance.INCLUDED_TRANSACTION_REFS,
                            ApiCodeConstants.Finance.TRANSACTION
                        );
                    }
                }

                row.set(ApiFieldConstants.Finance.INCLUDED_TRANSACTION_REFS, refs);
                keep(out, ApiFieldConstants.Finance.STATEMENTS, row);
            }

            result.set(ApiFieldConstants.Finance.STATEMENTS, out);
        }

        /**
         * 공개 청구의 미연결 거래 키만 생략하고 참조 배열을 남은 항목에서 파생한다.
         * 실제 null 연결·금액·회차는 원천 그대로 유지하며 페이지 위치로 권한을 판단하지 않는다.
         * @created 2026-10-30
         * @usedBy Context.statements
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void statementItems(ObjectNode statement) {
            Set<String> references = new LinkedHashSet<>();
            boolean restricted = false;
            for (ObjectNode item : rows(statement, ApiFieldConstants.Finance.ITEMS)) {
                String transaction = nullableText(item, ApiFieldConstants.Finance.TRANSACTION_ID);
                if (transaction == null) {
                    continue;
                }
                if (!indexes.get(ApiFieldConstants.Finance.TRANSACTIONS).containsKey(transaction)) {
                    throw unavailable();
                }

                if (shown(ApiFieldConstants.Finance.TRANSACTIONS, transaction)) {
                    references.add(transaction);
                } else {
                    item.remove(ApiFieldConstants.Finance.TRANSACTION_ID);
                    restrict(
                        ApiCodeConstants.Finance.STATEMENT_ITEM,
                        id(item, ApiFieldConstants.Finance.ITEM_ID),
                        ApiFieldConstants.Finance.TRANSACTION_ID,
                        ApiCodeConstants.Finance.TRANSACTION
                    );
                    restricted = true;
                }
            }

            if (restricted) {
                restrict(
                    ApiCodeConstants.Finance.STATEMENT,
                    id(statement, ApiFieldConstants.Finance.STATEMENT_ID),
                    ApiFieldConstants.Finance.INCLUDED_TRANSACTION_REFS,
                    ApiCodeConstants.Finance.TRANSACTION
                );
            }
            ArrayNode refs = array();
            references.forEach(refs::add);
            statement.set(ApiFieldConstants.Finance.INCLUDED_TRANSACTION_REFS, refs);
        }

        /**
         * 버전의 출금 계좌를 기준으로 계획을 공개하고 숨겨진 버전의 존재만 제한 표식으로 알린다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 긴 식 지역변수 분리
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void plans() {
            ArrayNode revisions = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS)) {
                if (!shown(
                    ApiFieldConstants.Finance.ACCOUNTS,
                    text(row, ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID)
                )) {
                    hide(
                        ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS,
                        row,
                        ApiCodeConstants.Finance.ACCOUNT
                    );
                    continue;
                }
                redact(
                    row,
                    ApiFieldConstants.Finance.CARD_ID,
                    ApiFieldConstants.Finance.CARDS,
                    ApiCodeConstants.Finance.RECURRING_PLAN_REVISION,
                    id(row, ApiFieldConstants.Finance.REVISION_ID),
                    ApiCodeConstants.Finance.CARD
                );
                keep(revisions, ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS, row);
                visible.get(ApiFieldConstants.Finance.RECURRING_PLANS)
                    .add(text(row, ApiFieldConstants.Finance.PLAN_ID));
            }

            ArrayNode plans = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.RECURRING_PLANS)) {
                String planId = id(row, ApiFieldConstants.Finance.PLAN_ID);
                if (!shown(ApiFieldConstants.Finance.RECURRING_PLANS, planId)) {
                    hide(
                        ApiFieldConstants.Finance.RECURRING_PLANS,
                        row,
                        ApiCodeConstants.Finance.ACCOUNT
                    );
                    continue;
                }
                Set<String> planFields = Set.of(
                    ApiFieldConstants.Finance.USER_ID,
                    ApiFieldConstants.Finance.PLAN_ID,
                    ApiFieldConstants.Finance.FIRST_OCCURRENCE_MONTH
                );
                Set<String> presentFields = Set.copyOf(row.propertyNames());
                if (!planFields.equals(presentFields)) {
                    throw unavailable();
                }

                keep(plans, ApiFieldConstants.Finance.RECURRING_PLANS, row);
                for (ObjectNode revision : all(
                    ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS
                )) {
                    if (planId.equals(text(revision, ApiFieldConstants.Finance.PLAN_ID)) && !shown(
                        ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS,
                        id(revision, ApiFieldConstants.Finance.REVISION_ID)
                    )) {
                        restrict(
                            ApiCodeConstants.Finance.RECURRING_PLAN,
                            planId,
                            ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS,
                            ApiCodeConstants.Finance.PLAN_REVISION
                        );
                    }
                }
            }

            result.set(ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS, revisions);
            result.set(ApiFieldConstants.Finance.RECURRING_PLANS, plans);
        }

        /**
         * 의무의 필수 계좌·계획·고정 버전과 선택 청구 참조를 서로 다르게 처리한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조
         */
        private void obligations() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.OBLIGATIONS)) {
                String hidden = !shown(
                    ApiFieldConstants.Finance.ACCOUNTS,
                    text(row, ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID)
                ) ? ApiCodeConstants.Finance.ACCOUNT
                    : hiddenPlan(
                        nullableText(row, ApiFieldConstants.Finance.RECURRING_PLAN_ID),
                        nullableText(row, ApiFieldConstants.Finance.PLAN_REVISION_ID)
                    );
                if (hidden != null) {
                    hide(ApiFieldConstants.Finance.OBLIGATIONS, row, hidden);
                    continue;
                }
                redact(
                    row,
                    ApiFieldConstants.Finance.STATEMENT_ID,
                    ApiFieldConstants.Finance.STATEMENTS,
                    ApiCodeConstants.Finance.OBLIGATION,
                    id(row, ApiFieldConstants.Finance.OBLIGATION_ID),
                    ApiCodeConstants.Finance.STATEMENT
                );
                keep(out, ApiFieldConstants.Finance.OBLIGATIONS, row);
            }

            result.set(ApiFieldConstants.Finance.OBLIGATIONS, out);
        }

        /**
         * 보호 계좌를 볼 수 있는 보호 설정만 공개한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void reserves() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.RESERVES)) {
                if (shown(
                    ApiFieldConstants.Finance.ACCOUNTS,
                    text(row, ApiFieldConstants.Finance.ACCOUNT_ID)
                )) {
                    keep(out, ApiFieldConstants.Finance.RESERVES, row);
                } else {
                    hide(ApiFieldConstants.Finance.RESERVES, row, ApiCodeConstants.Finance.ACCOUNT);
                }
            }

            result.set(ApiFieldConstants.Finance.RESERVES, out);
        }

        /**
         * 정산의 두 부모를 검사하고 공개 의무에서 숨긴 지급 근거의 제한을 명시한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조
         */
        private void settlements() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.SETTLEMENTS)) {
                String obligationId = text(row, ApiFieldConstants.Finance.OBLIGATION_ID);
                if (!shown(ApiFieldConstants.Finance.OBLIGATIONS, obligationId)) {
                    hide(
                        ApiFieldConstants.Finance.SETTLEMENTS,
                        row,
                        ApiCodeConstants.Finance.OBLIGATION
                    );
                    continue;
                }
                if (!shown(
                    ApiFieldConstants.Finance.TRANSACTIONS,
                    text(row, ApiFieldConstants.Finance.TRANSACTION_ID)
                )) {
                    hide(
                        ApiFieldConstants.Finance.SETTLEMENTS,
                        row,
                        ApiCodeConstants.Finance.TRANSACTION
                    );
                    restrict(
                        ApiCodeConstants.Finance.OBLIGATION,
                        obligationId,
                        ApiFieldConstants.Finance.SETTLEMENTS,
                        ApiCodeConstants.Finance.TRANSACTION
                    );
                    continue;
                }
                keep(out, ApiFieldConstants.Finance.SETTLEMENTS, row);
            }

            result.set(ApiFieldConstants.Finance.SETTLEMENTS, out);
        }

        /**
         * 배정 부모를 숨기거나 해제 근거만 생략하되 확인된 해제 금액을 변경하지 않는다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조
         */
        private void allocations() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.ALLOCATIONS)) {
                String kind = !shown(
                    ApiFieldConstants.Finance.RESERVES,
                    text(row, ApiFieldConstants.Finance.RESERVE_ID)
                ) ? ApiCodeConstants.Finance.RESERVE
                    : !shown(
                        ApiFieldConstants.Finance.OBLIGATIONS,
                        text(row, ApiFieldConstants.Finance.OBLIGATION_ID)
                    ) ? ApiCodeConstants.Finance.OBLIGATION : null;
                if (kind != null) {
                    hide(ApiFieldConstants.Finance.ALLOCATIONS, row, kind);
                    continue;
                }
                for (ObjectNode proof : rows(row, ApiFieldConstants.Finance.RELEASE_EVIDENCE)) {
                    ObjectNode settlement = indexes.get(ApiFieldConstants.Finance.SETTLEMENTS)
                        .get(text(proof, ApiFieldConstants.Finance.SETTLEMENT_LINK_ID));
                    if (!shown(
                        ApiFieldConstants.Finance.TRANSACTIONS,
                        text(settlement, ApiFieldConstants.Finance.TRANSACTION_ID)
                    )) {
                        row.remove(ApiFieldConstants.Finance.RELEASE_EVIDENCE);
                        restrict(
                            ApiCodeConstants.Finance.ALLOCATION,
                            id(row, ApiFieldConstants.Finance.ALLOCATION_ID),
                            ApiFieldConstants.Finance.RELEASE_EVIDENCE,
                            ApiCodeConstants.Finance.TRANSACTION
                        );
                        break;
                    }
                }

                keep(out, ApiFieldConstants.Finance.ALLOCATIONS, row);
            }

            result.set(ApiFieldConstants.Finance.ALLOCATIONS, out);
        }

        /**
         * 개별 회차의 계좌와 고정 계획 버전 공개 조건을 유지한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void overrides() {
            ArrayNode out = array();
            for (ObjectNode row : rows(source, ApiFieldConstants.Finance.OCCURRENCE_OVERRIDES)) {
                owner(row);
                known(
                    row,
                    ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID,
                    ApiFieldConstants.Finance.ACCOUNTS
                );
                String hidden = !shown(
                    ApiFieldConstants.Finance.ACCOUNTS,
                    text(row, ApiFieldConstants.Finance.WITHDRAWAL_ACCOUNT_ID)
                ) ? ApiCodeConstants.Finance.ACCOUNT
                    : hiddenPlan(
                        planFrom(row),
                        text(row, ApiFieldConstants.Finance.PLAN_REVISION_ID)
                    );
                if (hidden == null) {
                    out.add(row);
                } else {
                    restrict(
                        ApiCodeConstants.Finance.RESPONSE,
                        null,
                        ApiFieldConstants.Finance.OCCURRENCE_OVERRIDES,
                        hidden
                    );
                }
            }

            result.set(ApiFieldConstants.Finance.OCCURRENCE_OVERRIDES, out);
        }

        /**
         * 반복 결정의 계획·모든 원천 거래가 공개될 때만 그 결정을 반환한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void decisions() {
            ArrayNode out = array();
            for (ObjectNode row : all(ApiFieldConstants.Finance.RECURRING_DECISIONS)) {
                String plan = nullableText(row, ApiFieldConstants.Finance.PLAN_ID);
                String hidden = hiddenPlan(plan, null) != null ? ApiCodeConstants.Finance.PLAN
                    : null;
                for (String transaction : strings(
                    row,
                    ApiFieldConstants.Finance.EVIDENCE_TRANSACTION_IDS
                )) {
                    if (!indexes.get(ApiFieldConstants.Finance.TRANSACTIONS)
                        .containsKey(transaction)) {
                        throw unavailable();
                    }

                    if (!shown(ApiFieldConstants.Finance.TRANSACTIONS, transaction)) {
                        hidden = ApiCodeConstants.Finance.TRANSACTION;
                    }
                }

                if (hidden != null) {
                    hide(ApiFieldConstants.Finance.RECURRING_DECISIONS, row, hidden);
                    continue;
                }
                keep(out, ApiFieldConstants.Finance.RECURRING_DECISIONS, row);
            }

            result.set(ApiFieldConstants.Finance.RECURRING_DECISIONS, out);
        }

        /**
         * 양 끝 거래가 모두 공개된 관계만 제공하고 숨긴 반대쪽 ID를 표식에 넣지 않는다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void relations() {
            ArrayNode out = array();
            Set<String> unique = new HashSet<>();
            for (ObjectNode row : rows(source, ApiFieldConstants.Finance.TRANSACTION_RELATIONS)) {
                String from = text(row, ApiFieldConstants.Finance.FROM_ID),
                    to = text(row, ApiFieldConstants.Finance.TO_ID);
                known(
                    row,
                    ApiFieldConstants.Finance.FROM_ID,
                    ApiFieldConstants.Finance.TRANSACTIONS
                );
                known(row, ApiFieldConstants.Finance.TO_ID, ApiFieldConstants.Finance.TRANSACTIONS);
                if (shown(ApiFieldConstants.Finance.TRANSACTIONS, from)
                    && shown(ApiFieldConstants.Finance.TRANSACTIONS, to)) {
                    String key = text(row, ApiFieldConstants.Finance.KIND) + "|" + from + "|" + to
                        + "|" + text(row, ApiFieldConstants.Finance.EVIDENCE_REF);
                    if (unique.add(key)) {
                        out.add(row);
                    }
                } else {
                    restrict(
                        ApiCodeConstants.Finance.RESPONSE,
                        null,
                        ApiFieldConstants.Finance.TRANSACTION_RELATIONS,
                        ApiCodeConstants.Finance.TRANSACTION
                    );
                    if (shown(ApiFieldConstants.Finance.TRANSACTIONS, from)) {
                        restrict(
                            ApiCodeConstants.Finance.TRANSACTION,
                            from,
                            ApiFieldConstants.Finance.TRANSACTION_RELATIONS,
                            ApiCodeConstants.Finance.TRANSACTION
                        );
                    }
                    if (shown(ApiFieldConstants.Finance.TRANSACTIONS, to)) {
                        restrict(
                            ApiCodeConstants.Finance.TRANSACTION,
                            to,
                            ApiFieldConstants.Finance.TRANSACTION_RELATIONS,
                            ApiCodeConstants.Finance.TRANSACTION
                        );
                    }
                }
            }

            result.set(ApiFieldConstants.Finance.TRANSACTION_RELATIONS, out);
        }

        /**
         * 계획·구매·청구·의무의 명시 참조를 모두 확인한 회차 연결만 반환한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조
         * @modified 2026-11-02 - 긴 식 지역변수 분리; 단일 제어문 본문 중괄호 명시
         */
        private void occurrenceLinks() {
            ArrayNode out = array();
            Set<String> unique = new HashSet<>();
            for (ObjectNode row : rows(source, ApiFieldConstants.Finance.OCCURRENCE_LINKS)) {
                String hidden = hiddenPlan(planFrom(row), null) != null
                    ? ApiCodeConstants.Finance.PLAN
                    : null;
                var relatedFields = List.of(
                    ApiFieldConstants.Finance.PURCHASE_TRANSACTION_ID,
                    ApiFieldConstants.Finance.STATEMENT_ID,
                    ApiFieldConstants.Finance.OBLIGATION_ID
                );
                for (String field : relatedFields) {
                    String group = switch (field) {
                    case ApiFieldConstants.Finance.PURCHASE_TRANSACTION_ID ->
                        ApiFieldConstants.Finance.TRANSACTIONS;
                    case ApiFieldConstants.Finance.STATEMENT_ID ->
                        ApiFieldConstants.Finance.STATEMENTS;
                    default -> ApiFieldConstants.Finance.OBLIGATIONS;
                    };
                    knownOptional(row, field, group);
                    String reference = nullableText(row, field);
                    if (reference != null && !shown(group, reference)) {
                        hidden = switch (group) {
                        case ApiFieldConstants.Finance.TRANSACTIONS ->
                            ApiCodeConstants.Finance.TRANSACTION;
                        case ApiFieldConstants.Finance.STATEMENTS ->
                            ApiCodeConstants.Finance.STATEMENT;
                        default -> ApiCodeConstants.Finance.OBLIGATION;
                        };
                    }
                }

                if (hidden != null) {
                    restrict(
                        ApiCodeConstants.Finance.RESPONSE,
                        null,
                        ApiFieldConstants.Finance.OCCURRENCE_LINKS,
                        hidden
                    );
                } else {
                    String tuple = text(row, ApiFieldConstants.Finance.RECURRENCE_KEY) + "|"
                        + nullableText(row, ApiFieldConstants.Finance.PURCHASE_TRANSACTION_ID)
                        + "|" + nullableText(row, ApiFieldConstants.Finance.STATEMENT_ID) + "|"
                        + nullableText(row, ApiFieldConstants.Finance.OBLIGATION_ID)
                        + "|" + text(row, ApiFieldConstants.Finance.EVIDENCE_REF);
                    if (unique.add(tuple)) {
                        out.add(row);
                    }
                }
            }

            result.set(ApiFieldConstants.Finance.OCCURRENCE_LINKS, out);
        }

        /**
         * 급여 원천을 보존하고 계좌·근거·카드 계획의 미연결 슬롯만 생략한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void settings() {
            ObjectNode settings = objectAt(source, ApiFieldConstants.Finance.SETTINGS);
            ObjectNode salary = objectAt(settings, ApiFieldConstants.Finance.SALARY);
            knownOptional(
                salary,
                ApiFieldConstants.Finance.SALARY_ACCOUNT_ID,
                ApiFieldConstants.Finance.ACCOUNTS
            );
            String account = nullableText(salary, ApiFieldConstants.Finance.SALARY_ACCOUNT_ID);
            boolean accountHidden = account != null
                && !shown(ApiFieldConstants.Finance.ACCOUNTS, account);
            boolean evidenceHidden = false;
            Set<String> months = new HashSet<>();
            List<ObjectNode> evidence = rows(salary, ApiFieldConstants.Finance.RECEIPT_EVIDENCE);
            for (ObjectNode proof : evidence) {
                String month = text(proof, ApiFieldConstants.Finance.PAY_MONTH);
                if (!month.matches("[0-9]{4}-(0[1-9]|1[0-2])")
                    || month.startsWith(ApiConfigConstants.Finance.INVALID_YEAR)
                    || !months.add(month)) {
                    throw unavailable();
                }

                YearMonth.parse(month);
                LocalDate.parse(text(proof, ApiFieldConstants.Finance.EXPECTED_PAY_DATE));
                String confirmation = text(proof, ApiFieldConstants.Finance.CONFIRMATION);
                if (!Set.of(
                    ApiCodeConstants.Finance.UNKNOWN,
                    ApiCodeConstants.Finance.PARTIAL,
                    ApiCodeConstants.Finance.CONFIRMED
                ).contains(confirmation)) {
                    throw unavailable();
                }

                List<String> references = strings(proof, ApiFieldConstants.Finance.TRANSACTION_IDS);
                if (!confirmation.equals(ApiCodeConstants.Finance.UNKNOWN)
                    && references.isEmpty()) {
                    throw unavailable();
                }

                for (String transactionId : references) {
                    ObjectNode transaction = indexes.get(ApiFieldConstants.Finance.TRANSACTIONS)
                        .get(transactionId);
                    if (transaction == null
                        || !ApiCodeConstants.Finance.ACCOUNT_ENTRY
                            .equals(text(transaction, ApiFieldConstants.Finance.RECORD_KIND))
                        || !ApiCodeConstants.Finance.IN
                            .equals(text(transaction, ApiFieldConstants.Finance.DIRECTION))
                        || !ApiCodeConstants.Finance.POSTED
                            .equals(text(transaction, ApiFieldConstants.Finance.STATUS))
                        || !required(transaction, ApiFieldConstants.Finance.BALANCE_REFLECTED)
                            .asBoolean()) {
                        throw unavailable();
                    }

                    if (!shown(ApiFieldConstants.Finance.TRANSACTIONS, transactionId)) {
                        evidenceHidden = true;
                    }
                }
            }

            if (accountHidden) {
                salary.remove(ApiFieldConstants.Finance.SALARY_ACCOUNT_ID);
                restrict(
                    ApiFieldConstants.Finance.SETTINGS,
                    null,
                    ApiFieldConstants.Finance.SALARY_ACCOUNT_PATH,
                    ApiCodeConstants.Finance.ACCOUNT
                );
            }
            if (!evidence.isEmpty() && accountHidden) {
                salary.remove(ApiFieldConstants.Finance.RECEIPT_EVIDENCE);
                restrict(
                    ApiFieldConstants.Finance.SETTINGS,
                    null,
                    ApiFieldConstants.Finance.SALARY_EVIDENCE_PATH,
                    ApiCodeConstants.Finance.ACCOUNT
                );
            } else if (evidenceHidden) {
                salary.remove(ApiFieldConstants.Finance.RECEIPT_EVIDENCE);
                restrict(
                    ApiFieldConstants.Finance.SETTINGS,
                    null,
                    ApiFieldConstants.Finance.SALARY_EVIDENCE_PATH,
                    ApiCodeConstants.Finance.TRANSACTION
                );
            }
            ArrayNode cardPlans = array();
            for (ObjectNode row : rows(settings, ApiFieldConstants.Finance.CARD_PLANS)) {
                known(row, ApiFieldConstants.Finance.CARD_ID, ApiFieldConstants.Finance.CARDS);
                if (shown(
                    ApiFieldConstants.Finance.CARDS,
                    text(row, ApiFieldConstants.Finance.CARD_ID)
                )) {
                    cardPlans.add(row);
                } else {
                    restrict(
                        ApiFieldConstants.Finance.SETTINGS,
                        null,
                        ApiFieldConstants.Finance.CARD_PLANS,
                        ApiCodeConstants.Finance.CARD
                    );
                }
            }

            settings.set(ApiFieldConstants.Finance.CARD_PLANS, cardPlans);
            result.set(ApiFieldConstants.Finance.SETTINGS, settings);
        }

        /**
         * 실제 확보 범위는 원천 그대로 제공하며 연결하지 않은 대상의 ID는 생략한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void coverage() {
            ArrayNode out = array();
            Set<String> keys = new HashSet<>();
            for (ObjectNode row : rows(source, ApiFieldConstants.Finance.COVERAGE)) {
                String kind = text(row, ApiFieldConstants.Finance.TARGET_KIND);
                if (!Set.of(ApiCodeConstants.Finance.ACCOUNT, ApiCodeConstants.Finance.CARD)
                    .contains(kind)) {
                    throw unavailable();
                }

                String group = kind.equals(ApiCodeConstants.Finance.ACCOUNT)
                    ? ApiFieldConstants.Finance.ACCOUNTS
                    : ApiFieldConstants.Finance.CARDS;
                known(row, ApiFieldConstants.Finance.TARGET_ID, group);
                if (!keys.add(kind + ":" + text(row, ApiFieldConstants.Finance.TARGET_ID))) {
                    throw unavailable();
                }

                if (shown(group, text(row, ApiFieldConstants.Finance.TARGET_ID))) {
                    out.add(row);
                } else {
                    restrict(
                        ApiCodeConstants.Finance.RESPONSE,
                        null,
                        ApiFieldConstants.Finance.COVERAGE,
                        kind
                    );
                }
            }

            if (keys.size() != indexes.get(ApiFieldConstants.Finance.ACCOUNTS).size()
                + indexes.get(ApiFieldConstants.Finance.CARDS).size()) {
                throw unavailable();
            }

            result.set(ApiFieldConstants.Finance.COVERAGE, out);
        }

        /**
         * 공개 문자열 어디에도 미연결 자원의 식별자가 남아 있지 않은지 검사한다.
         * @created 2026-10-29
         * @usedBy Context.build
         * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
         */
        private void ensurePrivateIdsAbsent(JsonNode node) {
            if (node.isString()) {
                String text = node.asString().toLowerCase(java.util.Locale.ROOT);
                for (String id : hiddenIds) {
                    if (text.contains(id)) {
                        throw unavailable();
                    }
                }
            } else if (node.isContainer()) {
                for (JsonNode child : node) {
                    ensurePrivateIdsAbsent(child);
                }
            }
        }

        /**
         * 필수 계획 또는 고정 버전이 비공개이면 정확한 제한 종류를 반환한다.
         * @created 2026-10-29
         * @usedBy Context.obligations, overrides, decisions, occurrenceLinks
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private String hiddenPlan(String plan, String revision) {
            if (plan != null
                && !indexes.get(ApiFieldConstants.Finance.RECURRING_PLANS).containsKey(plan)) {
                throw unavailable();
            }
            if (revision != null && !indexes.get(ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS)
                .containsKey(revision)) {
                throw unavailable();
            }
            if (plan != null && !shown(ApiFieldConstants.Finance.RECURRING_PLANS, plan)) {
                return ApiCodeConstants.Finance.PLAN;
            }
            if (revision != null
                && !shown(ApiFieldConstants.Finance.RECURRING_PLAN_REVISIONS, revision)) {
                return ApiCodeConstants.Finance.PLAN_REVISION;
            }

            return null;
        }

        /**
         * 명시 회차 키의 계획 ID만 읽고 월별 회차·급여 날짜를 계산하지 않는다.
         * @created 2026-10-29
         * @usedBy Context.overrides, occurrenceLinks
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private String planFrom(ObjectNode row) {
            String key = text(row, ApiFieldConstants.Finance.RECURRENCE_KEY);
            int split = key.lastIndexOf(':');
            if (split < 0) {
                throw unavailable();
            }

            YearMonth.parse(key.substring(split + 1));
            return UUID.fromString(key.substring(0, split)).toString();
        }

        /**
         * 자원의 기관 종류가 원천 객체와 일치하는지 확인한다.
         * @created 2026-10-29
         * @usedBy Context.validateReferences
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void institution(ObjectNode row, String kind) {
            if (!kind.equals(
                institutionKinds.get(text(row, ApiFieldConstants.Finance.INSTITUTION_CODE))
            )) {
                throw unavailable();
            }
        }

        /**
         * 원천 배열에서 인덱스한 행을 순서대로 읽는다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         */
        private List<ObjectNode> all(String group) {
            return new ArrayList<>(indexes.get(group).values());
        }

        /**
         * 공개 자원을 결과 배열과 공개 ID 집합에 함께 기록한다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         */
        private void keep(ArrayNode target, String group, ObjectNode row) {
            visible.get(group).add(id(row, IDS.get(group)));
            target.add(row);
        }

        /**
         * 비공개 행을 숨기고 배열의 제한 위치만 공개한다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조
         */
        private void hide(String group, ObjectNode row, String kind) {
            hiddenIds.add(id(row, IDS.get(group)));
            restrict(ApiCodeConstants.Finance.RESPONSE, null, group, kind);
        }

        /**
         * 공개 부모의 미연결 참조는 null로 바꾸지 않고 키를 생략한다.
         * @created 2026-10-29
         * @usedBy Context.cards, transactions, statements, obligations, plans
         */
        private void redact(
            ObjectNode row,
            String field,
            String group,
            String ownerType,
            String ownerId,
            String kind
        ) {
            String reference = nullableText(row, field);
            if (reference != null && !shown(group, reference)) {
                row.remove(field);
                restrict(ownerType, ownerId, field, kind);
            }
        }

        /**
         * 요청별 공개 ID 인덱스에서 참조 권한을 확인한다.
         * @created 2026-10-29
         * @usedBy Context의 자원 투영 메서드
         */
        private boolean shown(String group, String reference) {
            return visible.get(group).contains(reference);
        }

        /**
         * 동일 위치·종류의 제한은 한 번만 기록하며 숨겨진 대상 ID는 포함하지 않는다.
         * @created 2026-10-29
         * @usedBy Context.hide, redact 및 관계 투영 메서드
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조
         */
        private void restrict(String ownerType, String ownerId, String field, String kind) {
            String key = ownerType + "|" + ownerId + "|" + field + "|" + kind;
            ObjectNode mark = object()
                .put(ApiFieldConstants.Finance.OWNER_TYPE, ownerType)
                .put(ApiFieldConstants.Finance.OWNER_ID, ownerId)
                .put(ApiFieldConstants.Finance.FIELD, field)
                .put(ApiFieldConstants.Finance.TARGET_KIND, kind)
                .put(ApiFieldConstants.Finance.REASON, ApiCodeConstants.Finance.NOT_CONNECTED);
            restrictions.putIfAbsent(key, mark);
        }

        /**
         * 추가 행의 소유자가 현재 Snapshot 소유자와 같은지 확인한다.
         * @created 2026-10-29
         * @usedBy Context.overrides
         * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
         * @modified 2026-11-02 - 용도별 상수 파일 참조; 단일 제어문 본문 중괄호 명시
         */
        private void owner(ObjectNode row) {
            if (!userId.equals(id(row, ApiFieldConstants.Finance.USER_ID))) {
                throw unavailable();
            }
        }

        /**
         * 필수 참조가 현재 사용자의 확보된 부모 집합에 존재하는지 확인한다.
         * @created 2026-10-29
         * @usedBy Context.validateReferences 및 관계 투영 메서드
         * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
         */
        private void known(ObjectNode row, String field, String group) {
            if (!indexes.get(group).containsKey(id(row, field))) {
                throw unavailable();
            }
        }

        /**
         * nullable 원천 참조의 null과 확보되지 않은 잘못된 ID를 구분한다.
         * @created 2026-10-29
         * @usedBy Context.validateReferences, settings, occurrenceLinks
         * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
         */
        private void knownOptional(ObjectNode row, String field, String group) {
            if (nullableText(row, field) != null) {
                known(row, field, group);
            }
        }
    }

    /**
     * 원천 오류 내용을 클라이언트에 노출하지 않는 기존 503을 만든다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     * @modified 2026-11-02 - 계약·업무 문자열 상수 분리
     * @modified 2026-11-02 - 용도별 상수 파일 참조
     */
    static FinancialException unavailable() {
        return new FinancialException(503, ApiCodeConstants.Finance.TEMPORARILY_UNAVAILABLE);
    }

    /**
     * 공통 JsonNodeFactory의 새 객체를 요청 로컬에서 생성한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static ObjectNode object() {
        return JsonNodeFactory.instance.objectNode();
    }

    /**
     * 공통 JsonNodeFactory의 새 배열을 요청 로컬에서 생성한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static ArrayNode array() {
        return JsonNodeFactory.instance.arrayNode();
    }

    /**
     * 누락된 필수 값은 정상 null로 보충하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    static JsonNode required(JsonNode row, String field) {
        JsonNode value = row.get(field);
        if (value == null || value.isMissingNode()) {
            throw unavailable();
        }

        return value;
    }

    /**
     * 필수 문자열의 타입을 자동 변환 없이 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    static String text(JsonNode row, String field) {
        JsonNode value = required(row, field);
        if (!value.isString() || value.asString().isEmpty()) {
            throw unavailable();
        }

        return value.asString();
    }

    /**
     * nullable 문자열에서 원천 null과 누락을 구분한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     */
    static String nullableText(JsonNode row, String field) {
        JsonNode value = required(row, field);
        return value.isNull() ? null : text(row, field);
    }

    /**
     * 정규 UUID 형식만 받아 축약 UUID나 다른 표기를 묵시 보정하지 않는다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    static String id(JsonNode row, String field) {
        String value = text(row, field);
        if (!UUID.fromString(value)
            .toString()
            .equals(value)) {
            throw unavailable();
        }

        return value;
    }

    /**
     * 필수 중첩 객체의 타입을 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection.Context.settings, FinancialPages
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    static ObjectNode objectAt(JsonNode row, String field) {
        JsonNode value = required(row, field);
        if (!(value instanceof ObjectNode object)) {
            throw unavailable();
        }

        return object;
    }

    /**
     * 필수 객체 배열을 빈 배열로 대체하지 않고 모든 원소의 타입을 검사한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    static List<ObjectNode> rows(JsonNode source, String field) {
        JsonNode value = required(source, field);
        if (!value.isArray()) {
            throw unavailable();
        }

        List<ObjectNode> result = new ArrayList<>();
        for (JsonNode item : value) {
            if (!(item instanceof ObjectNode object)) {
                throw unavailable();
            }

            result.add(object);
        }

        return result;
    }

    /**
     * 참조 배열은 문자열만 허용하고 같은 ID의 중복을 거절한다.
     * @created 2026-10-29
     * @usedBy FinancialProjection, FinancialPages
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    static List<String> strings(JsonNode row, String field) {
        JsonNode values = required(row, field);
        if (!values.isArray()) {
            throw unavailable();
        }

        List<String> result = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (JsonNode value : values) {
            if (!value.isString() || value.asString().isEmpty() || !seen.add(value.asString())) {
                throw unavailable();
            }

            result.add(value.asString());
        }

        return result;
    }
}
