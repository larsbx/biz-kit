defmodule CoopSubstrate.Throughput.Rules do
  @moduledoc """
  The code registry of throughput-rule implementations, mirroring
  `CoopSubstrate.Capital.AccrualRules` (docs/phase1c_plan.md: three small
  parallel registries, no shared rule framework). A rule becomes *active*
  only via a gated in-log `ThroughputRuleActivated` event.

  Tests may inject rules via the `:extra_throughput_rules` application env.
  """

  @builtin %{
    "throughput-weighted-v1" => CoopSubstrate.Throughput.Rules.WeightedSumV1
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
    Map.merge(@builtin, Application.get_env(:coop_substrate, :extra_throughput_rules, %{}))
  end
end
