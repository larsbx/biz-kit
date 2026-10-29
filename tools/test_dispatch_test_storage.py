"""Actual-service negative controls, after migrations and both EventStore schemas."""
import os
from pathlib import Path
import subprocess
import sys
import unittest
from urllib.parse import urlsplit, urlunsplit

SCRIPT = Path(__file__).with_name('check_dispatch_test_storage.py')


class StorageReadiness(unittest.TestCase):
    def run_check(self, **overrides):
        return subprocess.run(
            [sys.executable, str(SCRIPT)], env={**os.environ, **overrides},
            capture_output=True, text=True, timeout=25,
        )

    def assert_denied(self, **overrides):
        result = self.run_check(**overrides)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn('postgres:postgres@', result.stderr)
        self.assertNotIn('wrong-password', result.stderr)

    def test_prepared_services(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_missing_dispatch_database(self):
        url = urlsplit(os.environ['DATABASE_URL'])
        self.assert_denied(DATABASE_URL=urlunsplit(url._replace(path='/dispatch_missing_ci_test')))

    def test_incorrect_dispatch_credentials(self):
        url = urlsplit(os.environ['DATABASE_URL'])
        authority = f'{url.username}:wrong-password@{url.hostname}:{url.port or 5432}'
        self.assert_denied(DATABASE_URL=urlunsplit(url._replace(netloc=authority)))

    def test_unavailable_signed_history(self):
        self.assert_denied(EVENTSTORE_HOST='eventstore-unavailable.invalid')

    def test_incorrect_signed_history_credentials(self):
        self.assert_denied(EVENTSTORE_PASSWORD='wrong-password')

    def test_refuses_non_test_environment(self):
        self.assert_denied(MIX_ENV='prod')


if __name__ == '__main__':
    unittest.main()
