"""Deterministic exact maximum-cardinality packing of directed slot cycles.

Nodes are indivisible supply/need slots, not businesses. The caller determines
physical compatibility and availability. Outputs are proposals, not inventory
reservations, consent, transfers or delivery evidence. Unrestricted matching
uses Hungarian assignment. Explicit length bounds are sensitivity experiments,
solved by exhaustive cycle enumeration and exact disjoint packing.
"""

from __future__ import annotations
from dataclasses import dataclass


class InvalidGraphError(ValueError):
    """The graph or solver controls violate the API contract."""


class MatchingBudgetExceeded(RuntimeError):
    """Computation stopped without an optimality claim or partial result."""

    def __init__(self, work_budget, work_units, attempted_work_units, stage):
        self.work_budget = work_budget
        self.work_units = work_units
        self.attempted_work_units = attempted_work_units
        self.stage = stage
        super().__init__(f"matching work budget {work_budget} exhausted at {stage} "
                         f"({work_units} completed units; {attempted_work_units} required)")


@dataclass(slots=True)
class _Budget:
    limit: int
    used: int = 0

    def take(self, stage, units=1):
        following = self.used + units
        if following > self.limit:
            raise MatchingBudgetExceeded(self.limit, self.used, following, stage)
        self.used = following


def _validate_graph(nodes, edges, budget):
    if not isinstance(nodes, list) or not isinstance(edges, list):
        raise InvalidGraphError("nodes and edges must be lists")
    seen = set()
    for node in nodes:
        budget.take("validate-node")
        if not (isinstance(node, str) and node and node.isprintable()
                and not any(character.isspace() for character in node)):
            raise InvalidGraphError("node IDs must be nonempty printable tokens without whitespace")
        if node in seen:
            raise InvalidGraphError(f"duplicate node ID: {node!r}")
        seen.add(node)
    pairs = set()
    for edge in edges:
        budget.take("validate-edge")
        if not isinstance(edge, (tuple, list)) or len(edge) != 2:
            raise InvalidGraphError("each edge must be a pair of known node IDs")
        source, destination = edge
        if not isinstance(source, str) or not isinstance(destination, str):
            raise InvalidGraphError("edge endpoints must be string node IDs")
        if source not in seen or destination not in seen:
            raise InvalidGraphError("edge endpoints must refer to known nodes")
        if source == destination:
            raise InvalidGraphError("input self-edges are not trade opportunities")
        pair = (source, destination)
        if pair in pairs:
            raise InvalidGraphError(f"duplicate edge: {pair!r}")
        pairs.add(pair)
    ordered = sorted(seen)
    index = {node: position for position, node in enumerate(ordered)}
    return ordered, {(index[source], index[destination]) for source, destination in pairs}


def _assignment_cycles(count, edges, budget):
    """Hungarian assignment: real edge 0, self 1, forbidden edge n+1.

    All-self costs n, so no optimal assignment uses a forbidden edge. Its
    non-self permutation cycles maximize matched slots. Sorted rows/columns
    and strict comparisons resolve ties deterministically. Costs are lazy:
    auxiliary solver arrays occupy O(n) space, without a dense cost matrix.
    """
    budget.take("assignment-initialize", 4 * (count + 1))
    row_potential = [0] * (count + 1)
    column_potential = [0] * (count + 1)
    row_at_column = [0] * (count + 1)
    previous_column = [0] * (count + 1)
    infinity = (count + 1) ** 2 + 1
    for row in range(1, count + 1):
        budget.take("assignment-row-state", 2 * (count + 1))
        row_at_column[0] = row
        column = 0
        minimum_slack = [infinity] * (count + 1)
        used = [False] * (count + 1)
        while True:
            budget.take("assignment-search")
            used[column] = True
            source = row_at_column[column]
            delta, next_column = infinity, 0
            for candidate in range(1, count + 1):
                budget.take("assignment-relax")
                if used[candidate]:
                    continue
                cost = (1 if source == candidate else
                        0 if (source - 1, candidate - 1) in edges else count + 1)
                slack = cost - row_potential[source] - column_potential[candidate]
                if slack < minimum_slack[candidate]:
                    minimum_slack[candidate] = slack
                    previous_column[candidate] = column
                if minimum_slack[candidate] < delta:
                    delta, next_column = minimum_slack[candidate], candidate
            for candidate in range(count + 1):
                budget.take("assignment-potential")
                if used[candidate]:
                    row_potential[row_at_column[candidate]] += delta
                    column_potential[candidate] -= delta
                else:
                    minimum_slack[candidate] -= delta
            column = next_column
            if row_at_column[column] == 0:
                break
        while column != 0:
            budget.take("assignment-augment")
            predecessor = previous_column[column]
            row_at_column[column] = row_at_column[predecessor]
            column = predecessor

    budget.take("assignment-decode-state", count)
    destinations = [0] * count
    for column in range(1, count + 1):
        budget.take("assignment-decode")
        source, destination = row_at_column[column] - 1, column - 1
        if source != destination and (source, destination) not in edges:
            raise RuntimeError("internal assignment error: selected a forbidden edge")
        destinations[source] = destination
    cycles, visited = [], set()
    for start in range(count):
        budget.take("assignment-cycle-start")
        if start in visited:
            continue
        path, current = [], start
        while current not in visited:
            budget.take("assignment-cycle-edge")
            visited.add(current)
            path.append(current)
            current = destinations[current]
        if current != start:
            raise RuntimeError("internal assignment error: assignment is not a permutation")
        if len(path) > 1:
            cycles.append(tuple(path))
    return sorted(cycles)


def _bounded_cycles(count, edges, maximum, budget):
    """Enumerate canonical cycles, then exactly pack them with bitmask DP.

    Explicit stacks avoid a Python recursion-depth cap on nodes/cycle length.
    """
    budget.take("bounded-adjacency-state", count)
    adjacency = [[] for _ in range(count)]
    for source, destination in sorted(edges):
        budget.take("bounded-adjacency-edge")
        adjacency[source].append(destination)
    candidates = []
    limit = min(maximum, count)
    for start in range(count):
        budget.take("cycle-enumeration-start")
        path, present, next_neighbors = [start], {start}, [0]
        while path:
            budget.take("cycle-enumeration-step")
            last, neighbor_index = path[-1], next_neighbors[-1]
            if neighbor_index == len(adjacency[last]):
                present.remove(path.pop())
                next_neighbors.pop()
                continue
            destination = adjacency[last][neighbor_index]
            next_neighbors[-1] += 1
            if destination == start and len(path) >= 2:
                candidates.append(tuple(path))
            elif destination > start and destination not in present and len(path) < limit:
                path.append(destination)
                present.add(destination)
                next_neighbors.append(0)
    if not candidates:
        return []
    candidates.sort()
    budget.take("packing-index-state", count)
    cycles_at_node = [[] for _ in range(count)]
    masks, active = [], 0
    for cycle_index, cycle in enumerate(candidates):
        mask = 0
        for node in cycle:
            budget.take("packing-index-node")
            mask |= 1 << node
            cycles_at_node[node].append(cycle_index)
        masks.append(mask)
        active |= mask

    # Skip the lowest active node, or select one whole cycle containing it.
    # This partitions all disjoint packings; a partial search is never returned.
    solved = {0: (0, None)}
    pending, stack = {}, [(active, False)]
    while stack:
        budget.take("packing-state")
        available, expanded = stack.pop()
        if available in solved:
            continue
        if not expanded:
            first_bit = available & -available
            options = [(available ^ first_bit, None)]
            for cycle_index in cycles_at_node[first_bit.bit_length() - 1]:
                budget.take("packing-feasibility")
                mask = masks[cycle_index]
                if available & mask == mask:
                    options.append((available ^ mask, cycle_index))
            pending[available] = options
            stack.append((available, True))
            for residual, _ in reversed(options):
                budget.take("packing-schedule")
                if residual not in solved:
                    stack.append((residual, False))
        else:
            best_score, best_cycle = -1, None
            for residual, cycle_index in pending.pop(available):
                budget.take("packing-compare")
                score = solved[residual][0]
                if cycle_index is not None:
                    score += len(candidates[cycle_index])
                if score > best_score:
                    best_score, best_cycle = score, cycle_index
            solved[available] = (best_score, best_cycle)
    selected, remaining = [], active
    while remaining:
        budget.take("packing-decode")
        _, cycle_index = solved[remaining]
        if cycle_index is None:
            remaining ^= remaining & -remaining
        else:
            selected.append(candidates[cycle_index])
            remaining ^= masks[cycle_index]
    return sorted(selected)


def pack_cycles(nodes: list[str], edges: list[tuple[str, str]],
                max_cycle_length: int | None = None,
                work_budget: int = 250_000) -> dict:
    """Exactly maximize matched slot count; do not evaluate utility or delivery.

    IDs are unique printable tokens without whitespace; URI-style IDs work.
    Distinct directed edges connect different known IDs. Tuple/list pairs are
    accepted; malformed inputs and duplicates raise InvalidGraphError.

    None means unrestricted length. Explicit integer caps >=2 are experimental
    controls, not a business-membership policy. Work units count graph entries,
    array cells, assignment relaxations/potential updates and DFS/DP steps.
    They are deterministic abstract work counters, not CPU time/instructions.
    Exhaustion raises MatchingBudgetExceeded without returning a partial plan.
    Input ordering cannot affect output or work count; inputs are not mutated.
    """
    if type(work_budget) is not int or work_budget <= 0:
        raise InvalidGraphError("work_budget must be a positive integer")
    if max_cycle_length is not None and (type(max_cycle_length) is not int or max_cycle_length < 2):
        raise InvalidGraphError("max_cycle_length must be None or an integer >= 2")
    budget = _Budget(work_budget)
    ordered, indexed = _validate_graph(nodes, edges, budget)
    algorithm = "hungarian_assignment" if max_cycle_length is None else "exhaustive_cycle_packing_dp"
    if not indexed:
        cycles = []
    elif max_cycle_length is None:
        cycles = _assignment_cycles(len(ordered), indexed, budget)
    else:
        cycles = _bounded_cycles(len(ordered), indexed, max_cycle_length, budget)
    return {"cycles": [[ordered[node] for node in cycle] for cycle in cycles],
            "matched_count": sum(map(len, cycles)), "status": "optimal",
            "algorithm": algorithm, "work_units": budget.used}
