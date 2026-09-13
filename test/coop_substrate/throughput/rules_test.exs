defmodule CoopSubstrate.Throughput.RulesTest do
  use ExUnit.Case, async: false

  alias CoopSubstrate.Throughput.Rules

  describe "fetch/1" do
    test "returns {:ok, module} for a known built-in rule" do
      assert {:ok, CoopSubstrate.Throughput.Rules.WeightedSumV1} = Rules.fetch("throughput-weighted-v1")
    end

    test "returns {:error, :unknown_rule} for an unknown rule" do
      assert {:error, :unknown_rule} = Rules.fetch("unknown-rule-id")
    end

    test "returns {:ok, module} for an injected extra rule" do
      Application.put_env(:coop_substrate, :extra_throughput_rules, %{
        "custom-test-rule" => CustomRuleModule
      })

      on_exit(fn ->
        Application.delete_env(:coop_substrate, :extra_throughput_rules)
      end)

      assert {:ok, CustomRuleModule} = Rules.fetch("custom-test-rule")
    end
  end

  describe "known?/1" do
    test "returns true for a known built-in rule" do
      assert Rules.known?("throughput-weighted-v1") == true
    end

    test "returns false for an unknown rule" do
      assert Rules.known?("unknown-rule-id") == false
    end
  end
end
