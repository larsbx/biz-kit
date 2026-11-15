"""Independent exhaustive small-graph and refusal controls for the matcher."""

import itertools
import pathlib
import random
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from matching import InvalidGraphError, MatchingBudgetExceeded, pack_cycles


def assignment_oracle(nodes, edges):
    """Enumerate permutations directly, independently of both solver algorithms."""
    allowed = set(edges)
    best = {None: 0, 2: 0, 3: 0, 4: 0}
    for destinations in itertools.permutations(nodes):
        successor = dict(zip(nodes, destinations))
        if any(a != b and (a, b) not in allowed for a, b in successor.items()):
            continue
        visited, lengths = set(), []
        for start in nodes:
            if start in visited:
                continue
            current, length = start, 0
            while current not in visited:
                visited.add(current)
                length += 1
                current = successor[current]
            if length > 1:
                lengths.append(length)
        score, longest = sum(lengths), max(lengths, default=0)
        for maximum in best:
            if maximum is None or longest <= maximum:
                best[maximum] = max(best[maximum], score)
    return best


class MatchingTests(unittest.TestCase):
    def assert_valid_plan(self, plan, nodes, edges, maximum):
        self.assertEqual(plan["status"], "optimal")
        self.assertIsInstance(plan["work_units"], int)
        self.assertGreaterEqual(plan["work_units"], 0)
        self.assertEqual(plan["cycles"], sorted(plan["cycles"]))
        seen, allowed = set(), set(edges)
        for cycle in plan["cycles"]:
            self.assertGreaterEqual(len(cycle), 2)
            if maximum is not None:
                self.assertLessEqual(len(cycle), maximum)
            self.assertEqual(cycle[0], min(cycle))
            for source, destination in zip(cycle, cycle[1:] + cycle[:1]):
                self.assertIn(source, nodes)
                self.assertNotIn(source, seen)
                self.assertIn((source, destination), allowed)
                seen.add(source)
        self.assertEqual(plan["matched_count"], len(seen))

    def test_every_directed_graph_on_at_most_four_nodes_against_permutation_oracle(
        self,
    ):
        for size in range(5):
            nodes = [f"n{i}" for i in range(size)]
            possible = list(itertools.permutations(nodes, 2))
            for mask in range(1 << len(possible)):
                edges = [e for i, e in enumerate(possible) if mask & (1 << i)]
                expected = assignment_oracle(nodes, edges)
                for maximum in (None, 2, 3, 4):
                    plan = pack_cycles(nodes, edges, max_cycle_length=maximum)
                    if plan["matched_count"] != expected[maximum]:
                        self.fail(
                            f"incorrect optimum: {nodes=}, {edges=}, {maximum=}, {plan=}"
                        )
                    self.assert_valid_plan(plan, nodes, edges, maximum)

    def test_unrestricted_five_and_six_party_cycles_are_not_capped_at_four(self):
        for size in (5, 6):
            nodes = [f"merchant-{i}" for i in range(size)]
            edges = list(zip(nodes, nodes[1:] + nodes[:1]))
            result = pack_cycles(nodes, edges)
            self.assertEqual(result["cycles"], [nodes])
            self.assertEqual(result["matched_count"], size)
            self.assertEqual(result["algorithm"], "hungarian_assignment")
            self.assertEqual(pack_cycles(nodes, edges, 4)["matched_count"], 0)
            self.assertEqual(pack_cycles(nodes, edges, size)["matched_count"], size)

    def test_longest_cycle_greedy_would_lose_to_two_disjoint_cycles(self):
        nodes = ["a", "b", "c", "d"]
        edges = [("a", "b"), ("b", "c"), ("c", "a"), ("a", "d"), ("d", "a"), ("c", "b")]
        for maximum in (None, 2, 3, 4):
            result = pack_cycles(nodes, edges, maximum)
            self.assertEqual(result["cycles"], [["a", "d"], ["b", "c"]])
            self.assertEqual(result["matched_count"], 4)

    def test_result_and_work_count_are_stable_under_input_permutation(self):
        nodes = ["slot-a", "slot-b", "slot-c", "slot-d", "slot-e"]
        edges = list(itertools.permutations(nodes, 2))
        generator = random.Random(8127)
        for maximum in (None, 2, 3, 4):
            expected = pack_cycles(nodes, edges, maximum)
            for _ in range(25):
                shuffled_nodes, shuffled_edges = nodes.copy(), edges.copy()
                generator.shuffle(shuffled_nodes)
                generator.shuffle(shuffled_edges)
                self.assertEqual(
                    pack_cycles(shuffled_nodes, shuffled_edges, maximum), expected
                )

    def test_budget_is_exact_reproducible_and_never_returns_partial_optimal(self):
        nodes = ["a", "b", "c", "d", "e"]
        edges = list(itertools.permutations(nodes, 2))
        for maximum in (None, 3):
            baseline = pack_cycles(nodes, edges, maximum)
            required = baseline["work_units"]
            self.assertEqual(pack_cycles(nodes, edges, maximum, required), baseline)
            errors = []
            for _ in range(2):
                with self.assertRaises(MatchingBudgetExceeded) as caught:
                    pack_cycles(nodes, edges, maximum, required - 1)
                error = caught.exception
                self.assertLessEqual(error.work_units, required - 1)
                self.assertGreater(error.attempted_work_units, required - 1)
                errors.append(
                    (error.stage, error.work_units, error.attempted_work_units)
                )
            self.assertEqual(errors[0], errors[1])

    def test_no_fixed_node_limit_for_isolated_slots(self):
        nodes = [f"slot-{i}" for i in range(2000)]
        for maximum in (None, 3):
            result = pack_cycles(nodes, [], maximum, 2000)
            self.assertEqual(result["cycles"], [])
            self.assertEqual(result["matched_count"], 0)
            self.assertEqual(result["work_units"], 2000)
        with self.assertRaises(MatchingBudgetExceeded):
            pack_cycles(nodes, [], work_budget=1999)

    def test_dag_edges_are_not_completed_trades(self):
        nodes = ["a", "b", "c", "d"]
        edges = [("a", "b"), ("b", "c"), ("c", "d")]
        for maximum in (None, 2, 3, 4):
            self.assertEqual(pack_cycles(nodes, edges, maximum)["matched_count"], 0)

    def test_uri_tokens_and_json_edge_pairs_preserve_identity(self):
        nodes = ["https://business.test/slots/a", "https://other.test/slots/b"]
        result = pack_cycles(nodes, [[nodes[0], nodes[1]], [nodes[1], nodes[0]]])
        self.assertEqual(result["cycles"], [nodes])

    def test_invalid_nodes_edges_and_duplicates_are_rejected(self):
        cases = [
            ("abc", []),
            (["a"], ()),
            (["a", "a"], []),
            ([""], []),
            ([" a"], []),
            (["a b"], []),
            (["a\nb"], []),
            (["a\x00b"], []),
            (["a\u200bb"], []),
            ([None], []),
            ([7], []),
            (["a"], [("a", "a")]),
            (["a"], [("a", "b")]),
            (["a", "b"], [("a", "b"), ("a", "b")]),
            (["a", "b"], [("a", "b"), ["a", "b"]]),
            (["a", "b"], ["ab"]),
            (["a", "b"], [("a",)]),
            (["a", "b"], [("a", "b", "a")]),
            (["a", "b"], [("a", [])]),
        ]
        for nodes, edges in cases:
            with self.subTest(nodes=nodes, edges=edges):
                with self.assertRaises(InvalidGraphError):
                    pack_cycles(nodes, edges)

    def test_invalid_solver_controls_are_rejected(self):
        for maximum in (0, 1, -1, 2.0, "3", True, False):
            with self.assertRaises(InvalidGraphError):
                pack_cycles([], [], max_cycle_length=maximum)
        for budget in (0, -1, 1.5, "100", True, False, None):
            with self.assertRaises(InvalidGraphError):
                pack_cycles([], [], work_budget=budget)

    def test_inputs_are_not_mutated(self):
        nodes = ["c", "a", "b"]
        edges = [["c", "a"], ["a", "b"], ["b", "c"]]
        before_nodes, before_edges = nodes.copy(), [e.copy() for e in edges]
        for maximum in (None, 3):
            pack_cycles(nodes, edges, maximum)
        self.assertEqual(nodes, before_nodes)
        self.assertEqual(edges, before_edges)


if __name__ == "__main__":
    unittest.main()
