defmodule CoopSubstrate.Floor.Rules do
  @moduledoc """
  The code registry of floor-rule implementations, mirroring
  `CoopSubstrate.Capital.AccrualRules`. A rule becomes *active* only via a
  gated in-log `FloorRuleActivated` event.

  Tests may inject rules via the `:extra_floor_rules` application env.
  """

  @builtin %{
    "floor-threshold-v1" => CoopSubstrate.Floor.Rules.ThresholdV1
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
    Map.merge(@builtin, Application.get_env(:coop_substrate, :extra_floor_rules, %{}))
  end
end
