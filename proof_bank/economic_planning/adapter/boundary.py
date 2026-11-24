"""Host-scoped, read-only preparation and atomic offline replay publication.

Authentication and grant epochs are supplied by a trusted host. This module
does not authenticate a principal, connect a provider, or mutate business state.
"""
from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass
import hashlib
from typing import Callable

from . import reducer, wire


class PlanningError(ValueError):
    """A request cannot be released as a planning certificate."""


class SourceUnavailable(PlanningError):
    """A requested source is absent or not currently readable."""


class TraceRejected(PlanningError):
    def __init__(self, index: int):
        self.index = index
        super().__init__(f"planning action {index} was rejected")


@dataclass(frozen=True)
class HostIdentity:
    """Host-authenticated identity assertion, never decoded from a request."""

    principal: str
    scope: str

    def __post_init__(self):
        wire.text(self.principal, "host.principal")
        wire.text(self.scope, "host.scope")


def commitment(domain: str, raw: bytes) -> str:
    return hashlib.sha256(domain.encode("ascii") + b"\x00" + raw).hexdigest()


@dataclass(frozen=True, init=False)
class FrozenSnapshot:
    """Immutable bytes, rather than shallowly frozen mutable dictionaries."""

    _canonical: bytes

    def __init__(self, raw: bytes):
        value = wire.decode_snapshot(raw)
        object.__setattr__(self, "_canonical", wire.dumps(value).encode("utf-8"))

    @property
    def digest(self) -> str:
        return commitment("biz-kit/economic-planning/snapshot-v1", self._canonical)

    def _materialize(self) -> dict:
        # Each request receives its own value graph, never aliases to a previous
        # replay or to a caller-owned source object.
        return wire.decode_snapshot(self._canonical)


Authorizer = Callable[[HostIdentity, str, dict], bool]


class PlanningBoundary:
    """Offline request boundary; no direct state/certificate admission API."""

    def __init__(self, snapshot: FrozenSnapshot, authorize: Authorizer):
        if type(snapshot) is not FrozenSnapshot or not callable(authorize):
            raise TypeError("a validated host snapshot and read authorizer are required")
        self._snapshot = snapshot
        self._authorize = authorize

    def _check_read(self, identity: HostIdentity, snapshot: str, ref: dict) -> None:
        try:
            allowed = self._authorize(identity, snapshot, deepcopy(ref)) is True
        except Exception:
            allowed = False
        if not allowed:
            raise SourceUnavailable("requested source is unavailable")

    def plan(self, raw: bytes, identity: HostIdentity) -> bytes:
        """Return one serialized certificate only after the entire trace passes.

        `identity` must be supplied by the trusted host outside the request body.
        No output or partial certificate is returned on rejection.
        """
        if type(identity) is not HostIdentity:
            raise TypeError("host identity assertion required")
        request = wire.decode_request(raw)
        frozen = self._snapshot
        host = frozen._materialize()
        snapshot_digest = frozen.digest
        if identity.scope != host["scope"]:
            raise SourceUnavailable("requested source is unavailable")
        if request["snapshot"] != host["snapshot"]:
            raise PlanningError("request does not bind this frozen snapshot")
        if request["model"] not in host["models"]:
            raise PlanningError("model identifier is not allowed by this host snapshot")

        manifest = {k: request[k] for k in ("snapshot", "model", "scenario", "seed",
                                           "horizonStart", "horizonEnd", "currency")}
        manifest.update(scope=host["scope"], issuedAt=host["issuedAt"])
        source_table = {wire.ref_identity(e["ref"]): e for e in host["sources"]}
        sources = []
        readable = []
        seen = set()
        actions = []
        for action in request["actions"]:
            if action["kind"] != "evidence":
                actions.append(deepcopy(action))
                continue
            ref = action["expectedRef"]
            key = wire.ref_identity(ref)
            if key not in seen:
                # Authorization precedes record lookup. Absence and denial use
                # the same caller-visible error and reveal no private record.
                self._check_read(identity, host["snapshot"], ref)
                source = source_table.get(key)
                if source is None:
                    raise SourceUnavailable("requested source is unavailable")
                seen.add(key)
                sources.append(deepcopy(source))
                readable.append(deepcopy(ref))
            source = source_table[key]
            actions.append({"kind": "evidence", "request": {
                "expectedRef": deepcopy(ref), "expectedKey": deepcopy(action["expectedKey"]),
                "evidence": deepcopy(source)}})

        bundle = {"manifest": manifest, "sources": sources, "readable": readable,
                  "resources": deepcopy(host["resources"]),
                  "operationalToken": host["operationalToken"], "actions": actions}
        replay_bytes = wire.dumps(bundle).encode("utf-8")
        if len(replay_bytes) > wire.BUNDLE_BYTES:
            raise PlanningError("prepared replay exceeds its byte limit")
        result = reducer.replay_final(bundle)
        if not result["accepted"]:
            raise TraceRejected(result["rejectedAt"])
        cost_bindings = {wire.ref_identity(entry["source"]): entry["components"]
                         for entry in host["costComponents"]}
        # Check only after source-authorized replay succeeds, so guessing a
        # private quote's components cannot probe the host catalog. No replay
        # state or certificate has been released at this point.
        for line in result["state"]["costs"]:
            if cost_bindings.get(wire.ref_identity(line["source"])) != line["components"]:
                raise PlanningError("cost components do not match the host quote binding")
        publications = result["state"]["publications"]
        if len(publications) != 1:
            raise PlanningError("replay did not produce exactly one final certificate")
        # Revalidate all admitted sources immediately before release. The host
        # still owns atomic grant-epoch consistency across this callback boundary.
        for ref in readable:
            self._check_read(identity, host["snapshot"], ref)
        envelope = {
            "schema": "biz-kit/economic-planning/result-v1",
            "certificate": publications[0],
            "requestDigest": commitment("biz-kit/economic-planning/request-v1", raw),
            "snapshotDigest": snapshot_digest,
            "replayDigest": commitment("biz-kit/economic-planning/replay-v1", replay_bytes),
        }
        return wire.dumps(envelope).encode("utf-8")
