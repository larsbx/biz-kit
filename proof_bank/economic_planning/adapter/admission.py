"""Bounded, local admission example for a synthetic harbor scenario."""
from contextlib import closing, contextmanager
import hashlib
import hmac
import sqlite3

from . import wire
from .boundary import (
    FrozenSnapshot, HostIdentity, PlanningBoundary, PlanningError,
    SourceUnavailable, commitment,
)

SCOPE = "synthetic-harbor"
MODEL = "harbor-scenario-v1"
BUCKET = "20"
END = "23"
CONSTRAINT = "harbor-a/shared-cargo-space"
EFFECT = "harbor-a/bucket-20/jet-fuel-delivery"
SCHEMA = "biz-kit/economic-planning/synthetic-observation-v1"
# Provider owns the observation bytes. The host owns all registry meanings.
REGISTRY = {
    "harbor/capacity": ("port", "dispatch", "physicalQuantity", "cargo-space", "kg"),
    "fuel/primary": ("seller", "fuel", "moneyMinorUnits", "delivered-charge", "minor-unit"),
    "fuel/alternate": ("broker", "fuel", "moneyMinorUnits", "delivered-charge", "minor-unit"),
    "rates/indicator": ("research", "centralBank", "indicator", "policy-rate", "percent"),
}


def _encode(value):
    return wire.dumps(value).encode("utf-8")


def _signal(family, measure, subject, unit):
    fuel = measure == "moneyMinorUnits"
    capacity = measure == "physicalQuantity"
    return {
        "family": family, "measure": measure, "subject": subject, "unit": unit,
        "material": "jet-fuel" if fuel else "produce" if capacity else "",
        "grade": "Jet A-1" if fuel else "A" if capacity else "",
        "form": "liquid" if fuel else "packed" if capacity else "",
        "currency": "USD" if fuel else "", "location": "harbor-a",
        "instrument": "policy" if measure == "indicator" else "physical",
        "maturity": None,
    }


def observation_mac(key: bytes, payload: bytes) -> bytes:
    return hmac.digest(key, SCHEMA.encode("ascii") + b"\x00" + payload, "sha256")


class AdmissionStore:
    """Trusted local writer and replay host for a single SQLite database."""

    def __init__(self, path, provider_keys):
        self._path = path
        providers = {entry[0] for entry in REGISTRY.values()}
        if set(provider_keys) != providers or any(
            type(key) is not bytes or len(key) != 32 for key in provider_keys.values()
        ) or len(set(provider_keys.values())) != len(providers):
            raise ValueError("expected distinct 32-byte keys for the fixture providers")
        self._keys = dict(provider_keys)
        with closing(self._connect()) as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS revision (
                    source TEXT, revision TEXT, payload BLOB NOT NULL,
                    tag BLOB NOT NULL, received_at TEXT NOT NULL, PRIMARY KEY (source, revision)
                );
                CREATE TABLE IF NOT EXISTS snapshot (
                    epoch INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, host BLOB NOT NULL
                );
                CREATE TABLE IF NOT EXISTS read_grant (
                    epoch INTEGER REFERENCES snapshot, principal TEXT, scope TEXT,
                    source TEXT, revision TEXT,
                    FOREIGN KEY (source, revision) REFERENCES revision,
                    PRIMARY KEY (epoch, principal, scope, source, revision)
                );
            """)

    def _connect(self):
        db = sqlite3.connect(self._path, isolation_level=None)
        db.execute("PRAGMA foreign_keys = ON")
        db.execute("PRAGMA synchronous = FULL")
        return db

    @contextmanager
    def _transaction(self):
        with closing(self._connect()) as db, db:
            db.execute("BEGIN IMMEDIATE")
            yield db

    def _authenticate(self, payload, tag, received_at, issued_at):
        path = "provider observation"
        value = wire.obj(wire.loads(payload, max_bytes=4096), {
            "schema", "provider", "ref", "publishedAt", "effectiveFrom",
            "effectiveUntil", "value",
        }, path)
        if value["schema"] != SCHEMA:
            raise PlanningError("unsupported provider observation")
        ref = wire.source_ref(value["ref"], path + ".ref")
        policy = REGISTRY.get(ref["source"])
        if policy is None:
            raise PlanningError("unknown observation series")
        provider, family, measure, subject, unit = policy
        if (value["provider"] != provider or type(tag) is not bytes
                or not hmac.compare_digest(observation_mac(self._keys[provider], payload), tag)):
            raise PlanningError("provider authentication failed")
        published = wire.nat(value["publishedAt"], path + ".publishedAt")
        start = wire.nat(value["effectiveFrom"], path + ".effectiveFrom")
        end = wire.nat(value["effectiveUntil"], path + ".effectiveUntil")
        if not published <= received_at <= issued_at or start >= end:
            raise PlanningError("inconsistent observation times")
        if measure != "indicator" and (start, end) != (int(BUCKET), int(END)):
            raise PlanningError("observation does not match the registered bucket")
        quantity = value["value"]
        if measure == "indicator":
            if quantity is not None:
                wire.text(quantity, path + ".value")
            quantity = None
        else:
            wire.optional_nat(quantity, path + ".value")
        return {
            "ref": ref, "key": _signal(family, measure, subject, unit), "scope": SCOPE,
            "publishedAt": value["publishedAt"], "receivedAt": str(received_at),
            "effectiveFrom": value["effectiveFrom"], "effectiveUntil": value["effectiveUntil"],
            "origin": "synthetic", "quantity": quantity,
            "payloadDigest": hashlib.sha256(payload).hexdigest(),
        }

    def install(self, epoch, issued_at, observations, grants):
        """Install one complete host epoch. Grants replace the previous set.

        Observations contain exact provider bytes, tag and host receipt time.
        Grants are host-authored (principal, scope, source, revision) tuples.
        """
        if type(epoch) is not int or not 0 < epoch <= wire.MAX_NAT:
            raise PlanningError("invalid authorization epoch")
        issued = wire.nat(issued_at, "issuedAt")
        records = {}
        for payload, tag, received in observations:
            evidence = self._authenticate(
                payload, tag, wire.nat(received, "receivedAt"), issued,
            )
            source, _ = wire.ref_identity(evidence["ref"])
            if source in records:
                raise PlanningError("duplicate observation series")
            records[source] = (evidence, payload, tag)
        if records.keys() != REGISTRY.keys():
            raise PlanningError("incomplete observation batch")
        sources = [records[source][0] for source in sorted(records)]
        refs = {wire.ref_identity(item["ref"]) for item in sources}
        grant_rows = set()
        for principal, scope, source, revision in grants:
            identity = HostIdentity(principal, scope)
            ref = wire.source_ref({"source": source, "revision": revision}, "grant.ref")
            row = (identity.principal, identity.scope, *wire.ref_identity(ref))
            if scope != SCOPE or (source, revision) not in refs or row in grant_rows:
                raise PlanningError("inconsistent or duplicate grant")
            grant_rows.add(row)
            if len(grant_rows) > 128:
                raise PlanningError("too many fixture grants")
        ordered_grants = sorted(grant_rows)

        capacity = records["harbor/capacity"][0]
        host = {
            "schema": wire.SNAPSHOT_SCHEMA, "scope": SCOPE, "issuedAt": issued_at,
            "models": [MODEL], "operationalToken": "synthetic-inert",
            "sources": sources,
            "resources": [{
                "key": {"scope": SCOPE, "constraintId": CONSTRAINT, "bucket": BUCKET},
                "value": {"source": capacity["ref"], "signal": capacity["key"],
                          "capacity": capacity["quantity"]},
            }],
            "costComponents": [
                {"source": item["ref"], "components": [EFFECT]}
                for item in sources if item["key"]["measure"] == "moneyMinorUnits"
                and item["quantity"] is not None
            ],
        }
        name = commitment("biz-kit/economic-planning/synthetic-epoch-v1", _encode({
            "epoch": epoch, "host": host, "grants": [list(row) for row in ordered_grants],
        }))
        host["snapshot"] = name
        raw = _encode(host)
        FrozenSnapshot(raw)

        with self._transaction() as db:
            previous = db.execute(
                "SELECT epoch, host FROM snapshot ORDER BY epoch DESC LIMIT 1"
            ).fetchone()
            if previous and (epoch <= previous[0]
                             or issued < wire.decode_snapshot(previous[1])["issuedAt"]):
                raise PlanningError("stale authorization epoch or issue time")
            for evidence, payload, tag in records.values():
                ref = wire.ref_identity(evidence["ref"])
                existing = db.execute(
                    "SELECT payload, tag, received_at FROM revision WHERE source = ? AND revision = ?", ref,
                ).fetchone()
                record = (payload, tag, evidence["receivedAt"])
                if existing is None:
                    db.execute("INSERT INTO revision VALUES (?, ?, ?, ?, ?)", (*ref, *record))
                elif existing != record:
                    raise PlanningError("provider revision is already bound to different evidence")
            db.execute("INSERT INTO snapshot VALUES (?, ?, ?)", (epoch, name, raw))
            db.executemany("INSERT INTO read_grant VALUES (?, ?, ?, ?, ?)",
                           [(epoch, *row) for row in ordered_grants])
        return name

    def plan(self, raw, identity):
        """Authorize and serialize against the current epoch under one lock."""
        request = wire.decode_request(raw)
        if request["actions"][-1]["claim"] != "scenario":
            raise PlanningError("the synthetic admission example accepts scenario claims only")
        with self._transaction() as db:
            current = db.execute(
                "SELECT epoch, name, host FROM snapshot ORDER BY epoch DESC LIMIT 1"
            ).fetchone()
            if current is None or request["snapshot"] != current[1]:
                raise SourceUnavailable("requested source is unavailable")
            epoch, name, host = current

            def authorize(member, snapshot, ref):
                return snapshot == name and db.execute(
                    """SELECT 1 FROM read_grant WHERE epoch = ? AND principal = ?
                       AND scope = ? AND source = ? AND revision = ?""",
                    (epoch, member.principal, member.scope, *wire.ref_identity(ref)),
                ).fetchone() is not None

            result = PlanningBoundary(FrozenSnapshot(host), authorize).plan(raw, identity)
        return result
