"""Paired Monte Carlo comparisons with independent policy state."""

import copy
import math
import statistics
from .engine import simulate
from .scenario import ScenarioError, digest, validate_scenario

RATE_METRICS = (
    "quote_rate_7d",
    "pilot_quote_rate_7d",
    "commitment_rate_7d",
    "fulfillment_rate_7d",
    "original_due_date_fulfillment",
    "original_promise_reliability",
)


def _summary(values):
    if not values:
        return {"replicates": 0, "mean": None, "standard_error": None}
    return {
        "replicates": len(values),
        "mean": statistics.mean(values),
        "standard_error": statistics.stdev(values) / math.sqrt(len(values))
        if len(values) > 1
        else None,
    }


def compare(scenario, policies, seeds):
    """Sampling uncertainty describes synthetic replicates, not field evidence."""
    if (
        not isinstance(policies, dict)
        or not policies
        or any(
            not isinstance(k, str) or not k or not isinstance(v, dict)
            for k, v in policies.items()
        )
    ):
        raise ScenarioError(
            "policies must be a nonempty map of names to policy overrides"
        )
    if len(policies) > 10000:
        raise ScenarioError("comparison exceeds the explicit 10,000-run budget")
    base = validate_scenario(scenario)
    # A caller may provide a generator. Enforce the experiment budget while
    # consuming it, before materializing an arbitrarily large/infinite input.
    try:
        seed_iterator = iter(seeds)
    except TypeError as error:
        raise ScenarioError(
            "seeds must be an iterable of distinct nonnegative 63-bit integers"
        ) from error
    bounded_seeds = []
    seen = set()
    maximum_seeds = 10000 // len(policies)
    for seed in seed_iterator:
        if len(bounded_seeds) >= maximum_seeds:
            raise ScenarioError("comparison exceeds the explicit 10,000-run budget")
        if type(seed) is not int or not 0 <= seed < 2**63 or seed in seen:
            raise ScenarioError("seeds must be distinct nonnegative 63-bit integers")
        seen.add(seed)
        bounded_seeds.append(seed)
    seeds = bounded_seeds
    if not seeds:
        raise ScenarioError("seeds must be distinct nonnegative 63-bit integers")
    # Reject every malformed override before spending work on any simulation.
    variants = {
        name: validate_scenario({**base, "policy": base["policy"] | overrides})
        for name, overrides in policies.items()
    }
    runs, samples = [], {}
    for name, variant in variants.items():
        samples[name] = {}
        for seed in seeds:
            result = simulate(variant, seed)
            samples[name][seed] = result["metrics"]
            runs.append(
                {
                    "policy": name,
                    "seed": seed,
                    "scenario_sha256": result["provenance"]["scenario_sha256"],
                    "result_sha256": digest(result),
                    "provenance": result["provenance"],
                    "metrics": result["metrics"],
                }
            )
    baseline = next(iter(policies))
    summaries = {}
    for name in policies:
        summaries[name] = {}
        for metric in RATE_METRICS:
            values = [
                samples[name][s][metric]["rate"]
                for s in seeds
                if samples[name][s][metric]["rate"] is not None
            ]
            differences = [
                samples[name][s][metric]["rate"] - samples[baseline][s][metric]["rate"]
                for s in seeds
                if samples[name][s][metric]["rate"] is not None
                and samples[baseline][s][metric]["rate"] is not None
            ]
            summaries[name][metric] = {
                "rate": _summary(values),
                "paired_difference_from_baseline": _summary(differences),
            }
    return {
        "schema_version": "1.0",
        "source": "synthetic",
        "model": "paired_policy_comparison_v1",
        "baseline_policy": baseline,
        "policies": copy.deepcopy(policies),
        "seeds": seeds,
        "uncertainty_scope": "Monte Carlo variation under uncalibrated model assumptions; not field evidence",
        "summaries": summaries,
        "runs": runs,
    }
