defmodule AgentCore.CapabilitiesTest do
  use ExUnit.Case, async: true
  alias AgentCore.Capabilities

  @profile %{
    "parameters" => %{
      "capabilities" => %{
        "features" => ~w(text tool_calls files),
        "data_classes" => ~w(public internal),
        "regions" => ~w(local us-east-1),
        "max_duration_ms" => 60_000,
        "max_output_bytes" => 8192
      }
    }
  }
  @req %{
    "features" => ["text"],
    "data_classes" => ["internal"],
    "region" => "us-east-1",
    "max_duration_ms" => 30_000,
    "max_output_bytes" => 4096
  }

  test "accepts a subset under the exact budgets and region" do
    assert :ok = Capabilities.check(@profile, @req)
    assert :ok =
             Capabilities.check(@profile, %{
               @req
               | "features" => ["text", "files"],
                 "max_duration_ms" => 60_000,
                 "max_output_bytes" => 8192
             })
  end

  test "rejects unsupported features, data classes and residency" do
    assert {:error, :unsupported_agent_feature} =
             Capabilities.check(@profile, %{@req | "features" => ["streaming"]})

    assert {:error, :data_class_not_allowed} =
             Capabilities.check(@profile, %{@req | "data_classes" => ["restricted"]})

    assert {:error, :agent_region_not_allowed} =
             Capabilities.check(@profile, %{@req | "region" => "eu-west-1"})
  end

  test "bounded duration and output size cannot exceed approved profile" do
    assert {:error, :agent_resource_budget_exceeded} =
             Capabilities.check(@profile, %{@req | "max_duration_ms" => 60_001})

    assert {:error, :agent_resource_budget_exceeded} =
             Capabilities.check(@profile, %{@req | "max_output_bytes" => 8193})
  end

  test "a missing, malformed or widened capability declaration fails closed" do
    profile = put_in(@profile, ["parameters", "capabilities", "data_classes"], [])
    assert {:error, :invalid_agent_capabilities} = Capabilities.check(profile, @req)

    profile = put_in(@profile, ["parameters", "capabilities", "features"], ["text", "text"])
    assert {:error, :invalid_agent_capabilities} = Capabilities.check(profile, @req)

    profile = put_in(@profile, ["parameters", "capabilities", "max_output_bytes"], "infinite")
    assert {:error, :invalid_agent_capabilities} = Capabilities.check(profile, @req)

    assert {:error, :invalid_agent_capabilities} =
             Capabilities.check(%{"parameters" => %{}}, @req)

    assert {:error, :invalid_agent_requirements} =
             Capabilities.check(@profile, Map.delete(@req, "region"))

    assert {:error, :invalid_agent_requirements} =
             Capabilities.check(@profile, Map.put(@req, "allow_all", true))

    assert {:error, :invalid_agent_requirements} =
             Capabilities.check(@profile, %{@req | "features" => ["text", "text"]})

    assert {:error, :invalid_agent_requirements} =
             Capabilities.check(@profile, %{@req | "max_duration_ms" => -1})

    assert {:error, :invalid_agent_requirements} =
             Capabilities.check(@profile, %{@req | "max_duration_ms" => 30.5})
  end

  test "provider or framework names are not a capability requirement" do
    assert :ok = Capabilities.check(@profile, @req)
    assert {:error, :unsupported_agent_feature} =
             Capabilities.check(@profile, %{@req | "features" => ["agent_vendor_specific"]})
  end
end
