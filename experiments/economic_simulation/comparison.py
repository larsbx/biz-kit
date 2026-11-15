"""Paired Monte Carlo comparisons with independent policy state."""
import copy
import math
import statistics
from .engine import simulate
from .scenario import ScenarioError, digest

RATE_METRICS = ("quote_rate_7d", "pilot_quote_rate_7d", "commitment_rate_7d", "fulfillment_rate_7d", "original_due_date_fulfillment", "original_promise_reliability")

def _summary(values):
    if not values:
        return {"replicates":0, "mean":None, "standard_error":None}
    return {"replicates":len(values), "mean":statistics.mean(values), "standard_error":statistics.stdev(values)/math.sqrt(len(values)) if len(values)>1 else None}

def compare(scenario, policies, seeds):
    """Sampling uncertainty describes synthetic replicates, not field evidence."""
    if not isinstance(policies,dict) or not policies or any(not isinstance(k,str) or not k or not isinstance(v,dict) for k,v in policies.items()):
        raise ScenarioError("policies must be a nonempty map of names to policy overrides")
    seeds=list(seeds)
    if not seeds or any(type(seed) is not int or not 0 <= seed < 2**63 for seed in seeds) or len(seeds)!=len(set(seeds)):
        raise ScenarioError("seeds must be distinct nonnegative 63-bit integers")
    if len(policies)*len(seeds)>10000:
        raise ScenarioError("comparison exceeds the explicit 10,000-run budget")
    runs, samples = [], {}
    for name,overrides in policies.items():
        variant=copy.deepcopy(scenario)
        variant["policy"]=variant.get("policy",{}) | overrides
        samples[name]={}
        for seed in seeds:
            result=simulate(variant,seed)
            samples[name][seed]=result["metrics"]
            runs.append({"policy":name,"seed":seed,"scenario_sha256":result["provenance"]["scenario_sha256"],"result_sha256":digest(result),"provenance":result["provenance"],"metrics":result["metrics"]})
    baseline=next(iter(policies))
    summaries={}
    for name in policies:
        summaries[name]={}
        for metric in RATE_METRICS:
            values=[samples[name][s][metric]["rate"] for s in seeds if samples[name][s][metric]["rate"] is not None]
            differences=[samples[name][s][metric]["rate"]-samples[baseline][s][metric]["rate"] for s in seeds if samples[name][s][metric]["rate"] is not None and samples[baseline][s][metric]["rate"] is not None]
            summaries[name][metric]={"rate":_summary(values),"paired_difference_from_baseline":_summary(differences)}
    return {"schema_version":"1.0","source":"synthetic","model":"paired_policy_comparison_v1","baseline_policy":baseline,"policies":copy.deepcopy(policies),"seeds":seeds,"uncertainty_scope":"Monte Carlo variation under uncalibrated model assumptions; not field evidence","summaries":summaries,"runs":runs}

