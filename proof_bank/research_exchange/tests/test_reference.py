"""Adversarial checks of a local pure reference, not a network service."""
from copy import deepcopy
from dataclasses import FrozenInstanceError, replace
import json
from pathlib import Path
import unittest

from reference import codec
from reference.conformance import Case, canonical, compare_outputs, corpus
from reference.kernel import (
    Accept, Binding, Cancel, Candidate, Lease, Reserve, ReservationPhase,
    RewardConfig, RewardPhase, Settle, Start, Stop, Submit, Tick,
    initial_reservation, initial_reward, reservation_step, reward_step,
)


CONFIG = RewardConfig(Binding(1, 2, 3, 4), 5, 10, 20)


def leased():
    return reward_step(CONFIG, initial_reward(CONFIG, funder=7), Lease(10, 3))


def submitted():
    state = reward_step(CONFIG, leased(), Tick(1))
    return reward_step(CONFIG, state, Submit(10, 1, CONFIG.expected, 7))


class RewardTests(unittest.TestCase):
    def test_every_immutable_binding_component_is_required(self):
        state = leased()
        for field in ("target", "input", "environment", "policy"):
            with self.subTest(field=field):
                wrong = replace(CONFIG.expected, **{field: 99})
                self.assertIs(reward_step(CONFIG, state, Submit(10, 1, wrong, 7)), state)

    def test_deadline_is_exclusive_and_reassignment_increments_generation(self):
        state = reward_step(CONFIG, leased(), Tick(3))
        self.assertIs(reward_step(CONFIG, state, Submit(10, 1, CONFIG.expected, 7)), state)
        new = reward_step(CONFIG, state, Lease(20, 5))
        self.assertEqual((new.owner, new.generation), (20, 2))
        for worker, generation in ((10, 1), (20, 1), (10, 2)):
            self.assertIs(reward_step(CONFIG, new, Submit(worker, generation, CONFIG.expected, 7)), new)
        admitted = reward_step(CONFIG, new, Submit(20, 2, CONFIG.expected, 7))
        self.assertEqual(admitted.phase, RewardPhase.SUBMITTED)
        paid = reward_step(CONFIG, admitted, Accept(True, admitted.candidate))
        self.assertEqual((paid.balanceA, paid.balanceB, paid.escrow), (0, 5, 0))

    def test_same_worker_cannot_replay_its_previous_generation(self):
        state = reward_step(CONFIG, leased(), Tick(3))
        state = reward_step(CONFIG, state, Lease(10, 6))
        self.assertEqual(state.generation, 2)
        self.assertIs(reward_step(CONFIG, state, Submit(10, 1, CONFIG.expected, 7)), state)

    def test_lease_requires_allowed_worker_and_future_deadline(self):
        state = initial_reward(CONFIG)
        for lease in (Lease(99, 3), Lease(10, 0)):
            self.assertIs(reward_step(CONFIG, state, lease), state)
        active = leased()
        self.assertIs(reward_step(CONFIG, active, Lease(20, 6)), active)

    def test_submission_freezes_candidate_through_arbitrary_verifier_delay(self):
        state = submitted()
        c = state.candidate
        delayed = reward_step(CONFIG, state, Tick(2 ** 100))
        self.assertEqual(delayed.candidate, c)
        self.assertIs(reward_step(CONFIG, delayed, Lease(20, delayed.now + 10)), delayed)
        self.assertIs(reward_step(CONFIG, delayed, Submit(10, 1, CONFIG.expected, 8)), delayed)
        paid = reward_step(CONFIG, delayed, Accept(True, c))
        self.assertEqual(paid.phase, RewardPhase.ACCEPTED)
        self.assertEqual(paid.candidate, c)

    def test_evidence_must_match_every_candidate_field(self):
        state = submitted()
        c = state.candidate
        variants = [replace(c, **{field: getattr(c, field) + 1}) for field in
                    ("worker", "generation", "artifact", "submittedAt", "leaseExpires")]
        variants += [replace(c, binding=replace(c.binding, **{field: 99})) for field in
                     ("target", "input", "environment", "policy")]
        for wrong in variants:
            with self.subTest(evidence=wrong):
                self.assertIs(reward_step(CONFIG, state, Accept(True, wrong)), state)

    def test_untrusted_verdict_cannot_pay(self):
        state = submitted()
        self.assertIs(reward_step(CONFIG, state, Accept(False, state.candidate)), state)

    def test_acceptance_retry_is_idempotent_even_with_excess_escrow(self):
        state = replace(submitted(), escrow=50)
        verdict = Accept(True, state.candidate)
        paid = reward_step(CONFIG, state, verdict)
        for _ in range(20):
            self.assertIs(reward_step(CONFIG, paid, verdict), paid)
        self.assertEqual((paid.payouts, paid.balanceA, paid.escrow), (1, 5, 45))
        self.assertEqual(paid.total, state.total)

    def test_insufficient_escrow_refuses_payment(self):
        state = replace(submitted(), escrow=4)
        self.assertIs(reward_step(CONFIG, state, Accept(True, state.candidate)), state)

    def test_reference_values_are_immutable(self):
        state = submitted()
        with self.assertRaises(FrozenInstanceError):
            state.candidate.artifact = 9
        with self.assertRaises(FrozenInstanceError):
            state.candidate.binding.policy = 9


class ReservationTests(unittest.TestCase):
    def test_reservation_cap_and_no_double_reserve(self):
        initial = initial_reservation(10)
        self.assertIs(reservation_step(initial, Reserve(11)), initial)
        held = reservation_step(initial, Reserve(6))
        self.assertEqual((held.available, held.held), (4, 6))
        self.assertIs(reservation_step(held, Reserve(4)), held)

    def test_cancel_running_keeps_hold_until_trusted_stop(self):
        held = reservation_step(initial_reservation(10), Reserve(6))
        running = reservation_step(held, Start())
        cancelling = reservation_step(running, Cancel())
        self.assertEqual(cancelling.phase, ReservationPhase.CANCELLING)
        self.assertEqual((cancelling.available, cancelling.held, cancelling.spent), (4, 6, 0))
        self.assertIs(reservation_step(cancelling, Settle(0)), cancelling)
        self.assertIs(reservation_step(cancelling, Stop(False)), cancelling)
        stopped = reservation_step(cancelling, Stop(True))
        self.assertEqual(stopped.phase, ReservationPhase.STOPPED)
        self.assertEqual(stopped.held, 6)

    def test_cancel_before_start_is_stopped_without_releasing_hold(self):
        held = reservation_step(initial_reservation(10), Reserve(6))
        stopped = reservation_step(held, Cancel())
        self.assertEqual((stopped.phase, stopped.held), (ReservationPhase.STOPPED, 6))
        self.assertIs(reservation_step(stopped, Start()), stopped)
        refunded = reservation_step(stopped, Settle(0))
        self.assertEqual((refunded.available, refunded.held, refunded.spent), (10, 0, 0))

    def test_partial_charge_refunds_remainder_once(self):
        state = reservation_step(initial_reservation(10), Reserve(6))
        state = reservation_step(state, Start())
        state = reservation_step(state, Stop(True))
        self.assertIs(reservation_step(state, Settle(7)), state)
        paid = reservation_step(state, Settle(3))
        self.assertEqual((paid.available, paid.held, paid.spent), (7, 0, 3))
        self.assertEqual(paid.total, 10)
        for attempt in (Reserve(1), Start(), Cancel(), Stop(True), Settle(0), Settle(3)):
            self.assertIs(reservation_step(paid, attempt), paid)

    def test_zero_and_full_cap_are_well_defined(self):
        for cap in (0, 10):
            with self.subTest(cap=cap):
                state = reservation_step(initial_reservation(10), Reserve(cap))
                state = reservation_step(state, Start())
                state = reservation_step(state, Stop(True))
                state = reservation_step(state, Settle(cap))
                self.assertEqual((state.available, state.held, state.spent), (10 - cap, 0, cap))


class SerializationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = codec.loads((Path(__file__).parent / "fixtures" / "traces.json").read_text())

    def test_independent_handwritten_full_state_fixtures(self):
        for fixture in self.fixtures:
            with self.subTest(fixture=fixture["name"]):
                self.assertEqual(codec.replay(fixture["request"]), fixture["expected"])

    def test_natural_numbers_reject_bool_negative_float_string_and_null(self):
        for invalid in (True, False, -1, 1.0, "1", None):
            with self.subTest(value=invalid), self.assertRaises(codec.DecodeError):
                codec.natural(invalid)
        self.assertEqual(codec.natural(2 ** 100), 2 ** 100)

    def test_boolean_is_not_coerced_from_numbers_or_strings(self):
        for invalid in (0, 1, "true", "false", None):
            with self.subTest(value=invalid), self.assertRaises(codec.DecodeError):
                codec.boolean(invalid)

    def test_all_serialized_numeric_positions_reject_bool(self):
        def positions(value, path=()):
            if type(value) is int:
                yield path
            elif type(value) is dict:
                for key, child in value.items():
                    yield from positions(child, (*path, key))
            elif type(value) is list:
                for index, child in enumerate(value):
                    yield from positions(child, (*path, index))
        for fixture in self.fixtures:
            for path in positions(fixture["request"]):
                bad = deepcopy(fixture["request"])
                parent = bad
                for key in path[:-1]:
                    parent = parent[key]
                parent[path[-1]] = True
                with self.subTest(path=path), self.assertRaises(codec.DecodeError):
                    codec.replay(bad)

    def test_missing_extra_and_unknown_fields_fail_closed(self):
        source = self.fixtures[0]["request"]
        for key in source:
            bad = deepcopy(source)
            del bad[key]
            with self.subTest(missing=key), self.assertRaises(codec.DecodeError):
                codec.replay(bad)
        for bad_action in ({"type": "accept", "evidence": codec.encode(submitted().candidate)},
                           {"type": "tick", "delta": 1, "trusted": True},
                           {"type": "approve", "trusted": True},
                           {"type": "lease", "worker": 10}):
            bad = deepcopy(source)
            bad["actions"] = [bad_action]
            with self.subTest(action=bad_action), self.assertRaises(codec.DecodeError):
                codec.replay(bad)
        with self.assertRaises(codec.DecodeError):
            codec.reservation_action({"type": "stop"})

    def test_duplicate_keys_non_json_numbers_and_unknown_phases_reject(self):
        for text in ('{"trusted":false,"trusted":true}', '{"x":NaN}', '{"x":Infinity}'):
            with self.subTest(text=text), self.assertRaises(codec.DecodeError):
                codec.loads(text)
        bad = deepcopy(self.fixtures[0]["request"])
        bad["state"]["phase"] = "approved"
        with self.assertRaises(codec.DecodeError):
            codec.replay(bad)


class ConformanceHarnessTests(unittest.TestCase):
    def test_corpus_has_reachable_cases_and_explicit_guard_probes(self):
        cases = corpus()
        self.assertEqual(len(cases), len({c.name for c in cases}))
        self.assertIn("reachable-sequence", {c.scope for c in cases})
        self.assertIn("explicit-guard-probe", {c.scope for c in cases})
        for case in cases:
            states = codec.replay(case.request)["states"]
            keys = ("funder", "escrow", "balanceA", "balanceB") if case.request["kind"] == "reward" else (
                "available", "held", "spent")
            total = sum(states[0][key] for key in keys)
            self.assertEqual(len(states), len(case.request["actions"]) + 1)
            for state in states:
                self.assertEqual(sum(state[key] for key in keys), total, case.name)
                self.assertTrue(all(type(state[key]) is int and state[key] >= 0 for key in keys), case.name)
            if case.scope == "reachable-sequence" and case.request["kind"] == "reward":
                self.assertTrue(all(s["payouts"] <= 1 for s in states), case.name)
                candidates = [s["candidate"] for s in states if s["candidate"] is not None]
                self.assertTrue(not candidates or all(c == candidates[0] for c in candidates), case.name)

    def test_comparator_rejects_truncation_extra_output_and_changed_state(self):
        case = corpus()[0]
        expected = codec.replay(case.request)
        output = canonical(expected) + "\n"
        self.assertEqual(compare_outputs([case], output), len(expected["states"]))
        bad = deepcopy(expected)
        bad["states"][-1]["balanceA"] += 1
        for output in ("", output + output, canonical(bad), "not-json"):
            with self.subTest(output=output[:50]), self.assertRaises(ValueError):
                compare_outputs([case], output)

    def test_comparator_does_not_confuse_boolean_float_and_integer(self):
        case = corpus()[0]
        for wrong in (False, 0.0):
            bad = codec.replay(case.request)
            bad["states"][0]["now"] = wrong
            with self.subTest(wrong=wrong), self.assertRaises(ValueError):
                compare_outputs([case], canonical(bad))


class NegativeControlTests(unittest.TestCase):
    """These deliberately weakened transitions must violate real properties."""
    def assert_binding_property(self, step):
        state = leased()
        wrong = replace(CONFIG.expected, policy=99)
        self.assertEqual(step(CONFIG, state, Submit(10, 1, wrong, 7)), state)

    def assert_same_candidate_property(self, step):
        state = submitted()
        self.assertEqual(step(CONFIG, state, Accept(True, replace(state.candidate, artifact=99))), state)

    def assert_delay_property(self, step):
        state = reward_step(CONFIG, submitted(), Tick(100))
        self.assertEqual(step(CONFIG, state, Accept(True, state.candidate)).phase, RewardPhase.ACCEPTED)

    def assert_once_property(self, step):
        state = replace(submitted(), escrow=50)
        verdict = Accept(True, state.candidate)
        paid = step(CONFIG, state, verdict)
        self.assertEqual(step(CONFIG, paid, verdict), paid)

    def assert_hold_property(self, step):
        state = reservation_step(reservation_step(initial_reservation(10), Reserve(6)), Start())
        after = step(state, Cancel())
        self.assertEqual((after.available, after.held, after.spent), (4, 6, 0))

    def test_weakened_binding_guard_is_detected(self):
        def mutant(cfg, state, act):
            return reward_step(replace(cfg, expected=act.binding), state, act)
        self.assert_binding_property(reward_step)
        with self.assertRaises(AssertionError):
            self.assert_binding_property(mutant)

    def test_artifact_evidence_substitution_is_detected(self):
        def mutant(cfg, state, act):
            return reward_step(cfg, state, Accept(act.trusted, state.candidate))
        self.assert_same_candidate_property(reward_step)
        with self.assertRaises(AssertionError):
            self.assert_same_candidate_property(mutant)

    def test_expiry_recheck_at_verification_is_detected(self):
        def mutant(cfg, state, act):
            return state if state.now >= state.expires else reward_step(cfg, state, act)
        self.assert_delay_property(reward_step)
        with self.assertRaises(AssertionError):
            self.assert_delay_property(mutant)

    def test_reopened_payout_slot_is_detected(self):
        def mutant(cfg, state, act):
            if state.phase == RewardPhase.ACCEPTED:
                state = replace(state, phase=RewardPhase.SUBMITTED, payouts=0)
            return reward_step(cfg, state, act)
        self.assert_once_property(reward_step)
        with self.assertRaises(AssertionError):
            self.assert_once_property(mutant)

    def test_premature_cancel_refund_is_detected(self):
        def mutant(state, act):
            changed = reservation_step(state, act)
            return replace(changed, available=changed.available + changed.held, held=0)
        self.assert_hold_property(reservation_step)
        with self.assertRaises(AssertionError):
            self.assert_hold_property(mutant)


if __name__ == "__main__":
    unittest.main()
