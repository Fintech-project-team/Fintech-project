"""2026-10-29: JDBC 원거래 JOIN 검사에만 사용하는 격리 데이터 준비 도구."""

import uuid

from auth_test_support import quote


def prepare_links(cluster, database, user):
    """2026-10-29: 사용자별 원결제·날짜만 있는 취소·미확보/미상 관계를 만든다.

    사용: test_auth_jdbc.prepare_database; 운영 DB나 fixture 원천은 변경하지 않는다.
    반환 ID는 모두 생성 뒤 개수·소유권·관계를 확인한 준비 자료다.
    """
    values = {name: str(uuid.uuid4()) for name in (
        "card", "link", "purchase", "cancellation", "unavailable", "missing", "unreferenced",
        "hidden_card", "hidden_purchase")}
    institution = "jdbc-card-" + uuid.uuid4().hex
    unlinked_institution = "jdbc-card-" + uuid.uuid4().hex
    owner = quote(user["user"])
    identifiers = {name: quote(value) for name, value in values.items()}
    resolved = ",\n".join(
        f"({owner}, {identifiers[name]}, 'resolved', NULL)"
        for name in ("purchase", "cancellation", "unavailable", "unreferenced", "hidden_purchase"))
    statement = f"""
        BEGIN;
        -- 기관 연결은 사용자별 카드의 원천 조회 권한이며 계산 포함 선택과는 별개다.
        INSERT INTO payse.institutions (code, kind, name)
        VALUES ({quote(institution)}, 'card', '가상결제사'),
            ({quote(unlinked_institution)}, 'card', '미연결결제사');
        INSERT INTO payse.institution_links (id, user_id, institution_code, consented_at)
        VALUES ({identifiers['link']}, {owner}, {quote(institution)}, '2026-10-01T00:00:00Z');
        INSERT INTO payse.financial_cards (
            id, user_id, institution_code, source_ref, source_version, card_type, schedule_evidence
        )
        VALUES (
            {identifiers['card']}, {owner}, {quote(institution)}, {identifiers['card']},
            'jdbc-source', 'credit', '[]'
        ), (
            {identifiers['hidden_card']}, {owner}, {quote(unlinked_institution)},
            {identifiers['hidden_card']}, 'jdbc-source', 'credit', '[]'
        );
        -- 참조 없음과 ID만 확보된 원거래를 구분하며 실제 원거래 행을 꾸며 넣지 않는다.
        INSERT INTO payse.transaction_references (user_id, transaction_id, resolution, reason)
        VALUES {resolved},
            ({owner}, {identifiers['missing']}, 'unavailable', 'not_provided');
        INSERT INTO payse.financial_transactions (
            id, user_id, source_ref, source_version, card_id, record_kind, amount_krw,
            direction, status, reflection_reason, purchase_date, cancellation_date,
            original_transaction_id
        )
        VALUES
            ({identifiers['purchase']}, {owner}, {identifiers['purchase']}, 'jdbc-source',
                {identifiers['card']}, 'card_purchase', 30000, 'out', 'cancelled',
                'not_applicable', '2026-10-12', NULL, NULL),
            ({identifiers['cancellation']}, {owner}, {identifiers['cancellation']}, 'jdbc-source',
                {identifiers['card']}, 'card_cancellation', 30000, 'in', 'cancelled',
                'not_applicable', NULL, '2026-10-13', {identifiers['purchase']}),
            ({identifiers['unavailable']}, {owner}, {identifiers['unavailable']}, 'jdbc-source',
                {identifiers['card']}, 'card_cancellation', 12000, 'in', 'cancelled',
                'not_applicable', NULL, '2026-10-14', {identifiers['missing']}),
            ({identifiers['unreferenced']}, {owner}, {identifiers['unreferenced']}, 'jdbc-source',
                {identifiers['card']}, 'card_cancellation', 8000, 'in', 'cancelled',
                'not_applicable', NULL, '2026-10-15', NULL),
            ({identifiers['hidden_purchase']}, {owner}, {identifiers['hidden_purchase']}, 'jdbc-source',
                {identifiers['hidden_card']}, 'card_purchase', 5000, 'out', 'approved',
                'not_applicable', '2026-10-16', NULL, NULL);
        COMMIT;
        -- 생성 ID의 단일 존재·사용자·카드·원결제 연결을 테스트 시작 전에 확인한다.
        SELECT
            (SELECT count(*) FROM payse.financial_transactions
                WHERE user_id = {owner} AND card_id = {identifiers['card']}) = 4
            AND (SELECT count(*) FROM payse.financial_transactions
                WHERE id = {identifiers['cancellation']} AND user_id = {owner}
                  AND original_transaction_id = {identifiers['purchase']}
                  AND cancellation_date = '2026-10-13' AND occurred_at IS NULL) = 1
            AND (SELECT count(*) FROM payse.transaction_references
                WHERE transaction_id = {identifiers['missing']} AND user_id = {owner}
                  AND resolution = 'unavailable' AND reason = 'not_provided') = 1
            AND NOT EXISTS (SELECT 1 FROM payse.financial_transactions
                WHERE id = {identifiers['missing']})
            AND (SELECT count(*) FROM payse.institution_links
                WHERE id = {identifiers['link']} AND user_id = {owner}
                  AND disconnected_at IS NULL) = 1
            AND (SELECT count(*) FROM payse.financial_transactions
                WHERE id = {identifiers['hidden_purchase']} AND user_id = {owner}
                  AND card_id = {identifiers['hidden_card']}) = 1
            AND NOT EXISTS (SELECT 1 FROM payse.institution_links
                WHERE user_id = {owner} AND institution_code = {quote(unlinked_institution)}
                  AND disconnected_at IS NULL);
    """
    if cluster.sql(statement, database) != ["t"]:
        raise AssertionError("Generated transaction links were not unique and complete")
    return values
