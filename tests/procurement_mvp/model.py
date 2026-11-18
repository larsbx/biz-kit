#!/usr/bin/env python3
"""Finite reference model and Elixir conformance cases; no production-data access."""
import argparse
from collections import deque
from pathlib import Path

ACTIONS = ('qualify', 'quote1', 'quote2', 'accept1', 'accept2', 'fulfill', 'cancel', 'dispute', 'payment')
INITIAL = (0, 0, 0, False)  # requested, latest quote, accepted quote, payment attestation


def step(s, action, authorized=True, current=True):
    p, q, a, e = s
    if not authorized or not current:
        return None
    if action == 'qualify' and p == 0:
        return (1, q, a, e)
    if action.startswith('quote') and p == 1 and int(action[-1]) == q + 1:
        return (p, q + 1, a, e)
    if action.startswith('accept') and p == 1 and q == int(action[-1]) and a == 0:
        return (2, q, q, e)
    if action == 'fulfill' and p == 2:
        return (3, q, a, e)
    if action == 'cancel' and p in (0, 1, 2):
        return (4, q, a, e)
    if action == 'dispute' and p in (2, 3):
        return (5, q, a, e)
    if action == 'payment' and p in (2, 3, 5) and a > 0:
        return (p, q, a, True)
    return None


def valid(s):
    p, q, a, e = s
    return (not e or a > 0) and (p not in (2, 3, 5) or a > 0) and 0 <= a <= q <= 2


def transition_safe(before, after, action, authorized=True, current=True):
    if after is None:
        return True
    return (authorized and current and valid(after)
            and (before[2] == 0 or before[2] == after[2])
            and (not action.startswith('accept') or before[3] == after[3]))


def build():
    paths = {INITIAL: ()}
    queue = deque([INITIAL])
    while queue:
        s = queue.popleft()
        for action in ACTIONS:
            nxt = step(s, action)
            assert transition_safe(s, nxt, action)
            if nxt is not None and nxt not in paths:
                paths[nxt] = paths[s] + (action,)
                queue.append(nxt)
    rows = []
    for s, path in paths.items():
        for action in ACTIONS:
            for authorized in (True, False):
                for current in (True, False):
                    nxt = step(s, action, authorized, current)
                    assert transition_safe(s, nxt, action, authorized, current)
                    values = nxt if nxt is not None else s
                    rows.append('\t'.join([
                        ','.join(path) or '-', action, str(authorized).lower(),
                        str(current).lower(), 'ok' if nxt is not None else 'error',
                        *(str(v).lower() for v in values)]))
    # Negative controls: each broken transition must be detected by the checker.
    assert not transition_safe((1, 1, 0, False), (2, 1, 1, True), 'accept1')
    assert not transition_safe((2, 1, 1, False), (2, 2, 2, False), 'quote2')
    assert not transition_safe(INITIAL, (1, 0, 0, False), 'qualify', authorized=False)
    assert not transition_safe(INITIAL, (1, 0, 0, False), 'qualify', current=False)
    return paths, rows


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    paths, rows = build()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text('\n'.join(rows) + '\n', encoding='utf-8')
    print(f'{len(paths)} reachable abstract states; {len(rows)} conformance cases; 4 negative controls detected')
    print('Python reference only: Elixir agreement and Lean/Quint acceptance require their own runs.')
