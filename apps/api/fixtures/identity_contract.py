"""2026-10-22: Shared synthetic identity mapping for seeds and reviewed DB migration.

This module does not provision credentials, normalize user input, or access a DB.
Legacy names are migration evidence, never an alternative login identity.
"""
from __future__ import annotations

from datetime import datetime
import re
from types import MappingProxyType
from uuid import UUID


IDENTITY_USERS = tuple(MappingProxyType(row) for row in (
    {
        'user_id': 'f0a4be6c-01d7-53eb-ab2c-74675b22fd8c',
        'name': '데모알파',
        'phone': '01000000001',
        'legacy_synthetic_name': 'PAYSE 합성 alpha',
        'legacy_display_name': '데모 1',
        'initial_case': 'demo-life',
    },
    {
        'user_id': '87f7bbf9-2355-5210-9325-f25d83a8ff35',
        'name': '데모베타',
        'phone': '01000000002',
        'legacy_synthetic_name': 'PAYSE 합성 beta',
        'legacy_display_name': '데모 2',
        'initial_case': 'beta-ready',
    },
    {
        'user_id': 'd04073fd-f7ab-518d-8938-f2920d593db2',
        'name': '데모감마',
        'phone': '01000000003',
        'legacy_synthetic_name': 'PAYSE 합성 gamma',
        'legacy_display_name': '데모 3',
        'initial_case': 'gamma-month-end',
    },
))

DISABLED_CODE_VERIFIER = 'DISABLED:auth-design-pending'
SEED_USER_KEYS = frozenset({
    'userId', 'name', 'phone', 'codeVerifier', 'createdAt', 'initialCase',
})


def validate_stored_identity(name: str, phone: str) -> None:
    """2026-10-22: Reject noncanonical stored identities without changing values."""
    if not isinstance(name, str) or re.fullmatch(r'[가-힣A-Za-z]{2,20}', name) is None:
        raise ValueError('invalid stored identity name')
    if not isinstance(phone, str) or re.fullmatch(r'010[0-9]{8}', phone) is None:
        raise ValueError('invalid stored identity phone')


def validate_server_seeds(seeds: dict, snapshots: dict[str, dict]) -> None:
    """2026-10-22: Validate private seed meaning and owner links, even after rehashing.

    snapshots is keyed by catalog case ID. Error messages omit submitted values.
    The known fixture set is not a permanent limit on the number of PAYSE users.
    """
    if not isinstance(seeds, dict) or set(seeds) != {'warning', 'users'}:
        raise ValueError('invalid server seed root')
    if not isinstance(seeds['warning'], str) or not seeds['warning'].strip():
        raise ValueError('server seed warning missing')
    users = seeds['users']
    if not isinstance(users, list) or not users:
        raise ValueError('server seed users missing')

    known = {row['user_id']: row for row in IDENTITY_USERS}
    seen_ids = set()
    seen_credentials = set()
    for user in users:
        if not isinstance(user, dict) or set(user) != SEED_USER_KEYS:
            raise ValueError('server seed user keys differ from the identity contract')
        user_id = user['userId']
        if not isinstance(user_id, str):
            raise ValueError('invalid server seed user ID')
        try:
            canonical_id = str(UUID(user_id))
        except ValueError as error:
            raise ValueError('invalid server seed user ID') from error
        if canonical_id != user_id or user_id not in known or user_id in seen_ids:
            raise ValueError('unknown or duplicate server seed user ID')
        validate_stored_identity(user['name'], user['phone'])
        credentials = (user['name'], user['phone'])
        if credentials in seen_credentials:
            raise ValueError('duplicate server seed credentials')
        expected = known[user_id]
        if (user['name'], user['phone'], user['initialCase']) != (
            expected['name'], expected['phone'], expected['initial_case']
        ):
            raise ValueError('server seed identity mapping mismatch')
        if user['codeVerifier'] != DISABLED_CODE_VERIFIER:
            raise ValueError('credential provisioning is not part of fixture generation')
        try:
            created = datetime.fromisoformat(user['createdAt'])
        except (TypeError, ValueError) as error:
            raise ValueError('invalid server seed creation timestamp') from error
        if created.utcoffset() is None:
            raise ValueError('server seed timestamp requires an offset')
        initial = snapshots.get(user['initialCase'])
        if initial is None or initial.get('userId') != user_id:
            raise ValueError('server seed initial case owner mismatch')
        seen_ids.add(user_id)
        seen_credentials.add(credentials)

    if seen_ids != set(known) or any(s.get('userId') not in seen_ids for s in snapshots.values()):
        raise ValueError('server seeds and financial snapshot owners differ')
