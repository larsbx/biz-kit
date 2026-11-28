"""Independent finite reference controls; not execution of Lean or Elixir."""
from itertools import product
from collections import Counter

# Two narrators and one community; six distinct material/audience pairs.
ACTORS = ('n1', 'n2', 'community', 'sponsor', 'operator', 'governance', 'unknown')
PAIRS = tuple(product(('audio', 'transcript', 'excerpt'), ('research', 'public')))
REQUIRED = frozenset(ACTORS[:3])
KEYS = tuple(product(ACTORS[:3], PAIRS))

def eligible(grants, scope, pair):
    return scope == 'project' and all((a, pair) in grants for a in REQUIRED)

def review(grants, revision, scope, actor, action, pair, expected):
    key = (actor, pair)
    if scope != 'project': return 'scope', grants, revision
    if expected != revision: return 'stale', grants, revision
    if actor not in REQUIRED: return 'unauthorized', grants, revision
    if (key in grants) == action: return 'unchanged', grants, revision
    return 'ok', (grants | {key}) if action else (grants - {key}), revision + 1

counts = Counter()
# All 64 grant subsets on every pair-of-pairs (including identical pair),
# with all command actors and guard combinations; other pairs start empty.
for first, second in product(PAIRS, repeat=2):
    keys = tuple(dict.fromkeys(product(ACTORS[:3], (first, second))))
    for mask in range(1 << len(keys)):
        grants = frozenset(k for i, k in enumerate(keys) if mask >> i & 1)
        for actor, action, pair, scope, expected in product(ACTORS, (False, True), (first, second), ('project', 'other'), (2, 3)):
            code, after, rev = review(grants, 2, scope, actor, action, pair, expected)
            key = (actor, pair)
            expected_code = ('scope' if scope != 'project' else 'stale' if expected != 2 else 'unauthorized' if actor not in REQUIRED else 'unchanged' if (key in grants) == action else 'ok')
            assert code == expected_code
            counts[code] += 1
            if code != 'ok':
                assert (after, rev) == (grants, 2)
                continue
            assert rev == 3 and (key in after) == action
            assert grants ^ after == {key}
            for p in PAIRS:
                assert not eligible(after, 'other', p)
                if p != pair: assert eligible(after, 'project', p) == eligible(grants, 'project', p)
            if not action: assert not eligible(after, 'project', pair)
            assert review(after, rev, scope, actor, action, pair, expected)[0] == 'stale'
print(dict(sorted(counts.items())))
print('Total transitions:', sum(counts.values()))
