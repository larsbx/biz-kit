defmodule AgentCore.ProfilesTest do
  use ExUnit.Case, async: true

  alias AgentCore.Profiles

  defmodule SandboxAdapter do
    @behaviour AgentCore.ExecutionPort
    def launch(_, _, _), do: {:ok, %{backend: :sandbox}}
    def poll(_), do: {:ok, %{state: :running}}
    def cancel(_, _), do: :ok
  end

  defmodule HostedAdapter do
    @behaviour AgentCore.ExecutionPort
    def launch(_, _, _), do: {:ok, %{backend: :hosted}}
    def poll(_), do: {:ok, %{state: :succeeded, candidate_ref: "ref"}}
    def cancel(_, _), do: :ok
  end

  @one {:bytes, <<1::256>>}
  @two {:bytes, <<2::256>>}

  defp registry do
    %{
      "standard" => %{
        id: "standard",
        digest: @one,
        approved: true,
        adapter: SandboxAdapter,
        parameters: %{sandbox: %{policy: "sandbox-policy-v1"}}
      },
      "hosted" => %{
        id: "hosted",
        digest: @two,
        approved: true,
        adapter: HostedAdapter,
        parameters: %{service: %{endpoint_alias: "approved-hosted-agent"}}
      }
    }
  end

  test "same engine-neutral run shape supports distinct adapter implementations" do
    assert {:ok, %{adapter: SandboxAdapter}} =
             Profiles.resolve(
               %{execution_profile_id: "standard", execution_profile_digest: @one},
               registry()
             )

    assert {:ok, %{adapter: HostedAdapter}} =
             Profiles.resolve(
               %{execution_profile_id: "hosted", execution_profile_digest: @two},
               registry()
             )
  end

  test "profile replacement or unapproved profile fails closed" do
    run = %{execution_profile_id: "standard", execution_profile_digest: @one}
    rotated = put_in(registry(), ["standard", :digest], @two)

    assert {:error, :execution_profile_digest_mismatch} =
             Profiles.resolve(run, rotated)

    disabled = put_in(registry(), ["standard", :approved], false)

    assert {:error, :execution_profile_not_approved} =
             Profiles.resolve(run, disabled)
  end

  test "unknown and incomplete profiles fail closed" do
    assert {:error, :execution_profile_not_found} =
             Profiles.resolve(
               %{execution_profile_id: "other", execution_profile_digest: @one},
               registry()
             )

    run = %{execution_profile_id: "standard", execution_profile_digest: @one}

    assert {:error, :invalid_execution_adapter} =
             Profiles.resolve(run, put_in(registry(), ["standard", :adapter], "SandboxAdapter"))

    assert {:error, :invalid_execution_profile_parameters} =
             Profiles.resolve(run, put_in(registry(), ["standard", :parameters], nil))

    assert {:error, :invalid_execution_profile_reference} =
             Profiles.resolve(%{execution_profile_id: nil}, registry())
  end
end
