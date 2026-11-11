from dataclasses import replace
import unittest

from decision import Evidence, Snapshot, Source, Terms, evaluate


class DecisionTests(unittest.TestCase):
    def setUp(self):
        left = Source("1", "A", "B", "DZD", 100, "x", "h1", "x", "h1", 0, "c1", "c1")
        right = Source("2", "B", "A", "DZD", 80, "y", "h2", "y", "h2", 0, "c2", "c2")
        self.terms = Terms("chapter", "event", "hash", "activation", "ahash", "intent",
                           ("A", "B"), (left, right), (80, 80), "contract", "scope")
        issuers = {"grant": "registry", "release": "legal", "performance": "trade",
                   "policy": "policy-owner"}
        self.snapshot = Snapshot(10, 1, self.terms, self.terms.sources, ("intent", "intent"),
                                 tuple((issuer, 1) for issuer in [*issuers.values(), "A", "B"]),
                                 ("ka", "kb"), tuple(issuers.items()))

        def evidence(kind, subject, issuer, agent="", key=""):
            return Evidence(kind + subject, kind, self.terms.commitment(), subject,
                            issuer, agent, key, 1, 1, 20)

        self.evidence = (
            evidence("grant", "A", "registry", "agent-a", "ka"),
            evidence("grant", "B", "registry", "agent-b", "kb"),
            evidence("consent", "A", "A", "agent-a", "ka"),
            evidence("consent", "B", "B", "agent-b", "kb"),
            evidence("release", "contract", "legal"),
            evidence("policy", "scope", "policy-owner"),
            evidence("performance", "1", "trade"),
            evidence("performance", "2", "trade"),
        )

    def result(self, terms=None, snapshot=None, evidence=None):
        return evaluate(self.terms if terms is None else terms,
                        self.snapshot if snapshot is None else snapshot,
                        self.evidence if evidence is None else evidence)

    def change_evidence(self, index, **changes):
        return (*self.evidence[:index], replace(self.evidence[index], **changes),
                *self.evidence[index + 1:])

    def test_exact_retry_is_pure_and_order_independent(self):
        first = self.result()
        self.assertEqual(first.outcome, "validated_inert")
        self.assertEqual(first, self.result(evidence=self.evidence[::-1]))
        self.assertEqual(first.snapshot_version, 1)

    def test_equal_amount_substitution_and_lineage_mutation(self):
        left, right = self.terms.sources
        for change in ({"identity": "0"}, {"original_hash": "other"},
                       {"latest_hash": "other"}, {"original_core": "other"},
                       {"latest_core": "other"}, {"revision": 1}):
            with self.subTest(change=change):
                snapshot = replace(self.snapshot, current_sources=(replace(left, **change), right))
                self.assertEqual(self.result(snapshot=snapshot).outcome,
                                 "source_or_reservation_mismatch")

    def test_mismatched_obligation_and_competing_reservation(self):
        self.assertEqual(self.result(evidence=self.change_evidence(6, subject="0")).outcome,
                         "missing_or_duplicate_evidence")
        self.assertEqual(self.result(snapshot=replace(self.snapshot, owners=("intent", "other"))).outcome,
                         "reservation_conflict")

    def test_stale_epoch_revoked_grant_and_expired_approval(self):
        for kind in ("registry", "policy-owner", "A", "trade", "legal"):
            with self.subTest(kind=kind):
                epochs = tuple((name, 2 if name == kind else epoch)
                               for name, epoch in self.snapshot.authority_epochs)
                stale = replace(self.snapshot, authority_epochs=epochs)
                self.assertEqual(self.result(snapshot=stale).outcome, "authority_denied_or_stale")
        self.assertEqual(self.result(evidence=self.change_evidence(0, permits=False)).outcome,
                         "authority_denied_or_stale")
        self.assertEqual(self.result(evidence=self.change_evidence(3, expires=10)).outcome,
                         "evidence_outside_validity")

    def test_interrupted_evidence_collection_cannot_validate(self):
        for count in range(len(self.evidence)):
            self.assertEqual(self.result(evidence=self.evidence[:count]).outcome,
                             "missing_or_duplicate_evidence")
        self.assertEqual(self.result().outcome, "validated_inert")

    def test_consents_bind_same_commitment_and_distinct_agents(self):
        self.assertEqual(self.result(evidence=self.change_evidence(2, commitment="other")).outcome,
                         "evidence_scope_mismatch")
        evidence = tuple(replace(item, agent="agent-a") if item.subject == "B" else item
                         for item in self.evidence)
        self.assertEqual(self.result(evidence=evidence).outcome, "consent_not_independent")
        self.assertEqual(self.result(snapshot=replace(self.snapshot, keys=("ka", "rotated"))).outcome,
                         "consent_or_agency_mismatch")

    def test_changed_release_terms_and_malformed_allocations(self):
        terms = replace(self.terms, release_instrument="other")
        self.assertEqual(self.result(terms=terms).outcome, "source_or_reservation_mismatch")
        terms = replace(self.terms, release_minor=(79, 80))
        snapshot = replace(self.snapshot, reserved_terms=terms)
        self.assertEqual(self.result(terms=terms, snapshot=snapshot).outcome, "unsupported_terms")


if __name__ == "__main__":
    unittest.main()
