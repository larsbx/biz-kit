"""Concrete wire projection; runtime decisions reuse the existing Python kernel.

The separate Lean program implements the row arithmetic independently. Finite
cross-language comparisons supplement, but do not replace, its representation
theorems. This module does not authenticate a checker or implement a database.
"""
from __future__ import annotations

from copy import deepcopy

from .common import CORE  # establishes the frozen core import path
from reference import codec
from reference.kernel import (Accept, Binding, Candidate, RewardConfig, RewardPhase,
                              RewardState, reject_reward, reward_step)

BINDING_FIELDS = ("contributor", "library", "engine", "source_revision",
                  "source_snapshot_sha256", "target", "artifact_sha256",
                  "environment_sha256", "policy_sha256", "core_revision",
                  "core_source_sha256", "generation")


def text_nat(value: str) -> int:
    number = 0
    for byte in reversed(value.encode("utf-8")):
        number = byte + 1 + 257 * number
    return number


def tuple_nat(values: list[str]) -> int:
    digits = []
    for value in values:
        digits.extend(value.encode("utf-8"))
        digits.append(256)
    number = 0
    for digit in reversed(digits):
        number = digit + 1 + 258 * number
    return number


def project_binding(binding):
    return Binding(text_nat(binding["target"]),
                   tuple_nat([str(binding[field]) for field in BINDING_FIELDS]),
                   text_nat(binding["environment_sha256"]), text_nat(binding["policy_sha256"]))


def candidate(binding):
    return Candidate(text_nat(binding["contributor"]), binding["generation"],
                     project_binding(binding), text_nat(binding["artifact_sha256"]), 0, 1)


def reward_config(config):
    worker = text_nat(config["expected"]["contributor"])
    return RewardConfig(project_binding(config["expected"]), config["reward"], worker, worker + 1)


def reward_state(state):
    binding = state["binding"]
    return RewardState(0, binding["generation"], text_nat(binding["contributor"]), 1,
                       RewardPhase(state["phase"]), candidate(binding), state["payouts"],
                       state["funder"], state["escrow"], state["balance_a"], state["balance_b"])


def project(state):
    c = codec.encode(candidate(state["binding"]))
    return {"adapter": {"reward": codec.encode(reward_state(state)), "version": state["version"],
                        "verifierEnabled": state["verifier_enabled"],
                        "verifierEpoch": state["authority_epoch"],
                        "settlement": c if state["settlement"] else None},
            "refund": None if state["refund_amount"] is None else
            {"candidate": c, "amount": state["refund_amount"]}}


def ready(wire):
    cfg, s, who, p = (wire[key] for key in ("config", "state", "identity", "prepared"))
    return (who["authenticated"] and who["principal"] == cfg["verifier"] and
            s["verifier_enabled"] and p["authority_epoch"] == s["authority_epoch"] and
            s["requester_enabled"] and who["requester"] == s["binding"]["contributor"] and
            p["requester_epoch"] == s["requester_epoch"] and p["checked"] and
            p["profile"] == cfg["profile"] and p["version"] == s["version"] and
            p["binding"] == s["binding"] == cfg["expected"] and
            s["phase"] == "submitted" and s["payouts"] == 0 and
            not s["settlement"] and s["refund_amount"] is None and
            s["escrow"] == cfg["reward"] and cfg["reward"] > 0)


def decide(wire):
    allowed = ready(wire)
    s = deepcopy(wire["state"])
    before = reward_state(s)
    result = before
    core_result = project(s)
    if allowed and wire["verdict"] != "inconclusive":
        cfg = reward_config(wire["config"])
        c = candidate(wire["prepared"]["binding"])
        if wire["verdict"] == "accepted":
            result = reward_step(cfg, before, Accept(True, c))
        elif wire["verdict"] == "rejected":
            result = reject_reward(cfg, before, c)
        else:
            raise ValueError("invalid verdict")
        if result != before:
            s.update(phase=result.phase.value, version=s["version"] + 1,
                     payouts=result.payouts, funder=result.funder, escrow=result.escrow,
                     balance_a=result.balanceA, balance_b=result.balanceB,
                     settlement=wire["verdict"] == "accepted",
                     refund_amount=cfg.reward if wire["verdict"] == "rejected" else None)
            core_result["adapter"].update(reward=codec.encode(result), version=s["version"],
                                           settlement=codec.encode(c) if s["settlement"] else None)
            if wire["verdict"] == "rejected":
                core_result["refund"] = {"candidate": codec.encode(c), "amount": cfg.reward}
    return {"ready": allowed, "state": s, "projected": project(s), "core_result": core_result}


def initial(binding, authority_epoch, requester_epoch):
    return {"binding": deepcopy(binding), "phase": "submitted", "version": 0,
            "verifier_enabled": True, "authority_epoch": authority_epoch,
            "requester_enabled": True, "requester_epoch": requester_epoch,
            "payouts": 0, "funder": 0, "escrow": 1, "balance_a": 0, "balance_b": 0,
            "settlement": False, "refund_amount": None}
