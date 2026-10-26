"""2026-10-23: Read reviewed Korean bank reference data; no network or connection support inference."""
from __future__ import annotations

from datetime import date
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

REFERENCE = Path(__file__).resolve().parent / 'kr-banks.json'
CATEGORIES = {'commercial', 'regional', 'internet', 'special'}


def validate_bank_directory(directory: dict) -> None:
    """2026-10-23: Check reference provenance and unique internal identities before generation/export."""
    if not isinstance(directory, dict) or set(directory) != {
        'directoryVersion', 'countryCode', 'verifiedOn', 'scope', 'sources', 'banks'
    }:
        raise ValueError('Invalid bank directory root')
    if (directory['countryCode'] != 'KR'
            or directory['scope'] != 'domestic_commercial_regional_internet_special'
            or not re.fullmatch(r'PAYSE-KR-BANKS-[0-9]{8}', directory['directoryVersion'])):
        raise ValueError('Invalid bank directory scope/version')
    verified = date.fromisoformat(directory['verifiedOn'])
    if directory['verifiedOn'] != verified.isoformat():
        raise ValueError('Invalid bank verification date')
    sources = directory['sources']
    if not isinstance(sources, dict) or not sources:
        raise ValueError('Bank directory sources required')
    for key, value in sources.items():
        if not isinstance(key, str) or not key or not isinstance(value, str):
            raise ValueError('Invalid source reference')
        url = urlsplit(value)
        if url.scheme != 'https' or not url.hostname or url.username or url.password or any(c.isspace() for c in value):
            raise ValueError('Invalid public source URL')
    banks = directory['banks']
    if not isinstance(banks, list) or not banks:
        raise ValueError('Bank directory must not be empty')
    seen = set()
    for bank in banks:
        if not isinstance(bank, dict) or set(bank) != {'code', 'kind', 'name', 'category', 'sourceRefs'}:
            raise ValueError('Invalid bank row')
        if not isinstance(bank['code'], str) or not re.fullmatch(r'bank\.[a-z][a-z0-9_]*', bank['code']) or bank['code'] in seen:
            raise ValueError('Invalid/duplicate internal bank code')
        if bank['kind'] != 'bank' or bank['category'] not in CATEGORIES:
            raise ValueError('Invalid bank kind/category')
        if not isinstance(bank['name'], str) or not bank['name'].strip() or len(bank['name']) > 200:
            raise ValueError('Invalid bank name')
        refs = bank['sourceRefs']
        if not isinstance(refs, list) or not refs or not all(isinstance(ref, str) and ref in sources for ref in refs) or len(refs) != len(set(refs)):
            raise ValueError('Missing/invalid bank evidence')
        seen.add(bank['code'])


def load_bank_directory(path: Path = REFERENCE) -> dict:
    """2026-10-23: Load a local reviewed snapshot for generate.py and SQL export validation."""
    directory = json.loads(path.read_text(encoding='utf-8'))
    validate_bank_directory(directory)
    return directory


def check_fixture_banks(snapshot: dict, directory: dict) -> None:
    """2026-10-23: Require fixture-supported banks to match the directory without adding accounts."""
    by_code = {bank['code']: bank for bank in directory['banks']}
    for bank in snapshot['institutions']:
        if bank['kind'] != 'bank':
            continue
        reference = by_code.get(bank['code'])
        if reference is None or reference['name'] != bank['name']:
            raise ValueError('Fixture bank differs from directory')
