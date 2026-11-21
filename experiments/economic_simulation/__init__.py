"""Synthetic economic experiments; no business or settlement authority."""

__version__ = "0.1.0"


def simulate(scenario, seed=0):
    """Run an independent scenario and return a versioned JSON-compatible result."""
    from .engine import simulate as run

    return run(scenario, seed)


def compare(scenario, policies, seeds):
    """Compare policies using keyed common primitives and independent state."""
    from .comparison import compare as run

    return run(scenario, policies, seeds)
