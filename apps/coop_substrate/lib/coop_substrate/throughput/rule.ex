defmodule CoopSubstrate.Throughput.Rule do
  @moduledoc """
  A throughput rule: the versioned pure function weighting recorded
  throughput components (Phase 1C; hand-off §2.4). Activated in the log by
  `ThroughputRuleActivated{rule_id, params}` — never hardcoded (docs/
  phase1c_plan.md P3); every throughput entry records the `rule_id` that
  credited it, and a new rule applies forward only. Same discipline as
  `CoopSubstrate.Capital.AccrualRule`.

  Implementations MUST be pure and total over valid params (validated at the
  append gate via `validate_params/1`, so the fold never sees bad params).
  """

  @doc "Credited throughput minor-units for one component event. Pure; integer math."
  @callback credit(params :: map(), component :: String.t(), units :: pos_integer()) ::
              non_neg_integer()

  @doc "Gate-time validation of an activation's params."
  @callback validate_params(params :: term()) :: :ok | {:error, term()}
end
