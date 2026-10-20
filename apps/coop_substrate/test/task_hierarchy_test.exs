defmodule CoopSubstrate.TaskHierarchyTest do
  @moduledoc """
  Blueprints on the ledger (docs/architecture/2026-10-20-hierarchy-and-blueprints.md):
  governance applies the YAML bytes held in the custody store; an operator
  runs a workflow; replay rebuilds both from the ledger alone.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Commands, Crypto, Log, RunReadiness}
  alias CoopSubstrate.Projections.Tasks, as: Projection

  @key {"chapter-genesis", "tenant-1", "project-1"}

  setup do
    gov = new_member("governance")
    laptop = new_member("operator")

    {:ok, [_, grant]} =
      Log.append([declare_governance(gov), operator_grant(gov, laptop, "alice")])

    %{gov: gov, laptop: laptop, grant: grant}
  end

  # Unique per run: the artifact store outlives a test run.
  defp yaml(extra \\ "") do
    """
    # run #{System.unique_integer()} #{System.system_time()}
    schema_version: 2
    project: {key: project-1, name: Launch}
    roadmaps:
      - key: q4
        name: Fourth quarter
        workflows:
          - id: release
            name: Release
            tasks:
              - id: build
                title: Build the release
                definition_of_done:
                  - {id: artifact, description: The signed artifact}
                artifact_requirements: [source]
              - id: announce
                title: Announce it
                definition_of_done: [{id: post, description: The announcement}]
                depends_on: [build]
    #{extra}
    """
  end

  defp applied(gov, bytes, commit \\ String.duplicate("a", 40)) do
    digest = store!(bytes)
    {:ok, decoded} = YamlElixir.read_from_string(bytes)
    {:ok, blueprint} = TaskCore.Blueprint.normalize(decoded)

    signed_event(gov, "TaskBlueprintAppliedV1", %{
      "tenant_id" => "tenant-1",
      "project_id" => "project-1",
      "repository" => "acme/plans",
      "commit" => commit,
      "tree" => String.duplicate("b", 40),
      "path" => "launch.yaml",
      "manifest_digest" => {:bytes, digest},
      "blueprint" => blueprint
    })
  end

  defp run(laptop, grant, revision, ids) do
    signed_event(
      laptop,
      "TaskWorkflowInstantiatedV1",
      Map.merge(actor(grant), %{
        "tenant_id" => "tenant-1",
        "project_id" => "project-1",
        "revision_event_id" => revision,
        "roadmap_key" => "q4",
        "workflow_id" => "release",
        "task_ids" => ids
      })
    )
  end

  test "a blueprint applied from custody, a workflow run, and replay agree", w do
    {:ok, [revision]} = Log.append(applied(w.gov, yaml()))
    ids = %{"build" => "build-1", "announce" => "announce-1"}
    {:ok, [_]} = Log.append(run(w.laptop, w.grant, revision.event_id, ids))

    o = Log.gate().orchestration
    assert o.hierarchy[@key].roadmaps["q4"].workflows["release"].revision == revision.event_id

    assert %{state: "inbox", title: "Announce it", blueprint: %{predecessor_ids: ["build-1"]}} =
             o.tasks[{"chapter-genesis", "tenant-1", "project-1", "announce-1"}]

    assert {:ok, ^o} = Log.replay(Projection)
  end

  test "the ledger refuses bytes it does not hold, unparsable YAML, and a second apply", w do
    event = applied(w.gov, yaml())
    missing = put_in(event.payload["manifest_digest"], {:bytes, :crypto.hash(:sha256, "none")})

    assert {:error, {:reject, 0, :not_found}} =
             Log.append(signed_event(w.gov, "TaskBlueprintAppliedV1", missing.payload))

    garbage = store!("schema_version: [unclosed #{System.unique_integer()}")
    broken = Map.put(event.payload, "manifest_digest", {:bytes, garbage})

    assert {:error, {:reject, 0, :blueprint_not_yaml}} =
             Log.append(signed_event(w.gov, "TaskBlueprintAppliedV1", broken))

    {:ok, _} = Log.append(event)

    assert {:error, {:reject, 0, :blueprint_already_applied}} =
             Log.append(applied(w.gov, yaml("# again")))
  end

  test "an operator's device prepares, signs and submits a run", w do
    {:ok, [revision]} = Log.append(applied(w.gov, yaml()))
    ids = %{"build" => "build-2", "announce" => "announce-2"}
    action = {:instantiate, revision.event_id, "q4", "release", ids}
    scope = {"chapter-genesis", "tenant-1", "project-1"}

    {:ok, pending} = Commands.prepare("alice", w.laptop.signer.key_id, scope, action)

    {:ok, _} =
      Commands.submit("alice", pending.id, Crypto.sign(pending.signing_bytes, w.laptop.seed))

    assert %{state: "inbox"} =
             Log.gate().orchestration.tasks[Tuple.insert_at(scope, 3, "build-2")]

    # The same run again names tasks that now exist: refused before signing.
    assert {:error, {:invalid, :task_exists}} =
             Commands.prepare("alice", w.laptop.signer.key_id, scope, action)
  end

  describe "readiness for a run (2026-10-20-run-readiness.md)" do
    setup w do
      {:ok, [revision]} = Log.append(applied(w.gov, yaml()))
      ids = %{"build" => "build-r", "announce" => "announce-r"}
      {:ok, [run]} = Log.append(run(w.laptop, w.grant, revision.event_id, ids))
      %{run: run.event_id}
    end

    defp key(id), do: {"chapter-genesis", "tenant-1", "project-1", id}

    defp propose!(w, id) do
      version = Log.gate().orchestration.tasks[key(id)].version
      {:ok, _} = Log.append(propose(w.laptop, w.grant, id, version))
    end

    defp sign_all(w, held) do
      for c <- held.commands, do: Crypto.sign(c.signing_bytes, w.gov.seed)
    end

    @sop :crypto.hash(:sha256, "the run's SOP")
    @source :crypto.hash(:sha256, "source tarball")
    @scope {"chapter-genesis", "tenant-1", "project-1"}

    test "governance defines every waiting task of a run in one signed batch", w do
      # Nothing waits until a task is proposed: inbox tasks cannot be readied.
      assert RunReadiness.prepare(@scope, w.run, @sop, %{}, w.gov.signer.key_id) ==
               {:error, :nothing_to_define}

      propose!(w, "build-r")
      propose!(w, "announce-r")

      # Build requires the "source" input; its digest must be given.
      assert RunReadiness.prepare(@scope, w.run, @sop, %{}, w.gov.signer.key_id) ==
               {:error, :missing_input}

      inputs = %{"build-r" => %{"source" => @source}}
      {:ok, held} = RunReadiness.prepare(@scope, w.run, @sop, inputs, w.gov.signer.key_id)
      assert Enum.map(held.commands, & &1.payload["task_id"]) == ["announce-r", "build-r"]

      {:ok, [_, _]} = RunReadiness.define(@scope, w.run, held.id, sign_all(w, held))

      o = Log.gate().orchestration
      assert o.tasks[key("announce-r")].readiness.predecessor_ids == ["build-r"]

      assert o.tasks[key("build-r")].readiness.artifact_requirements == %{
               "source" => {:bytes, @source}
             }

      assert o.tasks[key("build-r")].readiness.sop_digest == {:bytes, @sop}

      # Defined: nothing left to define for this run.
      assert RunReadiness.prepare(@scope, w.run, @sop, inputs, w.gov.signer.key_id) ==
               {:error, :nothing_to_define}
    end

    test "a later batch, for tasks proposed later, must name the run's SOP", w do
      propose!(w, "build-r")
      inputs = %{"build-r" => %{"source" => @source}}
      {:ok, held} = RunReadiness.prepare(@scope, w.run, @sop, inputs, w.gov.signer.key_id)
      {:ok, [_]} = RunReadiness.define(@scope, w.run, held.id, sign_all(w, held))

      propose!(w, "announce-r")
      other = :crypto.hash(:sha256, "another SOP")

      assert RunReadiness.prepare(@scope, w.run, other, %{}, w.gov.signer.key_id) ==
               {:error, :sop_mismatch}

      {:ok, held} = RunReadiness.prepare(@scope, w.run, @sop, %{}, w.gov.signer.key_id)
      assert [%{payload: %{"task_id" => "announce-r"}}] = held.commands
    end

    test "a run's SOP version is kept by every later batch", w do
      propose!(w, "build-r")
      inputs = %{"build-r" => %{"source" => @source}}
      gov_key = w.gov.signer.key_id
      {:ok, held} = RunReadiness.prepare(@scope, w.run, @sop, inputs, gov_key, "1.4.0")
      assert [%{payload: %{"sop_version" => "1.4.0"}}] = held.commands
      {:ok, [_]} = RunReadiness.define(@scope, w.run, held.id, sign_all(w, held))

      propose!(w, "announce-r")
      assert RunReadiness.prepare(@scope, w.run, @sop, %{}, gov_key) == {:error, :sop_mismatch}

      assert RunReadiness.prepare(@scope, w.run, @sop, %{}, gov_key, "1.5.0") ==
               {:error, :sop_mismatch}

      {:ok, held} = RunReadiness.prepare(@scope, w.run, @sop, %{}, gov_key, "1.4.0")
      {:ok, [_]} = RunReadiness.define(@scope, w.run, held.id, sign_all(w, held))
      assert Log.gate().orchestration.tasks[key("announce-r")].readiness.sop_version == "1.4.0"
    end

    test "only governance keys sign, and a batch belongs to its run", w do
      propose!(w, "announce-r")

      assert RunReadiness.prepare(@scope, w.run, @sop, %{}, w.laptop.signer.key_id) ==
               {:error, :unknown_governance_key}

      {:ok, held} = RunReadiness.prepare(@scope, w.run, @sop, %{}, w.gov.signer.key_id)

      assert {:error, _} =
               RunReadiness.define(@scope, "another-run", held.id, sign_all(w, held))
    end
  end

  test "a retried run returns its original acknowledgement", w do
    {:ok, [revision]} = Log.append(applied(w.gov, yaml()))
    command = run(w.laptop, w.grant, revision.event_id, %{"build" => "b", "announce" => "a"})
    {:ok, [accepted]} = Log.append(command)
    assert {:ok, [^accepted]} = Log.append(command)
  end
end
