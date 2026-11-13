"""Inert decision evaluator over trusted synthetic fixture inputs.

No IO, signature verification, adapter implementation, or financial effects.
The caller represents an internal verifier in this prototype.
"""
from dataclasses import asdict, dataclass
from hashlib import sha256
import json


@dataclass(frozen=True)
class Source:
    identity: str
    debtor: str
    creditor: str
    currency: str
    amount: int
    original_event: str
    original_hash: str
    latest_event: str
    latest_hash: str
    revision: int
    original_core: str
    latest_core: str


@dataclass(frozen=True)
class Terms:
    chapter: str
    reservation_event: str
    reservation_hash: str
    activation_event: str
    activation_hash: str
    intent: str
    parties: tuple[str, str]
    sources: tuple[Source, ...]
    release_minor: tuple[int, ...]
    release_instrument: str
    jurisdiction: str

    def commitment(self) -> str:
        value = ["bizkit.discharge-decision.simulation.v1", asdict(self)]
        encoded = json.dumps(value, sort_keys=True, separators=(",", ":"))
        return sha256(encoded.encode()).hexdigest()


@dataclass(frozen=True)
class Evidence:
    reference: str
    kind: str
    commitment: str
    subject: str
    issuer: str
    agent: str
    key: str
    epoch: int
    valid_from: int
    expires: int
    permits: bool = True


@dataclass(frozen=True)
class Snapshot:
    now: int
    version: int
    reserved_terms: Terms
    current_sources: tuple[Source, ...]
    owners: tuple[str, ...]
    authority_epochs: tuple[tuple[str, int], ...]
    keys: tuple[str, str]
    allowed_issuers: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class Decision:
    outcome: str
    commitment: str
    snapshot_version: int
    evaluated_at: int
    evidence_refs: tuple[str, ...]


def evaluate(terms: Terms, snapshot: Snapshot, evidence: tuple[Evidence, ...]) -> Decision:
    commitment = terms.commitment()
    refs = tuple(sorted(item.reference for item in evidence))

    def decision(outcome: str) -> Decision:
        return Decision(outcome, commitment, snapshot.version, snapshot.now, refs)

    if terms != snapshot.reserved_terms or terms.sources != snapshot.current_sources:
        return decision("source_or_reservation_mismatch")
    if snapshot.owners != (terms.intent,) * len(terms.sources):
        return decision("reservation_conflict")

    a, b = terms.parties
    sources = terms.sources
    ids = tuple(row.identity for row in sources)
    if (
        not 2 <= len(sources) <= 256
        or ids != tuple(sorted(set(ids)))
        or a == b
        or len({row.currency for row in sources}) != 1
        or {(row.debtor, row.creditor) for row in sources} != {(a, b), (b, a)}
        or len(terms.release_minor) != len(sources)
    ):
        return decision("unsupported_terms")

    released = {a: 0, b: 0}
    outstanding = {a: 0, b: 0}
    for row, amount in zip(sources, terms.release_minor):
        if (
            row.revision != 0
            or row.original_event != row.latest_event
            or row.original_hash != row.latest_hash
            or row.original_core != row.latest_core
            or not 0 <= amount <= row.amount < 2**63
            or row.amount == 0
        ):
            return decision("unsupported_terms")
        released[row.debtor] += amount
        outstanding[row.debtor] += row.amount
    if max(outstanding.values()) >= 2**63 or set(released.values()) != {min(outstanding.values())}:
        return decision("unsupported_terms")

    expected = {
        ("grant", a), ("grant", b), ("consent", a), ("consent", b),
        ("release", terms.release_instrument), ("policy", terms.jurisdiction),
    } | {("performance", row.identity) for row in sources}
    indexed = {(item.kind, item.subject): item for item in evidence}
    if len(indexed) != len(evidence) or set(indexed) != expected or len(set(refs)) != len(refs):
        return decision("missing_or_duplicate_evidence")

    epochs = dict(snapshot.authority_epochs)
    issuers = dict(snapshot.allowed_issuers)
    for item in evidence:
        if item.commitment != commitment:
            return decision("evidence_scope_mismatch")
        if not item.valid_from <= snapshot.now < item.expires:
            return decision("evidence_outside_validity")
        if not item.permits or epochs.get(item.issuer) != item.epoch:
            return decision("authority_denied_or_stale")
        if item.kind != "consent" and issuers.get(item.kind) != item.issuer:
            return decision("issuer_mismatch")

    agents = []
    for principal, key in zip(terms.parties, snapshot.keys):
        grant = indexed["grant", principal]
        consent = indexed["consent", principal]
        if (
            not grant.agent
            or consent.issuer != principal
            or (grant.agent, grant.key) != (consent.agent, consent.key)
            or consent.key != key
        ):
            return decision("consent_or_agency_mismatch")
        agents.append(grant.agent)
    if len(set(agents)) != 2 or len(snapshot.keys) != 2 or len(set(snapshot.keys)) != 2:
        return decision("consent_not_independent")
    return decision("validated_inert")
