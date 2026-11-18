"""Offline PostgreSQL receipt experiment. No server, queue or effect interface.

Only explicit synthetic TEST pins are understood. PostgreSQL retains operational
evidence, not Halaqa authority. Never deploy this fixture adapter as live ingress.
"""
from __future__ import annotations

import base64
import json
from pathlib import Path
import re
import subprocess

from check_halaqa_federation_draft import load_snapshot

ROOT = Path(__file__).resolve().parents[1]


def sql_bytes(data: bytes) -> str:
    """Only hex digits enter SQL literals; values never become SQL syntax."""
    return "decode('" + data.hex() + "','hex')"


def sql_text(text: str) -> str:
    return "convert_from(" + sql_bytes(text.encode("utf-8")) + ",'UTF8')"


class ReceiptDraft:
    def __init__(self, database: str, environment: dict | None = None):
        # psql uses the caller's test-only libpq environment for host/auth.
        # Database is a separate argv option value, never shell/SQL text.
        if re.fullmatch(r"halaqa_receipt_test_[a-z0-9_]{1,43}", database) is None:
            raise ValueError("a disposable halaqa_receipt_test_ database is required")
        self.database = database
        self.environment = environment
        self.pin, _, self.unsigned, self.signed = load_snapshot(ROOT)

    def query(self, sql: str) -> dict:
        result = subprocess.run(
            ["psql", "-X", "-qAt", "--no-password", "--set=ON_ERROR_STOP=1",
             "--dbname", self.database],
            input=("BEGIN ISOLATION LEVEL READ COMMITTED;\n"
                   "SET LOCAL synchronous_commit = on;\n"
                   "SET LOCAL statement_timeout = '5s';\n"
                   "SET LOCAL ROLE halaqa_receipt_test_client;\n"
                   + sql + ";\nCOMMIT;\n"),
            text=True, capture_output=True, timeout=10, check=True, env=self.environment,
        )
        # Check return code first: SELECT output preceding a failed COMMIT is
        # never exposed as a receipt. A disconnect has an unknown outcome.
        return json.loads(result.stdout)

    def receive(self, wire: bytes, test_policy: dict) -> dict:
        self.signed.verify(wire, test_policy)
        # Parse only after the pinned strict verifier has accepted these bytes.
        candidate = base64.b64decode(json.loads(wire)["candidate"], validate=True)
        policy_sql = sql_text(json.dumps(test_policy, sort_keys=True)) + "::jsonb"
        return self.query("SELECT halaqa_receipt_draft.record_candidate("
                          + sql_bytes(candidate) + "," + sql_bytes(wire)
                          + "," + policy_sql + ")")

    def status(self, recipient: str, sender: str, message_id: str, digest: bytes) -> dict:
        """Local fixture lookup, never an unauthenticated network status API.

        Does not re-admit or execute anything, so retained results remain
        queryable after the original signature expires or its TEST pin changes.
        """
        args = [sql_text(x) for x in (recipient, sender, message_id)] + [sql_bytes(digest)]
        return self.query("SELECT halaqa_receipt_draft.lookup_receipt(" + ",".join(args) + ")")
