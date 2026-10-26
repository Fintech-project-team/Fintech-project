"""2026-10-22: Resolve SQL test roles from validated fixture relationships only.

Offline test preparation, never imported by the application or migration tool.
Context values select subjects; contract boundaries remain independent assertions.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sys
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'fixtures'))
from validate import validate_directory, validate_snapshot

CASES = ('alpha-ready', 'beta-ready', 'gamma-month-end')
UUID_KEYS = frozenset('''owner_id other_owner_id future_owner_id owner_account_id
other_account_id alternate_salary_account_id spaced_product_account_id reserve_id
allocation_id partial_obligation_id other_obligation_id statement_obligation_id
recurring_obligation_id partial_settlement_id partial_transaction_id
cycle_peer_transaction_id referenced_revision_id write_receipt_id relation_from_id
relation_to_id future_plan_id initial_revision_id future_revision_id
pinned_obligation_id future_initial_obligation_id salary_transaction_id other_salary_transaction_id
outgoing_transaction_id'''.split())
ARRAY_KEYS = frozenset({'card_transaction_ids', 'owner_account_ids'})
TEXT_KEYS = frozenset('''relation_kind owner_name owner_phone spaced_product_name
future_first_month future_revision_month pinned_occurrence_month
override_occurrence_month salary_evidence_date salary_evidence_month'''.split())
INT_KEYS = frozenset({'expected_user_count', 'expected_account_count',
                      'owner_account_count', 'owner_reserve_count'})
ROW_KEYS = {
    'users': ('id',), 'source_contexts': ('user_id',),
    'user_attributes': ('user_id',), 'financial_accounts': ('id',),
    'financial_cards': ('id',), 'financial_transactions': ('id',),
    'obligations': ('id',), 'reserves': ('id',), 'reserve_allocations': ('id',),
    'settlement_links': ('id',), 'write_receipts': ('id',),
    'card_statements': ('id',),
    'statement_items': ('user_id', 'statement_id', 'transaction_id'),
    'transaction_relations': ('user_id', 'kind', 'from_id', 'to_id'),
    'recurring_plans': ('id',), 'recurring_plan_revisions': ('id',),
    'occurrence_overrides': ('user_id', 'plan_id', 'occurrence_month'),
}


def require(condition, message):
    """2026-10-22: Reject preparation failures without dumping fixture bodies."""
    if not condition:
        raise ValueError('SQL test context: ' + message)


def one(rows, role):
    """2026-10-22: Resolve exactly one semantic candidate, never a first match."""
    values = list(rows)
    require(len(values) == 1, role + ' requires exactly one candidate')
    return values[0]


def by_id(rows, field, value, role):
    """2026-10-22: Resolve an explicit relation and reject absent/duplicate targets."""
    return one((row for row in rows if row[field] == value), role)


def canonical_hash(value):
    """2026-10-22: Identify prepared JSON meaning, independently of formatting."""
    body = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(body.encode('utf-8')).hexdigest()


def latest_income(snapshot):
    """2026-10-22: Select the unique latest confirmed incoming fact for proof tests.

    This is a test subject selector, not salary detection or a product calculation.
    """
    candidates = [row for row in snapshot['transactions']
                  if row['accountId'] == snapshot['settings']['salary']['salaryAccountId']
                  and row['recordKind'] == 'account_entry' and row['direction'] == 'in'
                  and row['status'] == 'posted' and row['balanceReflected'] is True
                  and row['payseTransactionType'] == 'income' and row['bookingDate']]
    require(candidates, 'confirmed income missing')
    latest = max(row['bookingDate'] for row in candidates)
    return one((row for row in candidates if row['bookingDate'] == latest), 'latest income')


def build_from_snapshots(cases, seed_users):
    """2026-10-22: Resolve validated graph roles, independently of fixed identity IDs.

    Public build_context first checks the canonical private seed mapping. This
    graph entry point also permits unit tests to consistently remap every UUID.
    """
    require(set(cases) == set(CASES), 'required case set differs')
    for snapshot in cases.values():
        validate_snapshot(snapshot)
    owner, other, future = (cases[name] for name in CASES)
    owners = [snapshot['userId'] for snapshot in (owner, other, future)]
    require(len(set(owners)) == len(owners), 'actor owners must differ')
    require(len(seed_users) == len(owners), 'seed owner count differs')
    seeds = {uid: one((u for u in seed_users if u['userId'] == uid), 'seed owner') for uid in owners}
    require(set(u['userId'] for u in seed_users) == set(owners), 'seed owners differ')
    for snapshot in cases.values():
        require(snapshot['accounts'] and snapshot['institutionLinks'], 'ready financial case required')

    def account(snapshot):
        return by_id(snapshot['accounts'], 'accountId', snapshot['settings']['salary']['salaryAccountId'], 'salary account')

    primary = account(owner)
    peer_account = account(other)
    allocation = one((a for a in owner['allocations'] if 0 < a['releasedKRW'] < a['amountKRW']), 'partial allocation')
    reserve = by_id(owner['reserves'], 'reserveId', allocation['reserveId'], 'partial reserve')
    partial = by_id(owner['obligations'], 'obligationId', allocation['obligationId'], 'partial obligation')
    evidence = one(allocation['releaseEvidence'], 'release evidence')
    settlement = by_id(owner['settlements'], 'linkId', evidence['settlementLinkId'], 'partial settlement')
    partial_tx = by_id(owner['transactions'], 'transactionId', settlement['transactionId'], 'partial withdrawal')
    allocated = {a['obligationId'] for a in owner['allocations']}
    settled = {s['obligationId'] for s in owner['settlements'] if s['invalidatedAt'] is None}
    manual = one((o for o in owner['obligations'] if o['status'] == 'active'
                  and o['statementId'] is None and o['recurringPlanId'] is None
                  and o['obligationId'] not in allocated | settled), 'other manual obligation')
    bill = one((o for o in owner['obligations'] if o['statementId'] is not None and o['status'] == 'active'), 'statement obligation')
    statement = by_id(owner['statements'], 'statementId', bill['statementId'], 'statement')
    card = by_id(owner['cards'], 'cardId', statement['cardId'], 'statement card')
    bill_link = one((s for s in owner['settlements'] if s['obligationId'] == bill['obligationId'] and s['invalidatedAt'] is None), 'statement settlement')
    bill_tx = by_id(owner['transactions'], 'transactionId', bill_link['transactionId'], 'statement withdrawal')
    purchases = [by_id(owner['transactions'], 'transactionId', tid, 'statement purchase') for tid in statement['includedTransactionRefs']]
    recurring = one((o for o in owner['obligations'] if o['recurringPlanId'] is not None), 'recurring obligation')
    revision = by_id(owner['recurringPlanRevisions'], 'revisionId', recurring['planRevisionId'], 'referenced revision')
    plan = by_id(owner['recurringPlans'], 'planId', recurring['recurringPlanId'], 'referenced plan')
    transfer = one((r for r in owner['transactionRelations'] if r['kind'] == 'internal_transfer'), 'internal transfer')
    transfer_txs = [by_id(owner['transactions'], 'transactionId', transfer[key], 'transfer transaction') for key in ('fromId', 'toId')]
    transfer_out = one((t for t in transfer_txs if t['direction'] == 'out'), 'transfer out')
    transfer_in = one((t for t in transfer_txs if t['direction'] == 'in'), 'transfer in')
    alternate = by_id(owner['accounts'], 'accountId', transfer_in['accountId'], 'alternate account')
    override = one(future['occurrenceOverrides'], 'individual override')
    future_revision = by_id(future['recurringPlanRevisions'], 'revisionId', override['planRevisionId'], 'future revision')
    future_plan = by_id(future['recurringPlans'], 'planId', future_revision['planId'], 'future plan')
    initial_revision = one((r for r in future['recurringPlanRevisions'] if r['planId'] == future_plan['planId']
                            and r['effectiveFromMonth'] == future_plan['firstOccurrenceMonth']), 'initial revision')
    initial_obligation = one((o for o in future['obligations'] if o['recurringPlanId'] == future_plan['planId']
                              and o['recurrenceKey'][-7:] == future_plan['firstOccurrenceMonth']), 'initial future-plan occurrence')
    pinned = one((o for o in future['obligations'] if o['recurringPlanId'] == future_plan['planId']
                  and o['planRevisionId'] == initial_revision['revisionId']
                  and o['recurrenceKey'][-7:] >= future_revision['effectiveFromMonth']), 'future occurrence pinned to old revision')
    income, other_income = latest_income(owner), latest_income(other)

    # Independent scenario premises; do not infer these boundaries from DB guards.
    require(primary['accountId'] == reserve['accountId'] == partial['withdrawalAccountId']
            == partial_tx['accountId'] == transfer_out['accountId'], 'primary account relationships differ')
    require(alternate['accountId'] != primary['accountId'], 'alternate account must differ')
    require(reserve['cancelledAt'] is None and partial['status'] == 'active'
            and settlement['invalidatedAt'] is None, 'partial scenario must be active')
    require((partial['amountKRW'], partial_tx['amountKRW'], settlement['allocatedKRW'],
             allocation['amountKRW'], allocation['releasedKRW'], evidence['amountKRW'], reserve['amountKRW'])
            == (100000, 40000, 40000, 100000, 40000, 40000, 400000), 'partial settlement boundary changed')
    require(len(purchases) == 2 and len({p['transactionId'] for p in purchases}) == 2
            and all(p['recordKind'] == 'card_purchase' and p['cardId'] == card['cardId'] for p in purchases), 'statement purchase premises differ')
    require(bill_tx['transactionId'] != partial_tx['transactionId'] and bill_tx['accountId'] == primary['accountId'], 'cycle peer must be a different matching withdrawal')
    require((future_plan['firstOccurrenceMonth'], future_revision['effectiveFromMonth'],
             pinned['recurrenceKey'][-7:], override['recurrenceKey'][-7:])
            == ('2027-01', '2027-03', '2027-03', '2027-04'), 'future month boundary changed')
    require((initial_revision['amountKRW'], future_revision['amountKRW'], pinned['amountKRW'], override['amountKRW'])
            == (100000, 110000, 100000, 120000), 'future amount boundary changed')
    require(initial_revision['isCurrent'] and future_revision['isCurrent'], 'future revision authority changed')
    require(revision['effectiveFromMonth'] == '2026-10', 'referenced revision test month changed')
    require(' ' in primary['productName'], 'source spacing premise missing')

    context = {
        'owner_id': owner['userId'], 'other_owner_id': other['userId'], 'future_owner_id': future['userId'],
        'owner_account_id': primary['accountId'], 'other_account_id': peer_account['accountId'],
        'alternate_salary_account_id': alternate['accountId'], 'spaced_product_account_id': primary['accountId'],
        'reserve_id': reserve['reserveId'], 'allocation_id': allocation['allocationId'],
        'partial_obligation_id': partial['obligationId'], 'other_obligation_id': manual['obligationId'],
        'statement_obligation_id': bill['obligationId'], 'recurring_obligation_id': recurring['obligationId'],
        'partial_settlement_id': settlement['linkId'], 'partial_transaction_id': partial_tx['transactionId'],
        'cycle_peer_transaction_id': bill_tx['transactionId'], 'referenced_revision_id': revision['revisionId'],
        'write_receipt_id': evidence['writeReceiptId'], 'relation_from_id': transfer['fromId'],
        'relation_to_id': transfer['toId'], 'relation_kind': transfer['kind'],
        'future_plan_id': future_plan['planId'], 'initial_revision_id': initial_revision['revisionId'],
        'future_revision_id': future_revision['revisionId'], 'pinned_obligation_id': pinned['obligationId'],
        'future_initial_obligation_id': initial_obligation['obligationId'],
        'salary_transaction_id': income['transactionId'], 'other_salary_transaction_id': other_income['transactionId'],
        'outgoing_transaction_id': partial_tx['transactionId'],
        'card_transaction_ids': sorted(p['transactionId'] for p in purchases),
        'owner_account_ids': sorted(a['accountId'] for a in owner['accounts']),
        'owner_name': seeds[owner['userId']]['name'], 'owner_phone': seeds[owner['userId']]['phone'],
        'spaced_product_name': primary['productName'],
        'future_first_month': future_plan['firstOccurrenceMonth'] + '-01',
        'future_revision_month': future_revision['effectiveFromMonth'] + '-01',
        'pinned_occurrence_month': pinned['recurrenceKey'][-7:] + '-01',
        'override_occurrence_month': override['recurrenceKey'][-7:] + '-01',
        'salary_evidence_date': income['bookingDate'],
        # Independent synthetic proof premise; never infer a payroll cycle from an incoming date.
        'salary_evidence_month': '2026-09',
        'expected_user_count': len(owners), 'expected_account_count': sum(len(s['accounts']) for s in cases.values()),
        'owner_account_count': len(owner['accounts']), 'owner_reserve_count': len(owner['reserves']),
        '_meta': {'format': 'PAYSE-SQL-CONTEXT-1', 'seedMode': 'ready', 'cases': list(CASES),
                  'snapshotHashes': {name: canonical_hash(cases[name]) for name in CASES}},
        '_rows': {table: [] for table in ROW_KEYS},
    }

    def row(table, value):
        rows = context['_rows'][table]
        identity = tuple(value[key] for key in ROW_KEYS[table])
        existing = [r for r in rows if tuple(r[key] for key in ROW_KEYS[table]) == identity]
        require(not existing or existing == [value], 'conflicting expected row')
        if not existing:
            rows.append(value)

    for snapshot in cases.values():
        uid = snapshot['userId']
        row('users', {'id': uid, 'name': seeds[uid]['name'], 'phone': seeds[uid]['phone'], 'data_version': int(snapshot['dataVersion'])})
        row('source_contexts', {'user_id': uid, 'source_version': snapshot['sourceVersion'], 'schema_version': snapshot['schemaVersion'], 'rule_version': snapshot['ruleVersion']})
        row('user_attributes', {'user_id': uid, 'salary_account_id': snapshot['settings']['salary']['salaryAccountId']})
        for a in snapshot['accounts']:
            row('financial_accounts', {'id': a['accountId'], 'user_id': uid, 'source_version': a['sourceVersion'], 'included': a['included'], 'product_name': a['productName']})
    for t in [partial_tx, bill_tx, income, other_income, *purchases, *transfer_txs]:
        row('financial_transactions', {'id': t['transactionId'], 'user_id': t['userId'], 'source_version': t['sourceVersion'],
            'record_kind': t['recordKind'], 'direction': t['direction'], 'status': t['status'],
            'reflection_reason': t['reflectionReason'], 'account_id': t['accountId'], 'card_id': t['cardId'],
            'amount_krw': t['amountKRW'], 'booking_date': t['bookingDate']})
    for o in [partial, manual, bill, recurring, pinned, initial_obligation]:
        row('obligations', {'id': o['obligationId'], 'user_id': o['userId'], 'withdrawal_account_id': o['withdrawalAccountId'],
            'amount_krw': o['amountKRW'], 'status': o['status'], 'statement_id': o['statementId'], 'plan_id': o['recurringPlanId'],
            'plan_revision_id': o['planRevisionId'], 'occurrence_month': o['recurrenceKey'][-7:] + '-01' if o['recurrenceKey'] else None})
    row('reserves', {'id': reserve['reserveId'], 'user_id': owner['userId'], 'account_id': reserve['accountId'], 'amount_krw': reserve['amountKRW'], 'cancelled_at': None})
    row('reserve_allocations', {'id': allocation['allocationId'], 'user_id': owner['userId'], 'reserve_id': allocation['reserveId'],
        'obligation_id': allocation['obligationId'], 'amount_krw': allocation['amountKRW'], 'released_krw': allocation['releasedKRW'], 'release_evidence': allocation['releaseEvidence']})
    for link in [settlement, bill_link]:
        row('settlement_links', {'id': link['linkId'], 'user_id': owner['userId'], 'obligation_id': link['obligationId'],
            'transaction_id': link['transactionId'], 'allocated_krw': link['allocatedKRW'], 'invalidated_at': None})
    row('write_receipts', {'id': evidence['writeReceiptId'], 'user_id': owner['userId'], 'action': 'import_user_state'})
    row('financial_cards', {'id': card['cardId'], 'user_id': owner['userId'], 'withdrawal_account_id': card['withdrawalAccountId']})
    row('card_statements', {'id': statement['statementId'], 'user_id': owner['userId'], 'card_id': card['cardId'], 'amount_krw': statement['amountKRW']})
    for purchase in purchases:
        row('statement_items', {'user_id': owner['userId'], 'statement_id': statement['statementId'], 'card_id': card['cardId'], 'transaction_id': purchase['transactionId']})
    row('transaction_relations', {'user_id': owner['userId'], 'kind': transfer['kind'], 'from_id': transfer['fromId'], 'to_id': transfer['toId']})
    for p in [plan, future_plan]:
        row('recurring_plans', {'id': p['planId'], 'user_id': p['userId'], 'first_occurrence_month': p['firstOccurrenceMonth'] + '-01'})
    for r in [revision, initial_revision, future_revision]:
        row('recurring_plan_revisions', {'id': r['revisionId'], 'user_id': r['userId'], 'plan_id': r['planId'],
            'effective_from_month': r['effectiveFromMonth'] + '-01', 'amount_krw': r['amountKRW'], 'is_current': r['isCurrent']})
    row('occurrence_overrides', {'user_id': future['userId'], 'plan_id': future_plan['planId'],
        'occurrence_month': override['recurrenceKey'][-7:] + '-01', 'plan_revision_id': override['planRevisionId'], 'amount_krw': override['amountKRW']})
    validate_context(context)
    return context


def build_context(directory):
    """2026-10-22: Read validated canonical fixtures and return test-only role data."""
    directory = Path(directory)
    validate_directory(directory)
    catalog = json.loads((directory / 'catalog.json').read_text(encoding='utf-8'))
    selected = {}
    for case in CASES:
        entry = one((row for row in catalog['cases'] if row['id'] == case), 'catalog case')
        selected[case] = json.loads((directory / entry['file']).read_text(encoding='utf-8'))
    seeds = json.loads((directory / 'server-seeds.json').read_text(encoding='utf-8'))
    return build_from_snapshots(selected, seeds['users'])


def validate_context(context):
    """2026-10-22: Require exact typed keys before encoding SQL test inputs."""
    require(type(context) is dict and set(context) == UUID_KEYS | ARRAY_KEYS | TEXT_KEYS | INT_KEYS | {'_meta', '_rows'}, 'context keys differ')
    def uuid(value):
        require(type(value) is str, 'UUID value must be text')
        try:
            require(str(UUID(value)) == value, 'UUID value must be canonical')
        except (ValueError, AttributeError) as error:
            raise ValueError('SQL test context: invalid UUID') from error
    for key in UUID_KEYS:
        uuid(context[key])
    for key in ARRAY_KEYS:
        values = context[key]
        require(type(values) is list and values, 'UUID array must be nonempty')
        for value in values:
            uuid(value)
        require(len(set(values)) == len(values), 'UUID array contains duplicates')
    require(all(type(context[key]) is str and context[key] for key in TEXT_KEYS), 'text role missing')
    require(all(type(context[key]) is int and context[key] > 0 for key in INT_KEYS), 'count must be positive integer')
    require(type(context['_meta']) is dict and context['_meta'].get('format') == 'PAYSE-SQL-CONTEXT-1' and context['_meta'].get('seedMode') == 'ready'
            and context['_meta'].get('cases') == list(CASES), 'context metadata differs')
    require(type(context['_rows']) is dict and set(context['_rows']) == set(ROW_KEYS), 'expected table set differs')
    for table, rows in context['_rows'].items():
        require(type(rows) is list and rows, 'expected rows missing')
        identities = []
        for row in rows:
            require(type(row) is dict and all(key in row for key in ROW_KEYS[table]), 'expected row key missing')
            identities.append(tuple(row[key] for key in ROW_KEYS[table]))
        require(len(set(identities)) == len(identities), 'expected row duplicated')


def context_sql(context):
    """2026-10-22: Return a connection-local prelude; callers run suites afterward.

    The prelude creates no permanent objects and is not an application seed.
    Helpers use invoker rights; callers must prepare RLS probe values before SET ROLE.
    """
    validate_context(context)
    body = json.dumps(context, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    # Dollar quoting preserves JSON backslashes regardless of standard_conforming_strings.
    tag = '$payse_context$'
    while tag in body:
        tag = tag[:-1] + '_$'
    literal = tag + body + tag
    sql = (Path(__file__).with_suffix('.sql')).read_text(encoding='utf-8')
    return ('CREATE TEMP TABLE payse_test_context (value jsonb NOT NULL);\n'
            'INSERT INTO pg_temp.payse_test_context(value) VALUES (' + literal + '::jsonb);\n' + sql)
