defmodule CoopSubstrate.Floor.Rule do
  @moduledoc """
  A participation-floor rule (Phase 1C; hand-off §2.4): the versioned pure
  predicate behind `cleared?(member, window)`. Activated in the log by
  `FloorRuleActivated{rule_id, params}` — thresholds and windows are
  constitutionalized parameters, never hardcoded (docs/phase1c_plan.md P3).
  """

  @doc "Does this throughput value clear the floor for this entity class? Pure."
  @callback cleared?(params :: map(), class :: String.t(), value_minor :: non_neg_integer()) ::
              boolean()

  @doc "Gate-time validation of an activation's params."
  @callback validate_params(params :: term()) :: :ok | {:error, term()}
end
