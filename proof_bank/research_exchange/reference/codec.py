"""Strict JSON boundary for the finite conformance harness.

Identifiers stand for abstract commitments in the formal model. This parser does
not implement cryptographic commitments or authenticate verifier approvals.
"""
from __future__ import annotations

import json
from typing import Any

from .kernel import (
    Accept, Binding, Cancel, Candidate, Lease, Reserve, ReservationPhase,
    ReservationState, RewardConfig, RewardPhase, RewardState, Settle, Start,
    Stop, Submit, Tick, reservation_step, reward_step,
)


class DecodeError(ValueError):
    """The request is outside the serialized model's declared input domain."""


def obj(value: Any, keys: tuple[str, ...]) -> dict:
    if type(value) is not dict:
        raise DecodeError("expected JSON object")
    if set(value) != set(keys):
        raise DecodeError(f"expected exactly {keys}, got {tuple(value)}")
    return value


def natural(value: Any) -> int:
    if type(value) is not int or value < 0:
        raise DecodeError("expected a nonnegative JSON integer")
    return value


def boolean(value: Any) -> bool:
    if type(value) is not bool:
        raise DecodeError("expected a JSON boolean")
    return value


def binding(value: Any) -> Binding:
    v = obj(value, ("target", "input", "environment", "policy"))
    return Binding(*(natural(v[k]) for k in ("target", "input", "environment", "policy")))


def candidate(value: Any) -> Candidate:
    v = obj(value, ("worker", "generation", "binding", "artifact", "submittedAt", "leaseExpires"))
    return Candidate(natural(v["worker"]), natural(v["generation"]), binding(v["binding"]),
                     natural(v["artifact"]), natural(v["submittedAt"]), natural(v["leaseExpires"]))


def reward_config(value: Any) -> RewardConfig:
    v = obj(value, ("expected", "reward", "workerA", "workerB"))
    return RewardConfig(binding(v["expected"]), natural(v["reward"]), natural(v["workerA"]),
                        natural(v["workerB"]))


def reward_state(value: Any) -> RewardState:
    keys = ("now", "generation", "owner", "expires", "phase", "candidate", "payouts",
            "funder", "escrow", "balanceA", "balanceB")
    v = obj(value, keys)
    try:
        phase = RewardPhase(v["phase"])
    except (ValueError, TypeError) as exc:
        raise DecodeError("unknown reward phase") from exc
    return RewardState(
        natural(v["now"]), natural(v["generation"]), natural(v["owner"]), natural(v["expires"]),
        phase, None if v["candidate"] is None else candidate(v["candidate"]),
        natural(v["payouts"]), natural(v["funder"]), natural(v["escrow"]),
        natural(v["balanceA"]), natural(v["balanceB"]),
    )


def reservation_state(value: Any) -> ReservationState:
    v = obj(value, ("phase", "available", "held", "spent"))
    try:
        phase = ReservationPhase(v["phase"])
    except (ValueError, TypeError) as exc:
        raise DecodeError("unknown reservation phase") from exc
    return ReservationState(phase, natural(v["available"]), natural(v["held"]), natural(v["spent"]))


def reward_action(value: Any):
    if type(value) is not dict or "type" not in value or type(value["type"]) is not str:
        raise DecodeError("expected action object with string type")
    name = value["type"]
    if name == "tick":
        v = obj(value, ("type", "delta"))
        return Tick(natural(v["delta"]))
    if name == "lease":
        v = obj(value, ("type", "worker", "deadline"))
        return Lease(natural(v["worker"]), natural(v["deadline"]))
    if name == "submit":
        v = obj(value, ("type", "worker", "generation", "binding", "artifact"))
        return Submit(natural(v["worker"]), natural(v["generation"]), binding(v["binding"]),
                      natural(v["artifact"]))
    if name == "accept":
        v = obj(value, ("type", "trusted", "evidence"))
        return Accept(boolean(v["trusted"]), candidate(v["evidence"]))
    raise DecodeError(f"unknown reward action: {name}")


def reservation_action(value: Any):
    if type(value) is not dict or "type" not in value or type(value["type"]) is not str:
        raise DecodeError("expected action object with string type")
    name = value["type"]
    if name == "reserve":
        v = obj(value, ("type", "cap"))
        return Reserve(natural(v["cap"]))
    if name == "start":
        obj(value, ("type",))
        return Start()
    if name == "cancel":
        obj(value, ("type",))
        return Cancel()
    if name == "stop":
        v = obj(value, ("type", "trusted"))
        return Stop(boolean(v["trusted"]))
    if name == "settle":
        v = obj(value, ("type", "cost"))
        return Settle(natural(v["cost"]))
    raise DecodeError(f"unknown reservation action: {name}")


def encode(value: Any) -> Any:
    """Project dataclasses to the exact Lean JSON protocol fields."""
    from dataclasses import fields, is_dataclass
    from enum import Enum
    if isinstance(value, Enum):
        return value.value
    if is_dataclass(value):
        return {field.name: encode(getattr(value, field.name)) for field in fields(value)}
    if type(value) in (list, tuple):
        return [encode(v) for v in value]
    if type(value) is dict:
        return {k: encode(v) for k, v in value.items()}
    return value


def loads(line: str) -> Any:
    def no_duplicates(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise DecodeError(f"duplicate JSON key: {key}")
            result[key] = value
        return result
    try:
        return json.loads(line, object_pairs_hook=no_duplicates,
                          parse_constant=lambda x: (_ for _ in ()).throw(DecodeError(f"invalid constant: {x}")))
    except json.JSONDecodeError as exc:
        raise DecodeError(str(exc)) from exc


def replay(request: Any) -> dict:
    if type(request) is not dict or request.get("kind") not in ("reward", "reservation"):
        raise DecodeError("unknown or missing kernel kind")
    kind = request["kind"]
    obj(request, ("kind", "config", "state", "actions") if kind == "reward" else
        ("kind", "state", "actions"))
    if type(request["actions"]) is not list:
        raise DecodeError("actions must be an array")
    if kind == "reward":
        config = reward_config(request["config"])
        state = reward_state(request["state"])
        actions = [reward_action(v) for v in request["actions"]]
        advance = lambda s, a: reward_step(config, s, a)
    else:
        state = reservation_state(request["state"])
        actions = [reservation_action(v) for v in request["actions"]]
        advance = reservation_step
    states = [encode(state)]
    for action in actions:
        state = advance(state, action)
        states.append(encode(state))
    return {"states": states}
