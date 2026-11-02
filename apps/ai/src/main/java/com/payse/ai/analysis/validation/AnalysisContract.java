package com.payse.ai.analysis.validation;

import static com.payse.ai.analysis.validation.SchemaRules.require;

import com.payse.ai.constants.AiCodeConstants;
import com.payse.ai.constants.AiConfigConstants;
import com.payse.ai.constants.AiFieldConstants;
import com.payse.ai.constants.AiMessageConstants;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.time.LocalTime;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

/**
 * 공개 업무 규격·근거 관계만 검증한다. 세션·소유권·DB 원천 확인은 API 책임이다.
 * @created 2026-11-01
 * @usedBy AnalysisService, InputMapper
 */
public final class AnalysisContract {
    private static final Set<String> TASKS = Set.of(
        AiConfigConstants.Analysis.TRANSACTION_MEANING,
        AiConfigConstants.Analysis.RECURRING_MEANING
    );
    private static final JsonMapper JSON = JsonMapper.builder().build();
    private static final Pattern SOURCE_TIME = Pattern.compile(
        AiConfigConstants.Analysis.TIMESTAMP_PATTERN
    );
    private final Map<String, ObjectNode> schemas = new HashMap<>();
    private final String instructions;

    /**
     * 운영 JAR의 공개 기준과 스키마만 읽는다. 파일 누락·미지원 스키마는 시작 시 실패한다.
     * @created 2026-11-01
     * @usedBy AnalysisService 생성자, 계약 테스트
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public AnalysisContract() {
        for (String task : TASKS) {
            for (String side : new String[] {
                AiConfigConstants.Analysis.INPUT_SIDE,
                AiConfigConstants.Analysis.OUTPUT_SIDE }) {
                String name = task + "." + side + AiConfigConstants.Analysis.SCHEMA_SUFFIX;
                ObjectNode schema = (ObjectNode) JSON.readTree(resource(name));
                SchemaRules.supported(schema);
                schemas.put(name, schema);
            }
        }
        instructions = resource(AiConfigConstants.Analysis.INSTRUCTIONS_FILE) + "\n"
            + resource(AiConfigConstants.Analysis.CRITERIA_FILE);
    }

    /**
     * 예시·정답을 포함하지 않는 고정 지침과 공개 의미 기준을 반환한다.
     * @created 2026-11-01
     * @usedBy AnalysisService.analyze
     */
    public String instructions() {
        return instructions;
    }

    /**
     * 호출자가 공유 기준을 바꾸지 못하도록 업무 출력 스키마 사본을 반환한다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public ObjectNode outputSchema(String task) {
        return schema(task, AiConfigConstants.Analysis.OUTPUT_SIDE)
            .deepCopy();
    }

    /**
     * 기존 Python 계약과 같은 입력 구조·식별·원천 참조·로컬 후보 조건을 검사한다.
     * @created 2026-11-01
     * @usedBy InputMapper 생성자, output
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    public void input(JsonNode payload) {
        require(payload != null && payload.isObject(), AiCodeConstants.Analysis.INVALID_INPUT);
        String task = payload.path(AiFieldConstants.Analysis.SEMANTIC_TASK_KIND).asString("");
        SchemaRules.check(schema(task, AiConfigConstants.Analysis.INPUT_SIDE), payload);

        JsonNode context = payload.get(AiFieldConstants.Analysis.CONTEXT);
        try {
            Long.parseLong(context.get(AiFieldConstants.Analysis.DATA_VERSION).asString());
            sourceTime(context.get(AiFieldConstants.Analysis.AS_OF).asString());
        } catch (NumberFormatException | DateTimeException failure) {
            throw new ContractFailure(AiCodeConstants.Analysis.INVALID_CONTEXT);
        }

        ids(context.get(AiFieldConstants.Analysis.SELECTED_ACCOUNT_IDS));
        Map<String, JsonNode> transactions = keyed(
            payload.get(AiFieldConstants.Analysis.TRANSACTIONS),
            AiFieldConstants.Analysis.TRANSACTION_ID
        );
        Map<String, JsonNode> unavailable = keyed(
            payload.get(AiFieldConstants.Analysis.UNAVAILABLE_REFERENCES),
            AiFieldConstants.Analysis.TRANSACTION_ID
        );
        require(
            java.util.Collections.disjoint(transactions.keySet(), unavailable.keySet()),
            AiCodeConstants.Analysis.CONFLICTING_AVAILABILITY
        );
        Map<String, JsonNode> candidates = keyed(
            payload.get(AiFieldConstants.Analysis.CANDIDATES),
            AiFieldConstants.Analysis.CANDIDATE_KEY
        );
        Map<String, JsonNode> current = keyed(
            payload.get(AiFieldConstants.Analysis.CURRENT_CLASSIFICATIONS),
            AiFieldConstants.Analysis.TRANSACTION_ID
        );
        require(
            transactions.keySet().containsAll(current.keySet()),
            AiCodeConstants.Analysis.CLASSIFICATION_OUTSIDE_EVIDENCE
        );

        originals(transactions, unavailable.keySet());
        relations(payload.get(AiFieldConstants.Analysis.RELATIONS), transactions);
        items(payload, task, context, transactions, unavailable.keySet(), candidates);
    }

    /**
     * 기존 Python ISO 입력의 실제 날짜·시각·오프셋만 검증한다. 원문 정밀도·시각을 변경하지 않는다.
     * @created 2026-11-01
     * @usedBy input
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private void sourceTime(String source) {
        var match = SOURCE_TIME.matcher(source);
        require(match.matches(), AiCodeConstants.Analysis.INVALID_CONTEXT);
        require(
            LocalDate.parse(match.group(1)).getYear() >= 1,
            AiCodeConstants.Analysis.INVALID_CONTEXT
        );
        String minute = match.group(3) != null ? match.group(3) : match.group(5);
        String second = match.group(4) != null ? match.group(4) : match.group(6);
        int hourValue = Integer.parseInt(match.group(2));
        int minuteValue = minute == null ? 0 : Integer.parseInt(minute);
        int secondValue = second == null ? 0 : Integer.parseInt(second);
        LocalTime.of(
            hourValue,
            minuteValue,
            secondValue
        );

        String offset = match.group(7);
        if (!AiConfigConstants.Analysis.UTC_MARKER.equals(offset)) {
            int offsetMinutes = Integer.parseInt(offset.substring(1, 3)) * 60
                + Integer.parseInt(offset.substring(4, 6));
            require(offsetMinutes < 24 * 60, AiCodeConstants.Analysis.INVALID_CONTEXT);
        }
    }

    /**
     * 원거래가 미제공으로 표시되었는지 확인하고 순환·계좌 미지원 상태를 거절한다.
     * @created 2026-11-01
     * @usedBy input
     * @modified 2026-11-02 - 긴 식 지역변수 분리
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private void originals(Map<String, JsonNode> transactions, Set<String> unavailable) {
        for (var entry : transactions.entrySet()) {
            JsonNode row = entry.getValue();
            if (AiConfigConstants.Analysis.ACCOUNT_ENTRY.equals(
                row.get(AiFieldConstants.Analysis.RECORD_KIND)
                    .asString()
            )) {
                require(
                    Set.of(AiConfigConstants.Analysis.POSTED, AiConfigConstants.Analysis.UNKNOWN)
                        .contains(row.get(AiFieldConstants.Analysis.STATUS).asString()),
                    AiCodeConstants.Analysis.UNSUPPORTED_ACCOUNT_STATUS
                );
            }

            JsonNode original = row.get(AiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID);
            if (!original.isNull()) {
                String originalId = original.asString();
                boolean resolved = transactions.containsKey(originalId)
                    || unavailable.contains(originalId);
                require(resolved, AiCodeConstants.Analysis.UNRESOLVED_ORIGINAL);
            }

            Set<String> visited = new HashSet<>();
            String cursor = entry.getKey();
            while (transactions.containsKey(cursor)) {
                require(visited.add(cursor), AiCodeConstants.Analysis.CYCLIC_ORIGINAL);
                cursor = transactions.get(cursor)
                    .get(AiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID)
                    .asString(null);
            }
        }
    }

    /**
     * 명시된 관계의 종류·방향·양 끝을 확인하며 관계를 추정 생성하지 않는다.
     * @created 2026-11-01
     * @usedBy input
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private void relations(JsonNode rows, Map<String, JsonNode> transactions) {
        Set<String> seen = new HashSet<>();
        for (JsonNode row : rows) {
            String from = row.get(AiFieldConstants.Analysis.FROM_ID).asString();
            String to = row.get(AiFieldConstants.Analysis.TO_ID).asString();
            String kind = row.get(AiFieldConstants.Analysis.KIND).asString();
            String pair = from.compareTo(to) < 0 ? from + to : to + from;
            require(
                !from.equals(to) && seen.add(kind + pair),
                AiCodeConstants.Analysis.DUPLICATE_RELATION
            );
            require(
                transactions.containsKey(from) && transactions.containsKey(to),
                AiCodeConstants.Analysis.RELATION_OUTSIDE_EVIDENCE
            );

            JsonNode first = transactions.get(from);
            JsonNode second = transactions.get(to);
            if (AiConfigConstants.Analysis.INTERNAL_TRANSFER.equals(kind)) {
                require(
                    AiConfigConstants.Analysis.ACCOUNT_ENTRY.equals(
                        first.get(AiFieldConstants.Analysis.RECORD_KIND)
                            .asString()
                    )
                        && AiConfigConstants.Analysis.ACCOUNT_ENTRY.equals(
                            second.get(AiFieldConstants.Analysis.RECORD_KIND)
                                .asString()
                        )
                        && !first.get(AiFieldConstants.Analysis.DIRECTION)
                            .equals(second.get(AiFieldConstants.Analysis.DIRECTION)),
                    AiCodeConstants.Analysis.INVALID_TRANSFER
                );
            } else {
                Set<String> kinds = new HashSet<>();
                kinds.add(first.get(AiFieldConstants.Analysis.RECORD_KIND).asString());
                kinds.add(second.get(AiFieldConstants.Analysis.RECORD_KIND).asString());
                require(
                    kinds.equals(
                        Set.of(
                            AiConfigConstants.Analysis.ACCOUNT_ENTRY,
                            AiConfigConstants.Analysis.CARD_PURCHASE
                        )
                    ),
                    AiCodeConstants.Analysis.INVALID_CARD_PAIR
                );
            }
        }
    }

    /**
     * 항목 대상과 완전한 근거 집합을 확인하고 Flutter의 후보 조건을 재계산 없이 검증한다.
     * @created 2026-11-01
     * @usedBy input
     * @modified 2026-11-02 - 긴 식 지역변수 분리; 제어문 본문 구분
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private void items(
        JsonNode payload,
        String task,
        JsonNode context,
        Map<String, JsonNode> transactions,
        Set<String> unavailable,
        Map<String, JsonNode> candidates
    ) {
        Map<String, JsonNode> items = keyed(
            payload.get(AiFieldConstants.Analysis.ITEMS),
            AiFieldConstants.Analysis.ITEM_KEY
        );
        Set<String> targets = new HashSet<>();
        Set<String> evidence = new HashSet<>();
        for (JsonNode item : items.values()) {
            Set<String> refs = ids(item.get(AiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS));
            evidence.addAll(refs);
            require(
                transactions.keySet().containsAll(refs),
                AiCodeConstants.Analysis.ITEM_OUTSIDE_EVIDENCE
            );
            String target;
            if (AiConfigConstants.Analysis.TRANSACTION_MEANING.equals(task)) {
                target = item.get(AiFieldConstants.Analysis.TARGET_TRANSACTION_ID).asString();
                require(
                    refs.contains(target)
                        && item.get(AiFieldConstants.Analysis.CANDIDATE_KEY)
                            .isNull(),
                    AiCodeConstants.Analysis.TARGET_MISMATCH
                );
            } else {
                target = item.get(AiFieldConstants.Analysis.CANDIDATE_KEY).asString();
                JsonNode candidate = candidates.get(target);
                require(
                    candidate != null
                        && item.get(AiFieldConstants.Analysis.TARGET_TRANSACTION_ID)
                            .isNull(),
                    AiCodeConstants.Analysis.CANDIDATE_MISMATCH
                );
                require(
                    refs.equals(
                        ids(candidate.get(AiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS))
                    ),
                    AiCodeConstants.Analysis.CANDIDATE_EVIDENCE_MISMATCH
                );
                require(
                    candidate.get(AiFieldConstants.Analysis.RULE_VERSION)
                        .equals(context.get(AiFieldConstants.Analysis.RULE_VERSION))
                        && candidate.get(AiFieldConstants.Analysis.SOURCE_VERSION)
                            .equals(context.get(AiFieldConstants.Analysis.SOURCE_VERSION)),
                    AiCodeConstants.Analysis.CANDIDATE_VERSION_MISMATCH
                );
                JsonNode features = candidate.get(AiFieldConstants.Analysis.FEATURES);
                var occurrenceCount = features.get(AiFieldConstants.Analysis.OCCURRENCE_COUNT)
                    .bigIntegerValue();
                boolean ready = occurrenceCount.compareTo(java.math.BigInteger.valueOf(3)) >= 0
                    && ids(features.get(AiFieldConstants.Analysis.OBSERVED_MONTHS)).size() >= 3
                    && features.get(AiFieldConstants.Analysis.DAY_WITHIN_RULE).asBoolean()
                    && features.get(AiFieldConstants.Analysis.AMOUNT_WITHIN_RULE)
                        .asBoolean()
                    && !features.get(AiFieldConstants.Analysis.HAS_UNRESOLVED_REVERSAL).asBoolean();
                require(ready, AiCodeConstants.Analysis.LOCAL_CANDIDATE_NOT_READY);
            }
            require(targets.add(target), AiCodeConstants.Analysis.DUPLICATE_TARGET);
        }
        if (AiConfigConstants.Analysis.RECURRING_MEANING.equals(task)) {
            require(targets.equals(candidates.keySet()), AiCodeConstants.Analysis.UNUSED_CANDIDATE);
        }
        require(transactions.keySet().equals(evidence), AiCodeConstants.Analysis.UNUSED_EVIDENCE);
        Set<String> originals = new HashSet<>();
        for (JsonNode transaction : transactions.values()) {
            String originalId = transaction.get(AiFieldConstants.Analysis.ORIGINAL_TRANSACTION_ID)
                .asString(null);
            originals.add(originalId);
        }
        require(
            originals.containsAll(unavailable),
            AiCodeConstants.Analysis.UNUSED_UNAVAILABLE_REFERENCE
        );
    }

    /**
     * 완결 출력만 허용하고 기존 분류·허용 근거·관계 경계를 보존한다.
     * @created 2026-11-01
     * @usedBy InputMapper.restore
     * @modified 2026-11-01 - 부분 조회와 항목 검증을 공유하되 생성 출력의 완결성 유지
     */
    public void output(JsonNode payload, JsonNode result) {
        input(payload);
        validateOutput(payload, result, true);
    }

    /**
     * 유효한 전체 입력에서 조회 가능한 출력 부분집합만 검증한다. 누락 항목을 생성하지 않는다.
     * @created 2026-11-01
     * @usedBy 미연결: 예정 사용처 AnalysisResults.response
     */
    public void outputSubset(JsonNode payload, JsonNode result) {
        input(payload);
        validateOutput(payload, result, false);
    }

    /**
     * 전체·부분 출력에 같은 구조·항목·근거 검증을 적용하고 부분 조회의 외부 ID도 거절한다.
     * @created 2026-11-01
     * @usedBy output, outputSubset
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    private void validateOutput(JsonNode payload, JsonNode result, boolean requireComplete) {
        String task = payload.get(AiFieldConstants.Analysis.SEMANTIC_TASK_KIND).asString();
        SchemaRules.check(schema(task, AiConfigConstants.Analysis.OUTPUT_SIDE), result);

        Map<String, JsonNode> requested = keyed(
            payload.get(AiFieldConstants.Analysis.ITEMS),
            AiFieldConstants.Analysis.ITEM_KEY
        );

        Map<String, JsonNode> received = keyed(
            result.get(AiFieldConstants.Analysis.ITEMS),
            AiFieldConstants.Analysis.ITEM_KEY
        );
        if (requireComplete) {
            require(
                requested.keySet().equals(received.keySet()),
                AiCodeConstants.Analysis.INCOMPLETE_ITEMS
            );
        } else {
            require(
                requested.keySet().containsAll(received.keySet()),
                AiCodeConstants.Analysis.OUTPUT_OUTSIDE_ITEMS
            );
        }
        Map<String, JsonNode> current = keyed(
            payload.get(AiFieldConstants.Analysis.CURRENT_CLASSIFICATIONS),
            AiFieldConstants.Analysis.TRANSACTION_ID
        );
        for (var entry : received.entrySet()) {
            JsonNode row = entry.getValue();
            JsonNode item = requested.get(entry.getKey());
            Set<String> refs = ids(item.get(AiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS));
            require(
                refs.containsAll(ids(row.get(AiFieldConstants.Analysis.EVIDENCE_TRANSACTION_IDS))),
                AiCodeConstants.Analysis.OUTPUT_OUTSIDE_EVIDENCE
            );
            decision(row.get(AiFieldConstants.Analysis.MEANING));
            if (AiConfigConstants.Analysis.RECURRING_MEANING.equals(task)) {
                require(
                    row.get(AiFieldConstants.Analysis.CANDIDATE_KEY)
                        .equals(item.get(AiFieldConstants.Analysis.CANDIDATE_KEY)),
                    AiCodeConstants.Analysis.INVENTED_CANDIDATE
                );
                continue;
            }
            decision(row.get(AiFieldConstants.Analysis.CLASSIFICATION));
            String target = item.get(AiFieldConstants.Analysis.TARGET_TRANSACTION_ID).asString();
            String basic = row.get(AiFieldConstants.Analysis.CLASSIFICATION)
                .get(AiFieldConstants.Analysis.VALUE)
                .asString(null);
            String existing = current.containsKey(target) ? current.get(target)
                .get(AiFieldConstants.Analysis.VALUE)
                .asString(null) : null;
            if (basic != null && existing != null) {
                require(
                    basic.equals(existing),
                    AiCodeConstants.Analysis.EXISTING_CLASSIFICATION_CONFLICT
                );
            }
            if (AiConfigConstants.Analysis.CARD_PAYMENT.equals(basic)) {
                require(
                    basic.equals(existing),
                    AiCodeConstants.Analysis.MISSING_BILL_SETTLEMENT_EVIDENCE
                );
            }
            if (AiConfigConstants.Analysis.INTERNAL_TRANSFER.equals(basic)
                && !basic.equals(existing)) {
                boolean linked = false;
                for (JsonNode relation : payload.get(AiFieldConstants.Analysis.RELATIONS)) {
                    String from = relation.get(AiFieldConstants.Analysis.FROM_ID).asString();
                    String to = relation.get(AiFieldConstants.Analysis.TO_ID).asString();
                    linked |= AiConfigConstants.Analysis.INTERNAL_TRANSFER.equals(
                        relation.get(AiFieldConstants.Analysis.KIND)
                            .asString()
                    )
                        && (target.equals(from) || target.equals(to))
                        && refs.contains(from)
                        && refs.contains(to);
                }
                require(linked, AiCodeConstants.Analysis.MISSING_TRANSFER_EVIDENCE);
            }
        }
    }

    /**
     * candidate·unknown 상태와 값·사유가 서로 모순되지 않는지 검사한다.
     * @created 2026-11-01
     * @usedBy output
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private void decision(JsonNode decision) {
        boolean known = AiConfigConstants.Analysis.CANDIDATE.equals(
            decision.get(AiFieldConstants.Analysis.STATUS)
                .asString()
        );
        require(
            known == !decision.get(AiFieldConstants.Analysis.VALUE).isNull()
                && known == AiConfigConstants.Analysis.SUPPORTED.equals(
                    decision.get(AiFieldConstants.Analysis.REASON_CODE)
                        .asString()
                ),
            AiCodeConstants.Analysis.DECISION_MISMATCH
        );
    }

    /**
     * 승인된 두 업무 외의 스키마 이름·임의 리소스 접근을 거절한다.
     * @created 2026-11-01
     * @usedBy input, output, outputSchema
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조
     */
    private ObjectNode schema(String task, String side) {
        require(TASKS.contains(task), AiCodeConstants.Analysis.UNKNOWN_TASK);
        return schemas.get(task + "." + side + AiConfigConstants.Analysis.SCHEMA_SUFFIX);
    }

    /**
     * 중복 식별자를 덮어쓰지 않는 인덱스를 만든다.
     * @created 2026-11-01
     * @usedBy input, items, output
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    private Map<String, JsonNode> keyed(JsonNode rows, String field) {
        Map<String, JsonNode> result = new LinkedHashMap<>();
        for (JsonNode row : rows) {
            require(
                result.putIfAbsent(row.get(field).asString(), row) == null,
                AiCodeConstants.Analysis.DUPLICATE_ID
            );
        }
        return result;
    }

    /**
     * 참조 중복을 오류로 유지한다.
     * @created 2026-11-01
     * @usedBy input, items, output
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    private Set<String> ids(JsonNode values) {
        Set<String> result = new HashSet<>();
        for (JsonNode value : values) {
            require(result.add(value.asString()), AiCodeConstants.Analysis.DUPLICATE_REFERENCE);
        }
        return result;
    }

    /**
     * 클래스 경로의 공개 리소스만 읽으며 파일 시스템·비공개 평가 자료를 탐색하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisContract 생성자
     * @modified 2026-11-02 - 계약 문자열 상수 분리; 용도별 통합 상수 참조; 제어문 본문 구분
     */
    private String resource(String name) {
        try (var stream = AnalysisContract.class
            .getResourceAsStream(AiConfigConstants.Analysis.RULES_PATH + name)) {
            if (stream == null) {
                throw new IllegalStateException(AiMessageConstants.Analysis.MISSING_RESOURCE);
            }
            return new String(stream.readAllBytes(), StandardCharsets.UTF_8);
        } catch (IOException failure) {
            throw new IllegalStateException(AiMessageConstants.Analysis.UNAVAILABLE_RESOURCE);
        }
    }
}
