#!/usr/bin/env python3
"""Finite independent admission model, NOT execution/refinement of Elixir/SQL."""
from collections import deque
from dataclasses import dataclass, replace
import json

@dataclass(frozen=True)
class State:
    active: bool = True
    grant: int = 1
    version: int = 0
    receipts: frozenset = frozenset()
    queue: tuple | None = None
    session: bool = True


def process(s, *, ignore_authority=False, ignore_version=False, ignore_retry=False):
    if s.queue is None:
        return s
    qgrant, qversion, ident = s.queue
    allowed = ignore_authority or (s.active and s.session and qgrant == s.grant)
    commit = allowed and (ignore_retry or ident not in s.receipts) and (ignore_version or qversion == s.version)
    return replace(s, queue=None, version=s.version + int(commit),
                   receipts=s.receipts | ({ident} if commit else set()))


def successors(s):
    if s.queue is None:
        for ident in range(2):
            yield "queue", replace(s, queue=(s.grant, s.version, ident))
    else:
        yield "process", process(s)
    yield "revoke", replace(s, active=False)
    yield "expire", replace(s, session=False)
    if s.grant < 3:
        yield "renew", replace(s, active=True, grant=s.grant + 1)
    yield "restart", s  # Durable prefix is unchanged; not a SQL restart test.


def main():
    pending, seen, transitions = deque([State()]), {State()}, 0
    while pending:
        before = pending.popleft()
        for action, after in successors(before):
            transitions += 1
            assert after.version == len(after.receipts)
            assert after.version >= before.version
            if action == "process" and before.queue:
                grant, version, ident = before.queue
                if not before.active or not before.session or grant != before.grant:
                    assert after.version == before.version
                if ident in before.receipts or version != before.version:
                    assert after.version == before.version
            if after not in seen:
                seen.add(after)
                pending.append(after)
    revoked = State(active=False, queue=(1, 0, 0))
    expired = State(session=False, queue=(1, 0, 0))
    replaced = State(grant=2, queue=(1, 0, 0))
    for broken in (revoked, expired, replaced):
        assert process(broken).version == 0
        assert process(broken, ignore_authority=True).version == 1
    stale = State(version=1, receipts=frozenset({0}), queue=(1, 0, 1))
    assert process(stale).version == 1
    assert process(stale, ignore_version=True).version == 2
    retry = State(version=1, receipts=frozenset({0}), queue=(1, 1, 0))
    assert process(retry).version == 1
    assert process(retry, ignore_retry=True).version == 2
    print(json.dumps({"model": "independent finite admission abstraction", "states": len(seen),
        "transitions": transitions, "negative_controls_detected": 5,
        "elixir_sql_http_executed": False}, sort_keys=True))

if __name__ == "__main__":
    main()
