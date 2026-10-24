defmodule AgentCore.PreflightTest do
  use ExUnit.Case, async: true

  alias AgentCore.Preflight

  defmodule LocalAdapter do
    @behaviour AgentCore.ExecutionPort
    def launch(_, _, _), do: {:ok, %{id: "local"}}
    def poll(_), do: {:ok, %{state: :succeeded}}
    def cancel(_, _), do: :ok
  end

  defmodule RemoteAdapter do
    @behaviour AgentCore.ExecutionPort
    def launch(_, _, _), do: {:ok, %{id: "remote"}}
    def poll(_), do: {:ok, %{state: :succeeded}}
    def cancel(_, _), do: :ok
  end

  @ticket %{
    "chapter_id" => "chapter1",
    "tenant_id" => "tenant1",
    "project_id" => "project1",
    "task_id" => "task1",
    "task_version" => 3,
    "source_event_id" => "source1",
    "definition_digest" => String.duplicate("a", 64)
  }

  @requirements %{
    "features" => ["text"],
    "data_classes" => ["internal"],
    "region" => "us-east-1",
    "max_duration_ms" => 30_000,
    "max_output_bytes" => 4096
  }

  defp hash_manifest(manifest), do: :crypto.hash(:sha256, :erlang.term_to_binary(manifest))

  defp profile(id, adapter, backend) do
    %{
      id: id,
      approved: true,
      adapter: adapter,
      manifest: %{
        "id" => id,
        "version" => 1,
        "adapter_module" => Atom.to_string(adapter),
        "parameters" => %{
          "backend" => backend,
          "capabilities" => %{
            "features" => ["text", "tool_calls"],
            "data_classes" => ["public", "internal"],
            "regions" => ["local", "us-east-1"],
            "max_duration_ms" => 60_000,
            "max_output_bytes" => 8192
          }
        }
      }
    }
  end

  defp registry do
    %{
      "local" => profile("local", LocalAdapter, "local-worker"),
      "remote" => profile("remote", RemoteAdapter, "remote-service")
    }
  end

  defp run(profile_id, entries) do
    %{
      run_id: "run1",
      intent_event_id: "signed1",
      ticket: @ticket,
      execution_profile_id: profile_id,
      execution_profile_digest: {:bytes, hash_manifest(entries[profile_id].manifest)},
      max_duration_ms: 30_000,
      max_output_bytes: 4096
    }
  end

  defp plan(r, entries \\ registry(), requirements \\ @requirements),
    do: Preflight.prepare(r, entries, &hash_manifest/1, requirements)

  test "local and remote worker produce the same engine-neutral execution contract" do
    entries = registry()
    assert {:ok, local} = plan(run("local", entries), entries)
    assert {:ok, remote} = plan(run("remote", entries), entries)

    assert local.adapter == LocalAdapter
    assert remote.adapter == RemoteAdapter
    assert local.execution == remote.execution
    assert local.effect_id == remote.effect_id
    assert local.effect_id == "agent-run:signed1"
    assert local.requirements == @requirements
    assert local.profile.manifest["parameters"]["backend"] == "local-worker"
    assert remote.profile.manifest["parameters"]["backend"] == "remote-service"
  end

  test "run ID and source are trusted inputs, never an optional default" do
    entries = registry()
    r = run("local", entries)

    assert {:error, :invalid_agent_run_preflight} =
             plan(%{r | run_id: "../escape"}, entries)

    assert {:error, :invalid_agent_run_preflight} =
             plan(%{r | ticket: Map.put(@ticket, "execute", true)}, entries)

    assert {:error, :invalid_agent_run_preflight} =
             plan(%{r | ticket: Map.put(@ticket, "definition_digest", "AB")}, entries)

    assert {:error, :invalid_agent_run_preflight} =
             plan(%{r | ticket: Map.put(@ticket, "task_version", true)}, entries)
  end

  test "signed run ceilings must exactly bind trusted requested budgets" do
    entries = registry()
    r = run("local", entries)

    assert {:error, :agent_budget_not_bound_to_intent} =
             plan(r, entries, %{@requirements | "max_duration_ms" => 45_000})

    assert {:error, :agent_budget_not_bound_to_intent} =
             plan(r, entries, %{@requirements | "max_output_bytes" => 5000})
  end

  test "capability or profile drift refuses a launch plan" do
    entries = registry()
    r = run("remote", entries)

    assert {:error, :unsupported_agent_feature} =
             plan(r, entries, %{@requirements | "features" => ["streaming"]})

    assert {:error, :agent_region_not_allowed} =
             plan(r, entries, %{@requirements | "region" => "eu-central"})

    changed =
      put_in(
        entries,
        ["remote", :manifest, "parameters", "capabilities", "regions"],
        ["unrestricted"]
      )

    assert {:error, :execution_profile_digest_mismatch} =
             plan(r, changed)
  end

  test "profile adapter cannot change under the same digest" do
    entries = registry()
    r = run("local", entries)
    swapped = put_in(entries, ["local", :adapter], RemoteAdapter)
    assert {:error, :execution_profile_adapter_mismatch} = plan(r, swapped)
  end
end
