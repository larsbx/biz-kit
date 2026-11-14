defmodule TaskCore.ReadinessContractTest do
  @moduledoc """
  Immutable source/SOP bindings through the ordinary task-core admission path.
  The fixture host assumes signatures were verified, as TaskCore requires;
  these tests do not claim cryptographic signature or Git-source verification.
  """
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, Blueprint, Event, State, Steps}
  alias TaskCore.Blueprint.ReadinessContract

  defmodule Host do
    @behaviour TaskCore.Host

    def digest(bytes), do: :crypto.hash(:sha256, bytes)

    def put(bytes) do
      digest = digest(bytes)
      Process.put({__MODULE__, :artifact, digest}, bytes)
      digest
    end

    def blueprint(document) do
      digest = put(:erlang.term_to_binary(document))
      Process.put({__MODULE__, :blueprint, digest}, document)
      digest
    end

    @impl true
    def read_blueprint(digest) do
      reject_replay_read!()

      case Process.get({__MODULE__, :blueprint, digest}) do
        nil -> {:error, :not_found}
        document -> {:ok, document}
      end
    end

    @impl true
    def verify_artifact(digest, limit) do
      reject_replay_read!()

      case Process.get({__MODULE__, :artifact, digest}) do
        nil ->
          {:error, :not_found}

        bytes when byte_size(bytes) > limit ->
          {:error, :too_large}

        bytes ->
          if digest(bytes) == digest,
            do: {:ok, byte_size(bytes)},
            else: {:error, :artifact_tampered}
      end
    end

    @impl true
    def hash(term), do: digest(:erlang.term_to_binary(term))

    defp reject_replay_read! do
      if Process.get({__MODULE__, :reject_reads}), do: raise("replay performed an artifact read")
    end
  end

  @scope {"cooperative", "company", "bizops"}
  @where %{"tenant_id" => "company", "project_id" => "bizops"}
  @governance %{key_id: "governance-key", pubkey: "governance-public-key"}
  @operator %{key_id: "operator-key", pubkey: "operator-public-key"}
  @actor %{
    "principal_id" => "operator",
    "authorization_event_id" => "operator-grant",
    "lifecycle_version" => 1
  }
  @inputs ~w(source_24_12 source_24_12d workflow_manifest)
  @sop "Pinned two-source SOP bundle, version 1.0.0"
  @source_a "Exact source 24.12"
  @source_b "Exact source 24.12d"

  setup do
    world = %{
      state: State.init(Host),
      keys: %{{"cooperative", "governance"} => %{"governance-key" => "governance-public-key"}},
      events: []
    }

    world =
      world
      |> fold!(
        event(
          "TaskOperatorGrantedV1",
          %{
            "principal_id" => "operator",
            "key_id" => @operator.key_id,
            "pubkey" => {:bytes, @operator.pubkey}
          },
          @governance,
          "operator-grant"
        )
      )
      |> fold!(%Event{
        event_id: "human",
        chapter_id: "cooperative",
        type: "TaskPrincipalKindDeclaredV1",
        payload: %{"principal_id" => "operator", "kind" => "human"},
        signers: [@governance]
      })
      |> fold!(event("TaskProjectOwnerAssignedV1", %{"principal_id" => "operator"}))

    for bytes <- [@sop, @source_a, @source_b], do: Host.put(bytes)
    %{world: world}
  end

  test "schema 2 retains a strict contract and requires all inputs on every task" do
    assert {:ok, normalized} = Blueprint.normalize(document())
    assert get_in(normalized, workflow_path() ++ ["readiness_contract"]) == contract()
    assert {:ok, ^normalized} = Blueprint.normalize(normalized)

    for requirements <- [
          [],
          ["source_24_12", "workflow_manifest"],
          @inputs ++ ["other"],
          @inputs ++ ["source_24_12"]
        ] do
      changed =
        put_in(
          document(),
          workflow_path() ++ ["tasks", Access.at(1), "artifact_requirements"],
          requirements
        )

      assert {:error, _} = Blueprint.normalize(changed)
    end

    reordered =
      put_in(
        document(),
        workflow_path() ++ ["tasks", Access.at(1), "artifact_requirements"],
        Enum.reverse(@inputs)
      )

    assert {:ok, _} = Blueprint.normalize(reordered)
  end

  test "unknown fields, collisions, malformed versions, digests and oversized source maps refuse" do
    base = contract()

    invalid =
      [
        nil,
        %{},
        Map.delete(base, "sop_version"),
        Map.put(base, "schema_version", 2),
        Map.put(base, "schema_version", 1.0),
        Map.put(base, "permission", "execute"),
        Map.put(base, "manifest_input", "another_manifest"),
        Map.put(base, "sop_digest", String.duplicate("A", 64)),
        Map.put(base, "sop_digest", String.duplicate("a", 65)),
        Map.put(base, "input_digests", %{}),
        Map.put(base, "input_digests", %{"workflow_manifest" => hex(@source_a)}),
        Map.put(base, "input_digests", %{"Source" => hex(@source_a)}),
        Map.put(base, "input_digests", %{"source" => "bad"}),
        Map.put(base, "input_digests", Map.new(1..32, &{"source_#{&1}", hex(@source_a)}))
      ] ++
        Enum.map(
          ["1.0", "01.0.0", "1.0.0-rc", "1.0.0+build", "1000000000.0.0", nil],
          &Map.put(base, "sop_version", &1)
        )

    for value <- invalid do
      assert {:error, _} =
               Blueprint.normalize(
                 put_in(document(), workflow_path() ++ ["readiness_contract"], value)
               )
    end

    bounded = Map.put(base, "input_digests", Map.new(1..31, &{"source_#{&1}", hex(@source_a)}))
    assert {:ok, ^bounded} = ReadinessContract.normalize(bounded)
  end

  test "generic readiness admission cannot replace either source, the SOP, version or adopted manifest",
       %{world: world} do
    {world, adoption} = adopt!(world, document(), "a")

    assert world.state.blueprints[adoption.event_id].readiness_contracts[{"offices", "office"}].artifact_requirements[
             "workflow_manifest"
           ] == adoption.payload["manifest_digest"]

    world = run!(world, adoption, "one") |> propose_run!("one")
    definition = definition(world, "one-scope", adoption.payload["manifest_digest"])
    assert admit(world, definition) == :ok

    changed =
      [
        put_in(definition.payload["sop_digest"], {:bytes, Host.digest("another SOP")}),
        put_in(definition.payload["sop_version"], "1.1.0"),
        %{definition | payload: Map.delete(definition.payload, "sop_version")}
      ] ++
        Enum.map(@inputs, fn name ->
          put_in(
            definition.payload["artifact_requirements"][name],
            {:bytes, Host.digest("replacement #{name}")}
          )
        end)

    for attempted <- changed do
      assert admit(world, attempted) == {:error, :blueprint_readiness_contract_mismatch}
    end

    assert admit(world, %{definition | signers: [@operator]}) ==
             {:error, :task_governance_not_declared}

    world = fold!(world, definition)

    assert world.state.tasks[key("one-scope")].readiness.artifact_requirements == %{
             "source_24_12" => {:bytes, Host.digest(@source_a)},
             "source_24_12d" => {:bytes, Host.digest(@source_b)},
             "workflow_manifest" => adoption.payload["manifest_digest"]
           }
  end

  test "later adoption cannot replace the contract or manifest of an existing run; replay reads no source",
       %{world: world} do
    {world, first} = adopt!(world, document(), "a")
    world = run!(world, first, "one") |> propose_run!("one")
    world = fold!(world, definition(world, "one-scope", first.payload["manifest_digest"]))

    next = put_in(document(), ["project", "name"], "Office operations, reviewed again")
    {world, second} = adopt!(world, next, "b")
    refute second.payload["manifest_digest"] == first.payload["manifest_digest"]
    world = run!(world, second, "two") |> propose_run!("two")

    assert admit(world, definition(world, "one-handoff", second.payload["manifest_digest"])) ==
             {:error, :blueprint_readiness_contract_mismatch}

    assert admit(world, definition(world, "two-scope", first.payload["manifest_digest"])) ==
             {:error, :blueprint_readiness_contract_mismatch}

    world =
      world
      |> fold!(definition(world, "one-handoff", first.payload["manifest_digest"]))
      |> fold!(definition(world, "two-scope", second.payload["manifest_digest"]))

    Process.put({Host, :reject_reads}, true)
    replay = Enum.reduce(world.events, State.init(Host), &State.handle_event/2)
    assert replay == world.state

    assert replay.tasks[key("one-scope")].blueprint.readiness_contract.artifact_requirements[
             "workflow_manifest"
           ] == first.payload["manifest_digest"]

    assert replay.tasks[key("two-scope")].blueprint.readiness_contract.artifact_requirements[
             "workflow_manifest"
           ] == second.payload["manifest_digest"]
  end

  test "custody, SOP acknowledgement and predecessors still gate a contracted run", %{
    world: world
  } do
    {world, adoption} = adopt!(world, document(), "a")
    world = run!(world, adoption, "one") |> propose_run!("one")

    world =
      Enum.reduce(~w(one-scope one-handoff), world, fn id, acc ->
        fold!(acc, definition(acc, id, adoption.payload["manifest_digest"]))
      end)

    artifacts = %{
      "sop" => {:bytes, Host.digest(@sop)},
      "source_24_12" => {:bytes, Host.digest(@source_a)},
      "source_24_12d" => {:bytes, Host.digest(@source_b)},
      "workflow_manifest" => adoption.payload["manifest_digest"]
    }

    world =
      Enum.reduce(artifacts, world, fn {name, {:bytes, digest}}, acc ->
        step!(acc, {:record_custody, digest}, "receipt-#{name}")
      end)

    receipts = Map.new(@inputs, &{&1, "receipt-#{&1}"})

    assert admit(world, prepare(world, {:queue, "one-scope"})) ==
             {:error, :sop_acknowledgment_required}

    world =
      Enum.reduce(~w(one-scope one-handoff), world, fn id, acc ->
        acc |> step!({:acknowledge_sop, id, "receipt-sop"}) |> step!({:queue, id})
      end)

    assert admit(world, prepare(world, {:ready, "one-handoff", receipts})) ==
             {:error, :incomplete_predecessors}

    wrong = Map.put(receipts, "source_24_12d", "receipt-source_24_12")

    assert admit(world, prepare(world, {:ready, "one-scope", wrong})) ==
             {:error, :custody_digest_mismatch}

    world = step!(world, {:ready, "one-scope", receipts})

    Process.put({Host, :artifact, Host.digest(@source_b)}, "tampered source")
    assert admit(world, prepare(world, {:start, "one-scope"})) == {:error, :artifact_tampered}
    assert world.state.tasks[key("one-scope")].state == "ready"
  end

  test "schema-2 workflows without the optional contract retain prior readiness behavior", %{
    world: world
  } do
    legacy = update_in(document(), workflow_path(), &Map.delete(&1, "readiness_contract"))
    assert {:ok, normalized} = Blueprint.normalize(legacy)
    refute Map.has_key?(get_in(normalized, workflow_path()), "readiness_contract")
    {world, adoption} = adopt!(world, legacy, "a")
    world = run!(world, adoption, "one") |> propose_run!("one")
    refute Map.has_key?(world.state.tasks[key("one-scope")].blueprint, :readiness_contract)
    arbitrary = definition(world, "one-scope", {:bytes, Host.digest("other manifest")})
    arbitrary = put_in(arbitrary.payload["sop_digest"], {:bytes, Host.digest("other SOP")})
    assert admit(world, arbitrary) == :ok
  end

  defp contract do
    %{
      "schema_version" => 1,
      "sop_digest" => hex(@sop),
      "sop_version" => "1.0.0",
      "input_digests" => %{"source_24_12" => hex(@source_a), "source_24_12d" => hex(@source_b)},
      "manifest_input" => "workflow_manifest"
    }
  end

  defp document do
    tasks =
      for {id, predecessors} <- [{"scope", []}, {"handoff", ["scope"]}] do
        %{
          "id" => id,
          "title" => id,
          "definition_of_done" => [%{"id" => "evidence", "description" => "Reviewed evidence"}],
          "depends_on" => predecessors,
          "artifact_requirements" => @inputs
        }
      end

    %{
      "schema_version" => 2,
      "project" => %{"key" => "bizops", "name" => "Office operations"},
      "roadmaps" => [
        %{
          "key" => "offices",
          "name" => "Offices",
          "workflows" => [
            %{
              "id" => "office",
              "name" => "Office engagement",
              "tasks" => tasks,
              "readiness_contract" => contract()
            }
          ]
        }
      ]
    }
  end

  defp adopt!(world, document, commit_char) do
    {:ok, normalized} = Blueprint.normalize(document)

    adoption =
      event("TaskBlueprintAppliedV1", %{
        "repository" => "fixture/workflows",
        "commit" => String.duplicate(commit_char, 40),
        "tree" => String.duplicate("c", 40),
        "path" => "workflows/office.json",
        "manifest_digest" => {:bytes, Host.blueprint(document)},
        "blueprint" => normalized
      })

    {fold!(world, adoption), adoption}
  end

  defp run!(world, adoption, prefix),
    do:
      step!(
        world,
        {:instantiate, adoption.event_id, "offices", "office",
         %{"scope" => "#{prefix}-scope", "handoff" => "#{prefix}-handoff"}}
      )

  defp propose_run!(world, prefix),
    do:
      Enum.reduce(~w(scope handoff), world, fn id, acc ->
        step!(acc, {:propose, "#{prefix}-#{id}"})
      end)

  defp definition(world, id, manifest) do
    task = world.state.tasks[key(id)]

    event("TaskReadinessDefinedV1", %{
      "task_id" => id,
      "expected_version" => task.version,
      "artifact_requirements" => %{
        "source_24_12" => {:bytes, Host.digest(@source_a)},
        "source_24_12d" => {:bytes, Host.digest(@source_b)},
        "workflow_manifest" => manifest
      },
      "predecessor_ids" => task.blueprint.predecessor_ids,
      "sop_digest" => {:bytes, Host.digest(@sop)},
      "sop_version" => "1.0.0"
    })
  end

  defp prepare(world, action, id \\ nil) do
    {:ok, type, payload} = Steps.command(world.state, @scope, action, @actor)
    event(type, payload, @operator, id)
  end

  defp step!(world, action, id \\ nil), do: fold!(world, prepare(world, action, id))

  defp admit(world, event),
    do: Admission.check(event, %{orchestration: world.state, role_keys: world.keys})

  defp fold!(world, event) do
    assert admit(world, event) == :ok, "#{event.type} refused"
    %{world | state: State.handle_event(event, world.state), events: world.events ++ [event]}
  end

  defp event(type, payload, signer \\ @governance, id \\ nil),
    do: %Event{
      event_id: id || "event-#{System.unique_integer([:positive])}",
      chapter_id: "cooperative",
      type: type,
      payload: Map.merge(@where, payload),
      signers: [signer]
    }

  defp key(id), do: Tuple.insert_at(@scope, 3, id)
  defp workflow_path, do: ["roadmaps", Access.at(0), "workflows", Access.at(0)]
  defp hex(bytes), do: bytes |> Host.digest() |> Base.encode16(case: :lower)
end
