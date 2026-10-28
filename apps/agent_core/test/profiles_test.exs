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

  # The actual biz-kit host must supply CoopSubstrate.Canonical.hash!/1, not
  # this test's local digest. It verifies manifest immutability as a behavior,
  # but does not make the test's representation the platform signing profile.
  defp hash_manifest(manifest), do: :crypto.hash(:sha256, :erlang.term_to_binary(manifest))

  defp manifest(id, adapter, params) do
    %{
      "id" => id,
      "version" => 1,
      "adapter_module" => Atom.to_string(adapter),
      "parameters" => params
    }
  end

  defp profile(id, adapter, parameters) do
    %{id: id, approved: true, adapter: adapter, manifest: manifest(id, adapter, parameters)}
  end

  defp registry do
    %{
      "standard" =>
        profile("standard", SandboxAdapter, %{
          "backend" => "sandbox",
          "policy" => "sandbox-policy-v1"
        }),
      "hosted" =>
        profile("hosted", HostedAdapter, %{
          "backend" => "hosted",
          "endpoint_alias" => "approved-hosted-agent"
        })
    }
  end

  defp ref(registry, id) do
    %{
      execution_profile_id: id,
      execution_profile_digest: {:bytes, hash_manifest(registry[id].manifest)}
    }
  end

  defp resolve(run, profiles), do: Profiles.resolve(run, profiles, &hash_manifest/1)

  test "same engine-neutral run type accepts two genuinely different adapter contracts" do
    entries = registry()

    assert {:ok, %{adapter: SandboxAdapter}} =
             resolve(ref(entries, "standard"), entries)

    assert {:ok, %{adapter: HostedAdapter}} =
             resolve(ref(entries, "hosted"), entries)
  end

  test "changing runtime parameters without a new signed digest refuses a run" do
    entries = registry()
    original = ref(entries, "standard")
    modified = put_in(entries, ["standard", :manifest, "parameters", "policy"], "allow-all")

    assert {:error, :execution_profile_digest_mismatch} =
             resolve(original, modified)
  end

  test "unapproved or unknown execution profile is refused" do
    entries = registry()
    run = ref(entries, "standard")
    disabled = put_in(entries, ["standard", :approved], false)

    assert {:error, :execution_profile_not_approved} =
             resolve(run, disabled)

    assert {:error, :execution_profile_not_found} =
             resolve(%{run | execution_profile_id: "other"}, entries)
  end

  test "no arbitrary runtime module, executable configuration or hash bypass" do
    entries = registry()
    run = ref(entries, "standard")

    assert {:error, :invalid_execution_adapter} =
             resolve(run, put_in(entries, ["standard", :adapter], "Some.Module"))

    assert {:error, :invalid_execution_profile_manifest} =
             resolve(run, put_in(entries, ["standard", :manifest], %{bad: :shape}))

    assert {:error, :execution_profile_hash_unavailable} =
             Profiles.resolve(run, entries, fn _ -> :not_a_digest end)

    assert {:error, :execution_profile_hash_unavailable} =
             Profiles.resolve(run, entries, fn _ -> raise "unavailable" end)

    assert {:error, :invalid_execution_profile_reference} =
             resolve(%{execution_profile_id: "standard"}, entries)
  end

  test "adapter replacement without a new signed profile digest is refused" do
    entries = registry()
    run = ref(entries, "standard")
    swapped = put_in(entries, ["standard", :adapter], HostedAdapter)

    assert {:error, :execution_profile_adapter_mismatch} =
             resolve(run, swapped)
  end
end
