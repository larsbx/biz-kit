"""Synthetic contract oracle. No platform imports, persistence, or real data."""

import hashlib
import json
import unittest
from dataclasses import dataclass, replace

RUST = (2, "g3-is-source-metadata-rust-v2")
PIN = "synthetic-approved-pin"


class Refusal(Exception):
    pass


class Crash(Exception):
    pass


@dataclass(frozen=True)
class Session:
    scope: tuple
    handle: str
    pin: str = PIN
    schema: int = RUST[0]
    version: str = RUST[1]
    learner: bytes = b"fictional prompt"
    teacher: bytes = b"synthetic answer"
    manifest: bytes = b"synthetic private nonce and classifications"

    def binding(self):
        metadata = json.dumps(
            [self.scope, self.handle, self.pin, self.schema, self.version],
            separators=(",", ":"),
        ).encode()
        return tuple(
            hashlib.sha256(part).digest()
            for part in (metadata, self.learner, self.teacher, self.manifest)
        )


class Contract:
    """Separate fixture stores represent intent, custody, outcome and receipt."""

    def __init__(self):
        self.grants = set()
        self.intents = {}
        self.staged = {}
        self.outcomes = {}
        self.receipts = {}
        self.generated = 0

    def require(self, principal, scope, capability):
        if (principal, scope, capability) not in self.grants:
            raise Refusal("unavailable")

    def begin(self, scope, key="retry-key", pin=PIN, fail=None):
        principal = scope[-1]
        self.require(principal, scope, "learner")
        operation = (scope, key)
        if self.intents.setdefault(operation, pin) != pin:
            raise Refusal("conflict")
        if operation in self.outcomes and self.outcomes[operation] is None:
            raise Refusal("unavailable")
        if operation not in self.staged:
            self.generated += 1
            candidate = Session(scope, f"synthetic-handle-{self.generated}", pin)
            if fail == "before stage":
                raise Crash()
            self.staged[operation] = candidate
        candidate = self.staged[operation]
        if fail == "after stage":
            raise Crash()
        self.complete(operation, candidate)
        if fail == "after append":
            raise Crash()
        self.recover(operation)
        if fail == "after receipt":
            raise Crash()
        return candidate.handle, self.read(scope[0], principal, candidate.handle)

    def complete(self, operation, candidate):
        scope, _ = operation
        self.require(scope[-1], scope, "learner")
        if operation in self.outcomes and self.outcomes[operation] is None:
            raise Refusal("unavailable")
        if self.staged.get(operation) != candidate:
            raise Refusal("integrity")
        self.outcomes.setdefault(operation, candidate.binding())

    def abort(self, operation):
        """Model a terminal abort accepted by the same gate as completion."""
        if operation not in self.intents or self.outcomes.setdefault(operation, None) is not None:
            raise Refusal("unavailable")
        self.staged.pop(operation, None)

    def recover(self, operation):
        """Project a completion into a receipt without returning private bytes."""
        outcome = self.outcomes.get(operation)
        if outcome is None:
            raise Refusal("unavailable")
        candidate = self.staged.get(operation)
        if candidate is None or outcome != candidate.binding():
            raise Refusal("integrity")
        self.receipts[(candidate.scope[0], candidate.handle)] = operation

    def read(self, tenant, principal, handle, teacher=False):
        operation = self.receipts.get((tenant, handle))
        if operation is None:
            raise Refusal("unavailable")
        scope, _ = operation
        self.require(principal, scope, "teacher-key" if teacher else "learner")
        if not teacher and principal != scope[-1]:
            raise Refusal("unavailable")
        saved = self.staged[operation]
        if type(saved.schema) is not int or not isinstance(saved.version, str):
            raise Refusal("malformed")
        if (saved.schema, saved.version) != RUST:
            raise Refusal("unsupported")
        if saved.pin != PIN or saved.binding() != self.outcomes[operation]:
            raise Refusal("integrity")
        return saved.teacher if teacher else saved.learner


class PracticeContractTests(unittest.TestCase):
    def setUp(self):
        self.model = Contract()
        self.scope = ("tenant-a", "class-a", "assignment-a", "learner-a")
        self.model.grants.add(("learner-a", self.scope, "learner"))

    def test_learner_cannot_read_key_or_manifest(self):
        handle, form = self.model.begin(self.scope)
        self.assertEqual(form, b"fictional prompt")
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.read("tenant-a", "learner-a", handle, teacher=True)
        self.model.grants.add(("teacher-a", self.scope, "teacher-key"))
        self.assertEqual(
            self.model.read("tenant-a", "teacher-a", handle, teacher=True),
            b"synthetic answer",
        )
        self.model.grants.remove(("teacher-a", self.scope, "teacher-key"))
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.read("tenant-a", "teacher-a", handle, teacher=True)

    def test_cross_tenant_and_non_owner_reads(self):
        handle, _ = self.model.begin(self.scope)
        for tenant, principal in (("tenant-b", "learner-a"), ("tenant-a", "other")):
            with self.subTest(tenant=tenant), self.assertRaisesRegex(Refusal, "unavailable"):
                self.model.read(tenant, principal, handle)

    def test_revoked_learner_cannot_resume_or_repeat_begin(self):
        handle, _ = self.model.begin(self.scope)
        self.model.grants.clear()
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.read("tenant-a", "learner-a", handle)
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.begin(self.scope)

    def test_repeated_begin_and_conflicting_body(self):
        self.assertEqual(self.model.begin(self.scope), self.model.begin(self.scope))
        self.assertEqual(self.model.generated, 1)
        with self.assertRaisesRegex(Refusal, "conflict"):
            self.model.begin(self.scope, pin="changed-pin")

    def test_crash_and_retry_publish_once(self):
        for phase in ("before stage", "after stage", "after append", "after receipt"):
            with self.subTest(phase=phase):
                model = Contract()
                model.grants.update(self.model.grants)
                with self.assertRaises(Crash):
                    model.begin(self.scope, fail=phase)
                if phase != "after receipt":
                    self.assertFalse(model.receipts)
                result = model.begin(self.scope)
                self.assertEqual(result, model.begin(self.scope))
                for store in (model.intents, model.staged, model.outcomes, model.receipts):
                    self.assertEqual(len(store), 1)
                self.assertEqual(model.generated, 2 if phase == "before stage" else 1)

    def test_abort_fences_late_completion_and_duplicate_begin(self):
        with self.assertRaises(Crash):
            self.model.begin(self.scope, fail="after stage")
        operation = (self.scope, "retry-key")
        stale_candidate = self.model.staged[operation]
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.recover(operation)
        self.model.abort(operation)
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.complete(operation, stale_candidate)
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.begin(self.scope)
        self.assertFalse(self.model.staged)
        self.assertFalse(self.model.receipts)
        self.assertEqual(self.model.generated, 1)

    def test_completion_fences_cleanup_and_recovery_preserves_revocation(self):
        with self.assertRaises(Crash):
            self.model.begin(self.scope, fail="after append")
        operation = (self.scope, "retry-key")
        handle = self.model.staged[operation].handle
        self.model.grants.clear()
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.abort(operation)
        self.assertIsNone(self.model.recover(operation))
        self.assertEqual(len(self.model.receipts), 1)
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.read("tenant-a", "learner-a", handle)
        with self.assertRaisesRegex(Refusal, "unavailable"):
            self.model.begin(self.scope)

    def test_recovery_refuses_missing_or_substituted_candidate(self):
        with self.assertRaises(Crash):
            self.model.begin(self.scope, fail="after append")
        operation = (self.scope, "retry-key")
        saved = self.model.staged.pop(operation)
        with self.assertRaisesRegex(Refusal, "integrity"):
            self.model.recover(operation)
        self.model.staged[operation] = replace(saved, teacher=b"substituted")
        with self.assertRaisesRegex(Refusal, "integrity"):
            self.model.recover(operation)
        self.assertFalse(self.model.receipts)

    def assert_saved_refusal(self, reason, **changes):
        handle, _ = self.model.begin(self.scope)
        operation = (self.scope, "retry-key")
        saved = self.model.staged[operation]
        self.model.staged[operation] = replace(saved, **changes)
        try:
            with self.assertRaisesRegex(Refusal, reason):
                self.model.read("tenant-a", "learner-a", handle)
        finally:
            self.model.staged[operation] = saved

    def test_malformed_metadata(self):
        self.assert_saved_refusal("malformed", schema="2")
        self.assert_saved_refusal("malformed", version=None)

    def test_tampered_saved_objects_and_source(self):
        for field in ("learner", "teacher", "manifest"):
            with self.subTest(field=field):
                self.assert_saved_refusal("integrity", **{field: b"altered"})
        self.assert_saved_refusal("integrity", pin="other-pin")

    def test_incompatible_versions(self):
        self.assert_saved_refusal("unsupported", schema=1, version="python-v1")
        self.assert_saved_refusal("unsupported", schema=3)
        self.assert_saved_refusal("unsupported", version="other-rust-v2")


if __name__ == "__main__":
    unittest.main()
