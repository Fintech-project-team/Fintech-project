package com.payse.api.analysis.mapper;

import com.payse.api.analysis.service.AnalysisJson;
import com.payse.api.auth.mapper.AuthTransactions;
import com.payse.api.constants.ApiMessageConstants.Execution;
import jakarta.persistence.EntityManager;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import tools.jackson.databind.node.ObjectNode;

/**
 * 프로젝트 비용을 결과·세션 수명과 분리해 보존한다. 외부 호출은 트랜잭션 밖에서 수행한다.
 * @created 2026-11-03
 * @usedBy AnalysisConfiguration, AnalysisRuntime, CostedModel, CostedKeys
 */
@Repository
@Profile("database & auth & finance & analysis")
public class AnalysisCosts {
    private final EntityManager entityManager;
    private final AuthTransactions transactions;

    /**
     * 기존 최소 권한 JPA 연결과 트랜잭션 경계를 사용한다.
     * @created 2026-11-03
     * @usedBy Spring 생성자 주입
     */
    public AnalysisCosts(EntityManager entityManager, AuthTransactions transactions) {
        this.entityManager = entityManager;
        this.transactions = transactions;
    }

    /**
     * 자격이나 금융 본문이 없는 승인 단가만 독립 트랜잭션에서 읽는다.
     * @created 2026-11-03
     * @usedBy AnalysisConfiguration.analysisRuntime
     */
    public ObjectNode policy(String project, String version) {
        return transactions.run(() -> {
            Object value = entityManager.createNativeQuery(
                "SELECT payse.analysis_cost_policy(?1, ?2)::text"
            ).setParameter(1, project).setParameter(2, version).getSingleResult();
            if (value == null) {
                throw new IllegalStateException(Execution.COST_UNAVAILABLE);
            }
            return (ObjectNode) AnalysisJson.JSON.readTree(value.toString());
        });
    }

    /**
     * 작업·시도와 같은 트랜잭션에 최대 비용을 예약한다. 이 메서드는 커밋하지 않는다.
     * @created 2026-11-03
     * @usedBy AnalysisRuntime.reserve, reserveCall
     */
    public void reserve(
        String project,
        UUID call,
        String version,
        String category,
        long maximum
    ) {
        requireTransaction();
        entityManager.createNativeQuery(
            "SELECT 1 FROM payse.analysis_cost_reserve(?1, ?2, ?3, ?4, ?5)"
        )
            .setParameter(1, project)
            .setParameter(2, call)
            .setParameter(3, version)
            .setParameter(4, category)
            .setParameter(5, maximum)
            .getSingleResult();
    }

    /**
     * 결과 복호화 등 작업 접수와 별개인 외부 호출 비용을 먼저 커밋한다.
     * @created 2026-11-03
     * @usedBy CostedKeys
     */
    public void reserveCall(
        String project,
        UUID call,
        String version,
        String category,
        long maximum
    ) {
        transactions.run(() -> {
            reserve(project, call, version, category, maximum);
            return null;
        });
    }

    /**
     * 현재 한도를 다시 검사하고 한 번만 전송권을 커밋한다. 커밋 불명은 전송하지 않는다.
     * @created 2026-11-03
     * @usedBy CostedModel, CostedKeys
     */
    public boolean start(String project, UUID call) {
        return transactions.run(() -> Boolean.TRUE.equals(
            entityManager.createNativeQuery("SELECT payse.analysis_cost_start(?1, ?2)")
                .setParameter(1, project)
                .setParameter(2, call)
                .getSingleResult()
        ));
    }

    /**
     * 관측한 비용을 인증 세션·결과 저장 성공과 무관하게 커밋한다.
     * @created 2026-11-03
     * @usedBy CostedModel, CostedKeys
     */
    public void settle(String project, UUID call, long actual) {
        finish(project, call, actual, false);
    }

    /**
     * 어댑터가 전송 전 실패를 확정한 호출만 0으로 반납한다.
     * @created 2026-11-03
     * @usedBy CostedModel, CostedKeys
     */
    public void notSent(String project, UUID call) {
        finish(project, call, 0, true);
    }

    /**
     * 전송권조차 얻지 않은 예약만 반납한다. 전송·완료 불명은 유지한다.
     * @created 2026-11-03
     * @usedBy AnalysisRuntime.cancel, CostedModel.releaseUnstarted
     */
    public void releaseUnstarted(String project, UUID call) {
        transactions.run(() -> {
            entityManager.createNativeQuery(
                "SELECT 1 FROM payse.analysis_cost_release(?1, ?2)"
            ).setParameter(1, project).setParameter(2, call).getSingleResult();
            return null;
        });
    }

    /**
     * 정산은 외부 호출 이후의 별도 커밋이며 기존 확정값을 덮어쓰지 않는다.
     * @created 2026-11-03
     * @usedBy settle, notSent
     */
    private void finish(String project, UUID call, long actual, boolean notSent) {
        transactions.run(() -> {
            entityManager.createNativeQuery(
                "SELECT 1 FROM payse.analysis_cost_finish(?1, ?2, ?3, ?4)"
            )
                .setParameter(1, project)
                .setParameter(2, call)
                .setParameter(3, actual)
                .setParameter(4, notSent)
                .getSingleResult();
            return null;
        });
    }

    /**
     * 자동 커밋으로 작업·예약의 원자성을 잃는 호출을 차단한다.
     * @created 2026-11-03
     * @usedBy reserve
     */
    private void requireTransaction() {
        if (!TransactionSynchronizationManager.isActualTransactionActive()
            || !entityManager.isJoinedToTransaction()) {
            throw new IllegalStateException(Execution.TRANSACTION_REQUIRED);
        }
    }
}
