package com.payse.api.finance.mapper;

import com.payse.api.finance.dto.StoredReceipt;
import com.payse.api.finance.entity.WriteReceiptEntity;
import com.payse.api.finance.error.FinancialException;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceException;
import java.time.OffsetDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.context.annotation.Profile;
import org.springframework.stereotype.Repository;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

/**
 * 같은 사용자 잠금 안에서 불변 JPA 영수증과 명시적 자료 버전을 기록한다.
 * @created 2026-10-29
 * @usedBy FinancialService
 * @modified 2026-10-29 - 영수증은 실제 엔티티로 저장하고 기존 버전 증가·멱등 의미 유지
 */
@Repository
@Profile("database & auth & finance")
public class FinancialReceipts {
    private final EntityManager entityManager;
    private final WriteStore store;
    private final JsonMapper json = JsonMapper.builder().build();

    /**
     * 인증과 업무 저장이 공유하는 영속성 문맥을 주입한다.
     * @created 2026-10-29
     * @usedBy Spring 생성자 주입
     * @modified 2026-10-29 - JDBC 대신 같은 트랜잭션의 EntityManager 사용
     */
    public FinancialReceipts(EntityManager entityManager) {
        this.entityManager = entityManager;
        store = new WriteStore(entityManager);
    }

    /**
     * 사용자·키로 불변 영수증 엔티티를 조회해 버전 검사보다 먼저 재시도를 판정한다.
     * @created 2026-10-29
     * @usedBy FinancialService.write
     * @modified 2026-10-29 - JPQL 소유자 조회와 관리 엔티티 복원 사용
     */
    public Optional<StoredReceipt> find(UUID user, String key, String digest) {
        store.requireOwner(user);
        try {
            List<WriteReceiptEntity> found = entityManager.createQuery("""
                SELECT receipt FROM WriteReceiptEntity receipt
                WHERE receipt.userId = :user AND receipt.operationKey = :key
                """, WriteReceiptEntity.class).setParameter("user", user).setParameter("key", key).getResultList();
            if (found.size() > 1) throw WriteStore.unavailable();
            if (found.isEmpty()) return Optional.empty();
            WriteReceiptEntity receipt = found.getFirst();
            if (!user.equals(receipt.userId())) throw WriteStore.unavailable();
            if (!digest.equals(receipt.requestDigest())) throw new FinancialException(409, "IDEMPOTENCY_CONFLICT");
            return Optional.of(stored(receipt));
        } catch (PersistenceException failure) { throw store.storageFailure(failure); }
    }

    /**
     * 설정 변경을 flush한 뒤 명시적 버전을 증가시키고 성공 영수증을 같은 트랜잭션에 persist한다.
     * @created 2026-10-29
     * @usedBy FinancialService.write
     * @modified 2026-10-29 - 설정·영수증 엔티티와 기존 native 버전 계약의 원자성 유지
     */
    public StoredReceipt save(UUID user, String key, String digest, String action,
            ArrayNode changedRefs, ObjectNode beforeAfter) {
        store.requireOwner(user);
        store.flush();
        try {
            // 사용자 잠금 아래의 계약 버전이다. JPA @Version으로 의미를 바꾸지 않는다.
            String version = (String) entityManager.createNativeQuery("""
                UPDATE payse.users
                SET data_version = data_version + 1
                WHERE id = ?1 AND data_version < 9223372036854775807
                RETURNING data_version::text
                """, String.class).setParameter(1, user).getSingleResult();
            if (version == null) throw WriteStore.unavailable();
            OffsetDateTime time = store.scalar("SELECT clock_timestamp()", OffsetDateTime.class);
            WriteReceiptEntity receipt = new WriteReceiptEntity(UUID.randomUUID(), user, key, digest, action,
                changedRefs.toString(), beforeAfter.toString(), Long.parseLong(version), time);
            store.persist(receipt);
            return stored(receipt);
        } catch (PersistenceException failure) { throw store.storageFailure(failure); }
    }

    /**
     * 영수증까지 flush한 뒤 지연 제약을 검사한다. 실패하면 이미 실행한 변경도 전부 롤백한다.
     * @created 2026-10-29
     * @usedBy FinancialService.write
     * @modified 2026-10-29 - ORM flush를 명시해 제약 검사 뒤에 미검증 SQL이 남지 않도록 처리
     */
    public void checkConstraints() {
        store.flush();
        try { entityManager.createNativeQuery("SET CONSTRAINTS ALL IMMEDIATE").executeUpdate(); }
        catch (PersistenceException failure) { throw store.storageFailure(failure); }
    }

    /**
     * 엔티티를 외부에 노출하지 않고 기존 공개 요약과 내부 감사 객체로 분리한다.
     * @created 2026-10-29
     * @usedBy FinancialReceipts.find, save
     */
    private StoredReceipt stored(WriteReceiptEntity receipt) {
        JsonNode changes = json.readTree(receipt.changedRefs());
        JsonNode audit = json.readTree(receipt.beforeAfter());
        if (!changes.isArray() || !(audit instanceof ObjectNode object)) throw WriteStore.unavailable();
        ObjectNode result = json.createObjectNode().put("receiptId", receipt.id().toString())
            .put("operationKey", receipt.operationKey()).put("resultVersion", Long.toString(receipt.resultVersion()))
            .put("createdAt", receipt.createdAt().toInstant().toString());
        result.set("changedRefs", changes);
        return new StoredReceipt(result, object);
    }
}
