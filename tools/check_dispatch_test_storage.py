"""Read-only readiness check for Dispatch CI databases; never grants authority."""
import os
import subprocess
import sys
from urllib.parse import unquote, urlsplit


def query(env, sql):
    result = subprocess.run(
        ['psql', '-X', '-w', '-A', '-t', '-v', 'ON_ERROR_STOP=1', '-c', sql],
        env={**env, 'PGCONNECT_TIMEOUT': '5'},
        capture_output=True, text=True, timeout=10,
    )
    return result.returncode == 0 and result.stdout.strip() == 't'


def check():
    if os.environ.get('MIX_ENV') != 'test':
        raise ValueError('MIX_ENV=test is required')
    url = urlsplit(os.environ['DATABASE_URL'])
    database = unquote(url.path.removeprefix('/'))
    if url.scheme not in ('ecto', 'postgres', 'postgresql') or not database.endswith('_test'):
        raise ValueError('an explicit test DATABASE_URL is required')
    dispatch = {
        **os.environ,
        'PGHOST': url.hostname or 'localhost',
        'PGPORT': str(url.port or 5432),
        'PGUSER': unquote(url.username or ''),
        'PGPASSWORD': unquote(url.password or ''),
        'PGDATABASE': database,
    }
    if not query(dispatch, "SELECT to_regclass('public.devices') IS NOT NULL"):
        raise ValueError('Dispatch test database unavailable or migrations missing')
    ledger = {
        **os.environ,
        'PGHOST': os.environ.get('EVENTSTORE_HOST', 'localhost'),
        'PGPORT': '5432',
        'PGUSER': os.environ.get('EVENTSTORE_USERNAME', 'postgres'),
        'PGPASSWORD': os.environ.get('EVENTSTORE_PASSWORD', ''),
        'PGDATABASE': 'coop_substrate_eventstore_test',
    }
    if not query(ledger, """SELECT
        to_regclass('public.events') IS NOT NULL AND
        to_regclass('public.streams') IS NOT NULL AND
        to_regclass('records.events') IS NOT NULL AND
        to_regclass('records.streams') IS NOT NULL"""):
        raise ValueError('signed EventStore/Records test database unavailable or uninitialized')


if __name__ == '__main__':
    try:
        check()
    except (KeyError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        # Never echo a database URI, password or driver stderr.
        print('FAIL: Dispatch CI storage readiness: ' + (
            str(error) if isinstance(error, ValueError) else type(error).__name__
        ), file=sys.stderr)
        sys.exit(1)
    print('PASS: Dispatch and signed EventStore/Records test storage ready')
