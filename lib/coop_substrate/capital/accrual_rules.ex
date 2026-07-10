defmodule CoopSubstrate.Capital.AccrualRules do
  @moduledoc """
  The code registry of accrual-rule implementations. A rule becomes *active*
  only via an in-log `AccrualRuleActivated` event (gated: the `rule_id` must
  be known here and its params must validate) — the registry maps rule ids to
  the pure modules that implement them.

  Tests may inject rules via the `:extra_accrual_rules` application env,
  mirroring the type registry's `:extra_event_types` (production registration
  workflow is a later governance phase).
  """

  @builtin %{
    "capital-accrual-v1" => CoopSubstrate.Capital.Rules.LinearV1
  }

  @spec fetch(String.t()) :: {:ok, module()} | {:error, :unknown_rule}
  def fetch(rule_id) when is_binary(rule_id) do
    case Map.fetch(all(), rule_id) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, :unknown_rule}
    end
  end

  @spec known?(String.t()) :: boolean()
  def known?(rule_id), do: match?({:ok, _}, fetch(rule_id))

  defp all do
    Map.merge(@builtin, Application.get_env(:coop_substrate, :extra_accrual_rules, %{}))
  end
end
