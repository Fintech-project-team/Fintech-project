package com.payse.api.analysis.service;

import com.payse.api.ApiTestConstants.AnalysisCodes;
import com.payse.api.ApiTestConstants.AnalysisFields;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.payse.api.finance.error.FinancialException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.function.Predicate;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 실제 준비 원천의 ID·관계로 분석 입력의 소유권·현재성·근거 누락을 검증한다.
 * @created 2026-11-01
 * @usedBy Gradle JUnit
 */
class AnalysisEvidenceTest {
    /**
     * DB 원천의 요청 거래만 보충하며 금액·날짜를 보존하고 정답·잔액·인증은 제외한다.
     * @created 2026-11-03
     * @usedBy JUnit
     */
    @Test
    void projectsOnlyAuthorizedSourceFacts() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode salary = salary(source);
        ObjectNode input = input(source, List.of(salary));
        ObjectNode before = source.deepCopy();
        ObjectNode facts = evidence.modelFacts(owner(source), source, input);
        assertEquals(1, facts.path("transactions").size());
        JsonNode row = facts.path("transactions").get(0);
        assertEquals(salary.path("amountKRW"), row.path("amountKRW"));
        assertEquals(salary.path("bookingDate"), row.path("bookingDate"));
        assertEquals(salary.path("accountId"), row.path("accountId"));
        assertEquals(source.path("asOf"), facts.path("asOf"));
        assertFalse(facts.toString().contains("payseTransactionType"));
        assertFalse(facts.toString().contains("userId"));
        assertFalse(facts.toString().contains("balanceKRW"));
        assertEquals(before, source);
        assertThrows(
            FinancialException.class,
            () -> evidence.modelFacts(UUID.randomUUID(), source, input)
        );
    }

    private final JsonMapper json = JsonMapper.builder().build();
    private final AnalysisEvidence evidence = new AnalysisEvidence();
    private static final List<String> FIELDS = List.of(
        AnalysisFields.TRANSACTION_ID,
        AnalysisFields.RECORD_KIND,
        AnalysisFields.DIRECTION,
        AnalysisFields.STATUS,
        AnalysisFields.REFLECTION_REASON,
        AnalysisFields.MERCHANT_NAME,
        AnalysisFields.DESCRIPTION,
        AnalysisFields.ORIGINAL_TRANSACTION_ID
    );

    /**
     * 원천·입력을 보존하고 반환값 수정도 호출자의 자료를 바꾸지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void preservesSources() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode input = input(source, List.of(salary(source)));
        ObjectNode beforeSource = source.deepCopy(), beforeInput = input.deepCopy();
        ObjectNode result = evidence.verify(owner(source), source, input);
        assertEquals(input, result);
        assertNotSame(input, result);
        ((ObjectNode) result.get(AnalysisFields.CONTEXT)).put(AnalysisFields.INPUT_REVISION, 99);
        assertEquals(beforeSource, source);
        assertEquals(beforeInput, input);
    }

    /**
     * UUID 정렬 첫 100건 밖의 실제 거래도 전체 DB 원천으로 검증한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     * @modified 2026-11-02 - 기존 자연 정렬을 명시적 수신자 람다로 표현
     */
    @Test
    void acceptsLaterPage() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode target = salary(source);
        List<String> ids = new ArrayList<>();
        source.get(AnalysisFields.TRANSACTIONS)
            .forEach(row -> ids.add(row.get(AnalysisFields.TRANSACTION_ID).asString()));
        ids.sort((left, right) -> left.compareTo(right));
        assertTrue(ids.indexOf(target.get(AnalysisFields.TRANSACTION_ID).asString()) >= 100);
        ObjectNode input = input(source, List.of(target));
        assertEquals(input, evidence.verify(owner(source), source, input));
    }

    /**
     * 같은 입력이어도 인증 사용자가 원천 소유자와 다르면 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsOtherOwner() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode other = source("beta-ready");
        assertFalse(owner(source).equals(owner(other)));
        failure(
            403,
            AnalysisCodes.RESOURCE_FORBIDDEN,
            owner(other),
            source,
            input(source, List.of(salary(source)))
        );
    }

    /**
     * 입력 문맥을 현재 사용자 것으로 꾸며도 다른 사용자의 거래는 허용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsOtherUsersTransaction() throws Exception {
        ObjectNode source = source("demo-ready"), other = source("beta-ready");
        ObjectNode input = input(other, List.of(salary(other)));
        input.set(AnalysisFields.CONTEXT, context(source));
        failure(403, AnalysisCodes.RESOURCE_FORBIDDEN, owner(source), source, input);
    }

    /**
     * 연결 해제 이후에는 이전에 받은 정확한 거래 내용도 분석에 사용하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsDisconnectedBank() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode target = salary(source), input = input(source, List.of(target));
        disconnect(source, target);
        failure(403, AnalysisCodes.RESOURCE_FORBIDDEN, owner(source), source, input);
    }

    /**
     * 선택 목록에 다른 계좌를 넣어도 금융 공개 권한을 넓히지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsForeignSelection() throws Exception {
        ObjectNode source = source("demo-ready"), other = source("beta-ready");
        ObjectNode input = input(source, List.of(salary(source)));
        ((ArrayNode) input.get(AnalysisFields.CONTEXT).get(AnalysisFields.SELECTED_ACCOUNT_IDS))
            .add(salary(other).get(AnalysisFields.ACCOUNT_ID));
        failure(403, AnalysisCodes.RESOURCE_FORBIDDEN, owner(source), source, input);
    }

    /**
     * 금융 데이터·원천 버전과 기준 시각이 바뀌면 현재 문맥을 다시 받게 한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsStaleContext() throws Exception {
        ObjectNode source = source("demo-ready");
        Map<String, String> changed = Map.of(
            AnalysisFields.DATA_VERSION,
            "9223372036854775807",
            AnalysisFields.SOURCE_VERSION,
            "different-source",
            AnalysisFields.AS_OF,
            "2026-10-20T12:00:00+09:00"
        );
        for (var entry : changed.entrySet()) {
            ObjectNode input = input(source, List.of(salary(source)));
            ((ObjectNode) input.get(AnalysisFields.CONTEXT)).put(entry.getKey(), entry.getValue());
            failure(409, AnalysisCodes.STALE_DATA, owner(source), source, input);
        }
    }

    /**
     * 다른 계산 규칙 문맥은 일반 입력 오류와 구분한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsWrongRule() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source)));
        ((ObjectNode) input.get(AnalysisFields.CONTEXT))
            .put(AnalysisFields.RULE_VERSION, "different-rule");
        failure(409, AnalysisCodes.RULE_VERSION_MISMATCH, owner(source), source, input);
    }

    /**
     * 사용자 편집 불가인 거래 적요를 임의로 바꾼 분석 입력을 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsChangedSource() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source);
        ObjectNode input = input(source, List.of(target));
        row(
            input,
            AnalysisFields.TRANSACTIONS,
            AnalysisFields.TRANSACTION_ID,
            target.get(AnalysisFields.TRANSACTION_ID).asString()
        ).put(AnalysisFields.DESCRIPTION, "위조 적요");
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 저장 분류를 빼서 출력 충돌 검사를 우회할 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsOmittedClassification() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source)));
        assertEquals(1, input.get(AnalysisFields.CURRENT_CLASSIFICATIONS).size());
        input.putArray(AnalysisFields.CURRENT_CLASSIFICATIONS);
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 분류 정정 후 구버전 값을 보내면 같은 원천 거래라도 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsOldClassification() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source);
        ObjectNode input = input(source, List.of(target));
        assertEquals("income", target.get(AnalysisFields.PAYSE_TRANSACTION_TYPE).asString());
        target.put(AnalysisFields.PAYSE_TRANSACTION_TYPE, "expense");
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 원천 null은 분류 누락 오류로 바꾸지 않으며 임의 확정값을 만들지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void acceptsUnknownClassification() throws Exception {
        ObjectNode source = source("demo-ready"), target = salary(source);
        target.putNull(AnalysisFields.PAYSE_TRANSACTION_TYPE);
        ObjectNode input = input(source, List.of(target));
        assertEquals(0, input.get(AnalysisFields.CURRENT_CLASSIFICATIONS).size());
        assertEquals(input, evidence.verify(owner(source), source, input));
    }

    /**
     * 확인된 본인 이체 양 끝과 관계는 함께 검증한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void acceptsExplicitRelation() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode relation = transfer(source);
        ObjectNode input = input(source, related(source, relation));
        assertEquals(1, input.get(AnalysisFields.RELATIONS).size());
        assertEquals(input, evidence.verify(owner(source), source, input));
    }

    /**
     * 두 거래를 제출해도 실제 명시 관계를 빼면 검증에 실패한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsOmittedRelation() throws Exception {
        ObjectNode source = source("demo-ready"),
            input = input(source, related(source, transfer(source)));
        input.putArray(AnalysisFields.RELATIONS);
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 형식상 가능한 반대 방향 관계라도 DB에 없으면 위조로 거절한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsForgedRelation() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        ObjectNode input = input(source, related(source, relation));
        ObjectNode sent = unique(input.get(AnalysisFields.RELATIONS), ignored -> true);
        sent.set(AnalysisFields.FROM_ID, relation.get(AnalysisFields.TO_ID));
        sent.set(AnalysisFields.TO_ID, relation.get(AnalysisFields.FROM_ID));
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 명시 관계 반대쪽의 공개 근거를 빼고 한 거래만 판단하게 만들 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsMissingRelationEndpoint() throws Exception {
        ObjectNode source = source("demo-ready"), relation = transfer(source);
        ObjectNode target = row(
            source,
            AnalysisFields.TRANSACTIONS,
            AnalysisFields.TRANSACTION_ID,
            relation.get(AnalysisFields.FROM_ID).asString()
        );
        failure(
            422,
            AnalysisCodes.VALIDATION_FAILED,
            owner(source),
            source,
            input(source, List.of(target))
        );
    }

    /**
     * 취소의 실제 원거래를 null로 지워 판단 근거를 없앨 수 없다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsRemovedOriginal() throws Exception {
        ObjectNode source = source("demo-ready");
        ObjectNode cancel = unique(
            source.get(AnalysisFields.TRANSACTIONS),
            value -> "card_cancellation".equals(value.path(AnalysisFields.RECORD_KIND).asString())
        );
        ObjectNode input = input(source, List.of(cancel));
        row(
            input,
            AnalysisFields.TRANSACTIONS,
            AnalysisFields.TRANSACTION_ID,
            cancel.get(AnalysisFields.TRANSACTION_ID).asString()
        ).putNull(AnalysisFields.ORIGINAL_TRANSACTION_ID);
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 미확보 표식의 ID·사유만으로 원거래의 소유·기관 공개 권한을 인정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsUnverifiedOriginalAccess() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        ObjectNode resolution = unique(
            source.get(AnalysisFields.REFERENCE_RESOLUTIONS),
            ignored -> true
        );
        ObjectNode refund = unique(
            source.get(AnalysisFields.TRANSACTIONS),
            value -> resolution.get(AnalysisFields.TRANSACTION_ID)
                .equals(value.get(AnalysisFields.ORIGINAL_TRANSACTION_ID))
        );
        ObjectNode input = input(source, List.of(refund));
        assertEquals(1, input.get(AnalysisFields.UNAVAILABLE_REFERENCES).size());
        failure(503, AnalysisCodes.TEMPORARILY_UNAVAILABLE, owner(source), source, input);
    }

    /**
     * 원천에 없는 미확보 사유나 미확보 기록 삭제를 정상 근거로 인정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsFabricatedUnavailableReason() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        ObjectNode resolution = unique(
            source.get(AnalysisFields.REFERENCE_RESOLUTIONS),
            ignored -> true
        );
        ObjectNode refund = unique(
            source.get(AnalysisFields.TRANSACTIONS),
            value -> resolution.get(AnalysisFields.TRANSACTION_ID)
                .equals(value.get(AnalysisFields.ORIGINAL_TRANSACTION_ID))
        );
        ObjectNode input = input(source, List.of(refund));
        unique(input.get(AnalysisFields.UNAVAILABLE_REFERENCES), ignored -> true)
            .put(AnalysisFields.REASON, "outside_retention");
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
        input = input(source, List.of(refund));
        source.putArray(AnalysisFields.REFERENCE_RESOLUTIONS);
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 현재 원거래를 읽을 권한이 없으면 그 ID를 모델 입력으로 복원하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsHiddenOriginal() throws Exception {
        ObjectNode source = source("refund-unavailable-original");
        ObjectNode resolution = unique(
            source.get(AnalysisFields.REFERENCE_RESOLUTIONS),
            ignored -> true
        );
        ObjectNode refund = unique(
            source.get(AnalysisFields.TRANSACTIONS),
            value -> resolution.get(AnalysisFields.TRANSACTION_ID)
                .equals(value.get(AnalysisFields.ORIGINAL_TRANSACTION_ID))
        );
        resolution.put(AnalysisFields.REASON, "not_connected");
        failure(
            403,
            AnalysisCodes.RESOURCE_FORBIDDEN,
            owner(source),
            source,
            input(source, List.of(refund))
        );
    }

    /**
     * 평가용 verified 표시를 넣어도 API에서 신뢰 근거로 인정하지 않는다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void rejectsClientVerificationFlag() throws Exception {
        ObjectNode source = source("demo-ready"), input = input(source, List.of(salary(source)));
        input.put(AnalysisFields.VERIFIED, true);
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 로컬 반복 후보는 영구 DB 후보를 요구하지 않고 실제 근거·버전·준비 상태만 검사한다.
     * @created 2026-11-01
     * @usedBy JUnit
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    @Test
    void acceptsLocalCandidate() throws Exception {
        ObjectNode source = source("demo-ready");
        List<ObjectNode> selected = new ArrayList<>();
        for (String month : List.of(
            "2026-07",
            "2026-08",
            "2026-09"
        )) {
            selected.add(
                unique(
                    source.get(AnalysisFields.TRANSACTIONS),
                    row -> row.path(AnalysisFields.SOURCE_REF)
                        .asString()
                        .endsWith("/salary/" + month)
                )
            );
        }
        ObjectNode input = input(source, selected)
            .put(AnalysisFields.SEMANTIC_TASK_KIND, "recurringMeaning");
        ObjectNode candidate = ((ArrayNode) input.get(AnalysisFields.CANDIDATES)).addObject()
            .put(AnalysisFields.CANDIDATE_KEY, "monthly-income");
        candidate.set(AnalysisFields.RULE_VERSION, source.get(AnalysisFields.RULE_VERSION));
        candidate.set(AnalysisFields.SOURCE_VERSION, source.get(AnalysisFields.SOURCE_VERSION));
        candidate.put(AnalysisFields.NORMALIZED_NAME, "반복 입금 후보")
            .put(AnalysisFields.SUGGESTED_AMOUNT_KRW, 3000000)
            .put(AnalysisFields.SUGGESTED_DAY, 25);
        ArrayNode refs = candidate.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS);
        selected.forEach(row -> refs.add(row.get(AnalysisFields.TRANSACTION_ID)));
        ObjectNode features = candidate.putObject(AnalysisFields.FEATURES)
            .put(AnalysisFields.OCCURRENCE_COUNT, 3)
            .put(AnalysisFields.DAY_WITHIN_RULE, true)
            .put(AnalysisFields.AMOUNT_WITHIN_RULE, true)
            .put(AnalysisFields.HAS_UNRESOLVED_REVERSAL, false);
        features.putArray(AnalysisFields.OBSERVED_MONTHS)
            .add("2026-07")
            .add("2026-08")
            .add("2026-09");
        ObjectNode item = input.putArray(AnalysisFields.ITEMS)
            .addObject()
            .put(AnalysisFields.ITEM_KEY, "monthly-income-item")
            .putNull(AnalysisFields.TARGET_TRANSACTION_ID)
            .put(AnalysisFields.CANDIDATE_KEY, "monthly-income");
        item.set(AnalysisFields.EVIDENCE_TRANSACTION_IDS, refs.deepCopy());
        assertEquals(input, evidence.verify(owner(source), source, input));
        features.put(AnalysisFields.HAS_UNRESOLVED_REVERSAL, true);
        failure(422, AnalysisCodes.VALIDATION_FAILED, owner(source), source, input);
    }

    /**
     * 제품 fixture는 읽기만 하며 각 검사에서 별도의 메모리 객체를 사용한다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     */
    private ObjectNode source(String name) throws Exception {
        return (ObjectNode) json
            .readTree(Files.readString(Path.of("fixtures/generated-v4/snapshots", name + ".json")));
    }

    /**
     * 입력 화면 문맥을 원천에서 구성하되 Flutter 소유 epoch·revision은 명시 시험값으로 둔다.
     * @created 2026-11-01
     * @usedBy input, rejectsOtherUsersTransaction
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode context(ObjectNode source) {
        ObjectNode result = json.createObjectNode()
            .put(AnalysisFields.SCHEMA_VERSION, AnalysisCodes.API_V4);
        for (String field : List.of(
            AnalysisFields.DATA_VERSION,
            AnalysisFields.SOURCE_VERSION,
            AnalysisFields.RULE_VERSION,
            AnalysisFields.AS_OF
        )) {
            result.set(field, source.get(field));
        }
        result.put(AnalysisFields.INPUT_REVISION, 4)
            .put(AnalysisFields.LOCAL_SESSION_EPOCH, 17)
            .putArray(AnalysisFields.SELECTED_ACCOUNT_IDS);
        return result;
    }

    /**
     * 선택한 준비 거래의 ID·실제 관계·분류만 복사한다. 검사 대상 구현은 정답 생성에 호출하지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조; 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode input(ObjectNode source, List<ObjectNode> selected) {
        ObjectNode result = json.createObjectNode()
            .put(AnalysisFields.CONTRACT_VERSION, AnalysisCodes.ANALYSIS_CONTRACT)
            .put(AnalysisFields.SEMANTIC_TASK_KIND, "transactionMeaning");
        result.set(AnalysisFields.CONTEXT, context(source));
        ArrayNode items = result.putArray(AnalysisFields.ITEMS),
            transactions = result.putArray(AnalysisFields.TRANSACTIONS);
        ArrayNode relations = result.putArray(AnalysisFields.RELATIONS),
            missing = result.putArray(AnalysisFields.UNAVAILABLE_REFERENCES);
        ArrayNode classifications = result.putArray(AnalysisFields.CURRENT_CLASSIFICATIONS);
        result.putArray(AnalysisFields.CANDIDATES);
        Set<String> ids = selected.stream()
            .map(row -> row.get(AnalysisFields.TRANSACTION_ID).asString())
            .collect(java.util.stream.Collectors.toSet());
        for (ObjectNode target : selected) {
            String id = target.get(AnalysisFields.TRANSACTION_ID).asString();
            ObjectNode transaction = transactions.addObject();
            for (String field : FIELDS) {
                transaction.set(field, target.get(field).deepCopy());
            }
            ObjectNode item = items.addObject()
                .put(AnalysisFields.ITEM_KEY, "transaction:" + id)
                .put(AnalysisFields.TARGET_TRANSACTION_ID, id)
                .putNull(AnalysisFields.CANDIDATE_KEY);
            ArrayNode evidenceIds = item.putArray(AnalysisFields.EVIDENCE_TRANSACTION_IDS);
            ids.stream()
                .sorted()
                .forEach(evidenceIds::add);
            if (!target.get(AnalysisFields.PAYSE_TRANSACTION_TYPE).isNull()) {
                classifications.addObject()
                    .put(AnalysisFields.TRANSACTION_ID, id)
                    .set(
                        AnalysisFields.VALUE,
                        target.get(AnalysisFields.PAYSE_TRANSACTION_TYPE).deepCopy()
                    );
            }
        }
        for (JsonNode relation : source.get(AnalysisFields.TRANSACTION_RELATIONS)) {
            if (ids.contains(relation.get(AnalysisFields.FROM_ID).asString())
                && ids.contains(relation.get(AnalysisFields.TO_ID).asString())) {
                ObjectNode value = relations.addObject();
                for (String field : List.of(
                    AnalysisFields.KIND,
                    AnalysisFields.FROM_ID,
                    AnalysisFields.TO_ID
                )) {
                    value.set(field, relation.get(field).deepCopy());
                }
            }
        }
        Set<String> originalIds = selected.stream()
            .filter(row -> !row.get(AnalysisFields.ORIGINAL_TRANSACTION_ID).isNull())
            .map(row -> row.get(AnalysisFields.ORIGINAL_TRANSACTION_ID).asString())
            .collect(java.util.stream.Collectors.toSet());
        for (JsonNode resolution : source.get(AnalysisFields.REFERENCE_RESOLUTIONS)) {
            if (originalIds.contains(resolution.get(AnalysisFields.TRANSACTION_ID).asString())) {
                missing.addObject()
                    .set(
                        AnalysisFields.TRANSACTION_ID,
                        resolution.get(AnalysisFields.TRANSACTION_ID).deepCopy()
                    )
                    .set(AnalysisFields.REASON, resolution.get(AnalysisFields.REASON).deepCopy());
            }
        }
        return result;
    }

    /**
     * 표시명이나 고정 UUID 대신 생성기의 안정된 원천 참조로 시험 거래를 유일하게 찾는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode salary(ObjectNode source) {
        ObjectNode target = unique(
            source.get(AnalysisFields.TRANSACTIONS),
            row -> row.path(AnalysisFields.SOURCE_REF)
                .asString()
                .endsWith("/salary/2026-06")
        );
        assertEquals(source.get(AnalysisFields.USER_ID), target.get(AnalysisFields.USER_ID));
        assertEquals("account_entry", target.get(AnalysisFields.RECORD_KIND).asString());
        assertEquals("in", target.get(AnalysisFields.DIRECTION).asString());
        return target;
    }

    /**
     * 명시된 본인 이체 관계가 정확히 하나인 준비 조건을 먼저 확인한다.
     * @created 2026-11-01
     * @usedBy 관계 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private ObjectNode transfer(ObjectNode source) {
        return unique(
            source.get(AnalysisFields.TRANSACTION_RELATIONS),
            row -> "internal_transfer".equals(row.path(AnalysisFields.KIND).asString())
        );
    }

    /**
     * 관계 양 끝을 실제 준비 자료에서 해석하고 없거나 중복이면 시험 준비를 실패시킨다.
     * @created 2026-11-01
     * @usedBy 관계 검사
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private List<ObjectNode> related(ObjectNode source, ObjectNode relation) {
        return List.of(
            row(
                source,
                AnalysisFields.TRANSACTIONS,
                AnalysisFields.TRANSACTION_ID,
                relation.get(AnalysisFields.FROM_ID).asString()
            ),
            row(
                source,
                AnalysisFields.TRANSACTIONS,
                AnalysisFields.TRANSACTION_ID,
                relation.get(AnalysisFields.TO_ID).asString()
            )
        );
    }

    /**
     * 거래의 원천 금융사 연결만 메모리에서 해제하고 다른 연결은 그대로 둔다.
     * @created 2026-11-01
     * @usedBy rejectsDisconnectedBank
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private void disconnect(ObjectNode source, ObjectNode transaction) {
        boolean account = "account_entry"
            .equals(transaction.get(AnalysisFields.RECORD_KIND).asString());
        String key = account ? AnalysisFields.ACCOUNT_ID : AnalysisFields.CARD_ID;
        ObjectNode parent = row(
            source,
            account ? AnalysisFields.ACCOUNTS : AnalysisFields.CARDS,
            key,
            transaction.get(key).asString()
        );
        ObjectNode link = row(
            source,
            AnalysisFields.INSTITUTION_LINKS,
            AnalysisFields.INSTITUTION_CODE,
            parent.get(AnalysisFields.INSTITUTION_CODE).asString()
        );
        assertTrue(link.get(AnalysisFields.DISCONNECTED_AT).isNull());
        link.put(AnalysisFields.DISCONNECTED_AT, "2026-10-20T12:00:00+09:00");
    }

    /**
     * 명시 참조로 찾은 대상의 유일성을 검사한다.
     * @created 2026-11-01
     * @usedBy 시험 준비 도우미
     */
    private ObjectNode row(ObjectNode source, String array, String key, String value) {
        return unique(source.get(array), row -> value.equals(row.path(key).asString()));
    }

    /**
     * 첫 행·표시명·LIMIT 1 대신 단일 대상이라는 준비 조건을 확인한다.
     * @created 2026-11-01
     * @usedBy row, salary, transfer, 미확보 참조 검사
     * @modified 2026-11-02 - 단일 제어문 본문 중괄호 명시
     */
    private ObjectNode unique(JsonNode rows, Predicate<JsonNode> predicate) {
        List<ObjectNode> matches = new ArrayList<>();
        for (JsonNode row : rows) {
            if (predicate.test(row)) {
                matches.add((ObjectNode) row);
            }
        }
        assertEquals(1, matches.size(), "Fixture selection must identify exactly one row");
        return matches.getFirst();
    }

    /**
     * 준비 원천에 저장된 사용자를 읽고 임의 UUID를 검사에 심지 않는다.
     * @created 2026-11-01
     * @usedBy AnalysisEvidenceTest
     * @modified 2026-11-02 - 계약 문자열 상수 분리 및 테스트 통합 파일 참조
     */
    private UUID owner(ObjectNode source) {
        return UUID.fromString(source.get(AnalysisFields.USER_ID).asString());
    }

    /**
     * 공개 상태·코드를 명시 기대값으로 검증한다.
     * @created 2026-11-01
     * @usedBy 오류 검사
     */
    private void failure(int status, String code, UUID owner, ObjectNode source, ObjectNode input) {
        FinancialException failure = assertThrows(
            FinancialException.class,
            () -> evidence.verify(owner, source, input)
        );
        assertEquals(status, failure.status());
        assertEquals(code, failure.code());
    }
}
