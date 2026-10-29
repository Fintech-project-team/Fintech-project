package com.payse.api.finance.mapper;

import com.payse.api.finance.dto.WriteChange;
import com.payse.api.finance.validation.FinancialInput;
import jakarta.persistence.EntityManager;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Component;
import tools.jackson.databind.node.ObjectNode;

/**
 * 검증된 금융 쓰기를 담당 저장 작업에 전달한다. 인증·버전·멱등·커밋은 서비스가 소유한다.
 * @created 2026-10-29
 * @usedBy FinancialService.write
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
 */
@Component
@Profile("database & auth")
public final class FinancialWrites {
    private final WriteStore store;
    private final SettingsWrites settings;
    private final PlanWrites plans;

    /**
     * 기존 인증과 같은 EntityManager의 상태 없는 저장 구성요소를 만든다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    public FinancialWrites(EntityManager entityManager) {
        store = new WriteStore(entityManager);
        settings = new SettingsWrites(store);
        plans = new PlanWrites(store);
    }

    /**
     * 세션 소유자가 잠긴 트랜잭션 안에서 요청 한 건의 설정 변경을 수행한다.
     * @created 2026-10-29
     * @usedBy FinancialService.write
     * @modified 2026-10-29 - JPA 관리 엔티티와 같은 영속성 문맥으로 저장 경계 유지
     */
    public WriteChange apply(UUID owner, String method, String path, ObjectNode body) {
        store.requireOwner(owner);
        WriteStore.Journal journal = store.journal();
        if (method.equals("POST") && path.equals("/institution-links")) settings.link(owner, body, journal);
        else if (method.equals("PATCH") && path.equals("/account-selection")) settings.selection(owner, body, journal);
        else if (method.equals("PATCH") && path.equals("/settings")) settings.settings(owner, body, journal);
        else if (method.equals("PATCH") && path.startsWith("/accounts/")) settings.nickname(owner, FinancialInput.id(path.substring(10)), body, journal);
        else if (method.equals("POST") && path.equals("/obligations")) plans.obligation(owner, null, body, journal);
        else if (method.equals("POST") && path.equals("/reserves")) plans.reserve(owner, null, body, journal);
        else {
            String[] parts = path.split("/");
            UUID id = FinancialInput.id(parts[2]);
            boolean obligation = parts[1].equals("obligations");
            if (method.equals("DELETE") || (method.equals("POST") && path.endsWith("/cancel"))) {
                plans.cancel(owner, id, obligation, body, method.equals("POST"), journal);
            } else if (obligation) plans.obligation(owner, id, body, journal);
            else plans.reserve(owner, id, body, journal);
        }
        return new WriteChange(journal.refs, journal.audit);
    }

}
