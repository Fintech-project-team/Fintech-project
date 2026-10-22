"""2026-10-22: Run rollback-only SQL suites after validating disposable fixture data.

The caller prepares the database and credentials. This runner never creates,
seeds, clears, or discovers databases and never calls a running PAYSE backend.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess

from test_context import build_context, context_sql

DATABASE = Path(__file__).resolve().parent
DEFAULT_FIXTURES = DATABASE.parent / 'fixtures' / 'generated'
SUITES = (
    'test_constraints.sql',
    'test_extremes.sql',
    'test_source_setting_integrity.sql',
    'test_identity_storage.sql',
)


def require_disposable_database(database: str) -> None:
    """2026-10-22: Reject remote hosts and non-test database names before connecting."""
    if not re.fullmatch(r'payse_fixture_[a-z0-9_]+', database):
        raise ValueError('Explicit disposable database name required')
    if os.environ.get('PGHOST') not in ('127.0.0.1', 'localhost'):
        raise ValueError('Explicit localhost PGHOST required')
    if os.environ.get('PGHOSTADDR') not in (None, '', '127.0.0.1', '::1') or os.environ.get('PGSERVICE'):
        raise ValueError('Remote host-address overrides and connection services are not allowed')


def run_sql(psql: str, database: str, sql: str, timeout_seconds: int = 60) -> str:
    """2026-10-22: Execute trusted test SQL in one bounded noninteractive connection."""
    require_disposable_database(database)
    if not 1 <= timeout_seconds <= 300:
        raise ValueError('Test timeout must be between 1 and 300 seconds')
    environment = {**os.environ, 'PGCLIENTENCODING': 'UTF8', 'PGCONNECT_TIMEOUT': '5'}
    result = subprocess.run(
        [str(psql), '-X', '--no-password', '-qAt', '-v', 'ON_ERROR_STOP=1', '-d', database],
        input=sql, text=True, encoding='utf-8', capture_output=True,
        timeout=timeout_seconds, env=environment,
    )
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def run_suites(psql: str, database: str, context: dict, timeout_seconds: int = 60) -> None:
    """2026-10-22: Load verified roles and a rollback-only suite in the same connection."""
    preparation = context_sql(context)
    for filename in SUITES:
        suite = (DATABASE / filename).read_text(encoding='utf-8')
        run_sql(psql, database, preparation + '\n' + suite, timeout_seconds)
        print(f'PASS: {filename}')


def main() -> None:
    """2026-10-22: Read local fixtures, verify roles, and execute all four SQL suites."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--database', required=True)
    parser.add_argument('--psql', default='psql')
    parser.add_argument('--fixtures', type=Path, default=DEFAULT_FIXTURES)
    parser.add_argument('--timeout-seconds', type=int, default=60)
    args = parser.parse_args()
    require_disposable_database(args.database)
    run_suites(args.psql, args.database, build_context(args.fixtures), args.timeout_seconds)


if __name__ == '__main__':
    main()
