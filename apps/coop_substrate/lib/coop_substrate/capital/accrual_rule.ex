defmodule CoopSubstrate.Capital.AccrualRule do
  @moduledoc """
  An accrual rule: the versioned, pure function at the heart of the capital
  account (hand-off §2.3). The rule is a *parameter* — activated in the log
  by `AccrualRuleActivated{rule_id, params}`, never hardcoded — and every
  account entry records the `rule_id` that credited it, so historical
  accruals are reproducible forever. A new rule applies forward only; nothing
  ever recomputes past entries.

  Implementations MUST be pure and total over valid params (validated at the
  append gate via `validate_params/1`, so the fold never sees bad params).
  """

  @doc "Credited minor units for one patronage event. Pure; integer math only."
  @callback credit(params :: map(), kind :: String.t(), amount_minor :: pos_integer()) ::
              non_neg_integer()

  @doc "Gate-time validation of an activation's params."
  @callback validate_params(params :: term()) :: :ok | {:error, term()}
end
