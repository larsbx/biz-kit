defmodule TaskCore.KnowledgeTest do
  @moduledoc """
  Project knowledge over admitted task/workflow facts. The fixture host assumes
  event signatures were verified; real signature and HTTP acceptance is hosted
  by TaskHost. No evidence body becomes generated knowledge.
  """
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, Blueprint, Event, Knowledge, State, Steps}

  defmodule Host do
    @behaviour TaskCore.Host

    def hash(term), do: digest(:erlang.term_to_binary(term))
    def digest(bytes), do: :crypto.hash(:sha256, bytes)

    def put(bytes) do
      digest = digest(bytes)
      Process.put({__MODULE__, digest}, bytes)
      digest
    end

    def put_blueprint(document) do
      digest = put(:erlang.term_to_binary(document))
      Process.put({__MODULE__, :blueprint, digest}, document)
      digest
    end

    def verify_artifact(digest, limit) do
      if Process.get({__MODULE__, :no_reads}), do: raise("unexpected artifact read")

      case Process.get({__MODULE__, digest}) do
        nil ->
          {:error, :not_found}

        bytes when byte_size(bytes) > limit ->
          {:error, :too_large}

        bytes ->
          if digest(bytes) == digest, do: {:ok, byte_size(bytes)}, else: {:error, :tampered}
      end
    end

    def read_blueprint(digest) do
      with {:ok, _} <- verify_artifact(digest, 1_048_576),
           document when is_map(document) <- Process.get({__MODULE__, :blueprint, digest}),
           do: {:ok, document},
           else: (_ -> {:error, :not_found})
    end
  end

  @scope {"coop", "company", "office"}
  @where %{"tenant_id" => "company", "project_id" => "office"}
  @gov %{key_id: "gov", pubkey: "gov-public"}
  @op %{key_id: "operator", pubkey: "operator-public"}
  @reviewer %{key_id: "reviewer", pubkey: "reviewer-public"}
  @sop "Retained SOP"
  @source "Retained procedure"
  @evidence "Private raw evidence that must never appear in a generated draft"

  setup do
    for bytes <- [@sop, @source, @evidence], do: Host.put(bytes)

    w = %{
      state: State.init(Host),
      keys: %{{"coop", "governance"} => %{@gov.key_id => @gov.pubkey}},
      events: []
    }

    w =
      w
      |> fold!(event("TaskOperatorGrantedV1", grant("operator", @op), @gov, "operator-grant"))
      |> fold!(
        event("TaskReviewerGrantedV1", grant("reviewer", @reviewer), @gov, "reviewer-grant")
      )
      |> fold!(%Event{
        event_id: "human",
        chapter_id: "coop",
        type: "TaskPrincipalKindDeclaredV1",
        payload: %{"principal_id" => "operator", "kind" => "human"},
        signers: [@gov]
      })
      |> fold!(event("TaskProjectOwnerAssignedV1", %{"principal_id" => "operator"}))

    {w, adoption} = adopt!(w, blueprint(), "a")

    w =
      step!(w, {:instantiate, adoption.event_id, "service", "requests", %{"check" => "check-1"}})

    w = step!(w, {:propose, "check-1"})

    w =
      fold!(
        w,
        event("TaskReadinessDefinedV1", %{
          "task_id" => "check-1",
          "expected_version" => w.state.tasks[key()].version,
          "predecessor_ids" => [],
          "sop_digest" => {:bytes, Host.digest(@sop)},
          "sop_version" => "1.0.0",
          "artifact_requirements" => %{
            "source_notes" => {:bytes, Host.digest(@source)},
            "workflow_manifest" => adoption.payload["manifest_digest"]
          }
        })
      )

    w =
      w
      |> step!({:record_custody, Host.digest(@sop)}, "sop-receipt")
      |> step!({:record_custody, Host.digest(@source)}, "source-receipt")
      |> step!(
        {:record_custody, elem(adoption.payload["manifest_digest"], 1)},
        "manifest-receipt"
      )
      |> step!({:acknowledge_sop, "check-1", "sop-receipt"})
      |> step!({:queue, "check-1"})
      |> step!(
        {:ready, "check-1",
         %{"source_notes" => "source-receipt", "workflow_manifest" => "manifest-receipt"}}
      )
      |> step!({:start, "check-1"})
      |> step!({:record_custody, Host.digest(@evidence)}, "evidence-receipt")
      |> step!({:submit_evidence, "check-1", %{"checked" => "evidence-receipt"}})
      |> step!(
        {:review, "check-1", "accept", "Checked the retained results"},
        nil,
        @reviewer,
        "reviewer-grant"
      )

    w = step!(w, {:complete, "check-1", w.state.tasks[key()].dod.review.event_id}, "completion")
    %{world: w, adoption: adoption}
  end

  test "accepted operational data populates stable scoped candidates without reads or writes", %{
    world: w,
    adoption: adoption
  } do
    Process.put({Host, :no_reads}, true)
    items = Knowledge.candidates(w.state, @scope)
    assert Enum.map(items, & &1["kind"]) |> Enum.sort() == ~w(adopted_workflow completed_task)
    assert Knowledge.candidates(w.state, @scope) == items

    assert Knowledge.counts(w.state, @scope) == %{
             "pending" => 2,
             "approved" => 0,
             "rejected" => 0,
             "withdrawn" => 0,
             "stale" => 0
           }

    assert Knowledge.candidates(w.state, {"coop", "company", "other"}) == []

    assert {:error, :unknown_knowledge_candidate} =
             Knowledge.candidate(w.state, @scope, "unknown")

    for item <- items do
      assert item["status"] == "pending"
      assert item["review_version"] == 0
      assert item["review"] == nil
      assert item["current"]
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, item["source_fingerprint"])
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, item["draft_digest"])
      assert is_binary(item["body"])
      refute item["body"] =~ @evidence
    end

    task = find(w, "completed_task")
    assert task["source"]["completion_event_id"] == "completion"
    assert task["source"]["blueprint"]["definition_id"] == "check"
    assert task["source"]["blueprint"]["revision_event_id"] == adoption.event_id
    workflow = find(w, "adopted_workflow")

    assert workflow["source"]["readiness_contract"]["artifact_requirements"]["workflow_manifest"] ==
             hex(elem(adoption.payload["manifest_digest"], 1))
  end

  test "completion candidates require the current accepting review and receipt-backed evidence",
       %{world: w} do
    original = w.state.tasks[key()]

    invalid = [
      %{original | state: "in_progress"},
      put_in(original.dod.review.decision, "refuse"),
      put_in(original.dod.review.submission_event_id, "another-submission"),
      update_in(original.dod.submission, &Map.delete(&1, :custody_receipts)),
      %{original | version: original.version + 1}
    ]

    for task <- invalid do
      state = put_in(w.state, [:tasks, key()], task)
      assert Enum.all?(Knowledge.candidates(state, @scope), &(&1["kind"] == "adopted_workflow"))
    end
  end

  test "a completed task's timing changes do not change its knowledge pins or decision", %{
    world: w
  } do
    candidate = find(w, "completed_task")
    w = review!(w, candidate["id"], "approve")
    before = elem(Knowledge.candidate(w.state, @scope, candidate["id"]), 1)
    task = w.state.tasks[key()]

    timing =
      event(
        "TaskTimingRevisedV1",
        %{
          "task_id" => "check-1",
          "principal_id" => "operator",
          "authorization_event_id" => "operator-grant",
          "lifecycle_version" => 1,
          "expected_timing_version" => task.timing_version,
          "timing" => %{"schedule" => nil, "due_ms" => 1_900_000_000_000}
        },
        @op,
        "later-timing"
      )

    w = fold!(w, timing)
    assert w.state.tasks[key()].last_event_id == "later-timing"
    assert {:ok, ^before} = Knowledge.candidate(w.state, @scope, candidate["id"])
  end

  test "approval retains exact generated content while tasks and workflow authority stay unchanged",
       %{world: w} do
    task_state = w.state.tasks
    hierarchy = w.state.hierarchy
    w = Enum.reduce(Knowledge.candidates(w.state, @scope), w, &review!(&2, &1["id"], "approve"))
    assert length(Knowledge.approved(w.state, @scope)) == 2
    assert Knowledge.counts(w.state, @scope)["approved"] == 2
    assert w.state.tasks == task_state
    assert w.state.hierarchy == hierarchy

    for item <- Knowledge.candidates(w.state, @scope) do
      assert item["review_version"] == 1

      assert item["review"]["snapshot"] ==
               Map.take(item, ~w(generator_version kind title summary body source))

      assert {:error, :knowledge_already_reviewed} =
               Knowledge.review_payload(w.state, @scope, item["id"], "approve", "Duplicate")
    end
  end

  test "rejection and withdrawal persist until an explicit versioned reconsideration", %{world: w} do
    id = find(w, "completed_task")["id"]
    w = review!(w, id, "reject")

    assert {:ok, %{"status" => "rejected", "review_version" => 1}} =
             Knowledge.candidate(w.state, @scope, id)

    assert Knowledge.approved(w.state, @scope) == []

    assert {:error, :knowledge_already_reviewed} =
             Knowledge.review_payload(w.state, @scope, id, "reject", "Duplicate")

    w = review!(w, id, "approve")

    assert {:ok, %{"status" => "approved", "review_version" => 2}} =
             Knowledge.candidate(w.state, @scope, id)

    w = review!(w, id, "withdraw")

    assert {:ok, %{"status" => "withdrawn", "review_version" => 3}} =
             Knowledge.candidate(w.state, @scope, id)

    assert Knowledge.approved(w.state, @scope) == []
    w = review!(w, id, "approve")

    assert {:ok, %{"status" => "approved", "review_version" => 4}} =
             Knowledge.candidate(w.state, @scope, id)
  end

  test "changed current workflow revisions require review and old approvals remain withdrawable",
       %{world: w} do
    old = find(w, "adopted_workflow")
    w = review!(w, old["id"], "approve")

    changed =
      update_in(
        blueprint(),
        ["roadmaps", Access.at(0), "workflows", Access.at(0), "name"],
        &(&1 <> " revised")
      )

    {w, _revision} = adopt!(w, changed, "b")
    {:ok, current} = Knowledge.candidate(w.state, @scope, old["id"])
    assert current["status"] == "pending"
    assert current["review_version"] == 1
    refute current["source_fingerprint"] == old["source_fingerprint"]
    assert Knowledge.approved(w.state, @scope) == []

    {:ok, payload} =
      Knowledge.review_payload(w.state, @scope, old["id"], "withdraw", "Retire old reference")

    assert payload["snapshot"]["title"] == old["title"]
    assert payload["source_fingerprint"] == tagged(old["source_fingerprint"])
    w = fold!(w, event("KnowledgeCandidateReviewedV1", payload))

    assert {:ok, %{"status" => "pending", "review_version" => 2}} =
             Knowledge.candidate(w.state, @scope, old["id"])
  end

  test "generic signed events cannot change the draft, pins, schema, scope or review version", %{
    world: w
  } do
    for candidate <- Knowledge.candidates(w.state, @scope) do
      {:ok, payload} =
        Knowledge.review_payload(w.state, @scope, candidate["id"], "approve", "Reviewed")

      changes = [
        Map.put(payload, "generator_version", 1.0),
        Map.put(payload, "expected_review_version", 1),
        Map.put(payload, "execute", true),
        Map.put(payload, "reason", ""),
        Map.put(payload, "decision", "publish"),
        Map.put(payload, "source_fingerprint", {:bytes, <<0::256>>}),
        Map.put(payload, "draft_digest", {:bytes, <<0::256>>}),
        put_in(payload, ["snapshot", "body"], "Altered draft"),
        put_in(payload, ["snapshot", "source", "scope", "project_id"], "another"),
        Map.put(payload, "project_id", "another")
      ]

      for changed <- changes,
          do:
            assert(match?({:error, _}, admit(w, event("KnowledgeCandidateReviewedV1", changed))))

      assert admit(w, event("KnowledgeCandidateReviewedV1", payload, @op)) ==
               {:error, :task_governance_not_declared}

      assert admit(w, %{event("KnowledgeCandidateReviewedV1", payload) | signers: []}) ==
               {:error, :task_signer_cardinality}

      assert admit(%{w | keys: %{}}, event("KnowledgeCandidateReviewedV1", payload)) ==
               {:error, :task_governance_not_declared}
    end
  end

  test "two reviews of the same displayed version cannot both append", %{world: w} do
    id = find(w, "completed_task")["id"]
    {:ok, first} = Knowledge.review_payload(w.state, @scope, id, "approve", "Accept")
    {:ok, second} = Knowledge.review_payload(w.state, @scope, id, "reject", "Reject")
    w = fold!(w, event("KnowledgeCandidateReviewedV1", first))

    assert admit(w, event("KnowledgeCandidateReviewedV1", second)) ==
             {:error, :stale_knowledge_review}

    assert {:ok, %{"status" => "approved", "review_version" => 1}} =
             Knowledge.candidate(w.state, @scope, id)
  end

  test "portable admission preserves exact snapshot types as well as values", %{world: w} do
    id = find(w, "completed_task")["id"]
    {:ok, payload} = Knowledge.review_payload(w.state, @scope, id, "approve", "Reviewed")
    altered = update_in(payload, ["snapshot", "source", "task_version"], &(&1 * 1.0))

    # A host may admit terms before canonical encoding. Numeric equivalence
    # must not authorize a snapshot that differs from the generated bytes.
    assert payload["snapshot"] == altered["snapshot"]
    refute payload["snapshot"] === altered["snapshot"]
    assert admit(w, event("KnowledgeCandidateReviewedV1", payload)) == :ok

    assert admit(w, event("KnowledgeCandidateReviewedV1", altered)) ==
             {:error, :knowledge_draft_mismatch}
  end

  test "a held approval cannot apply after its workflow source changes", %{world: w} do
    id = find(w, "adopted_workflow")["id"]

    {:ok, payload} =
      Knowledge.review_payload(w.state, @scope, id, "approve", "Reviewed old revision")

    changed = put_in(blueprint(), ["project", "name"], "Changed manifest bytes")
    {w, _revision} = adopt!(w, changed, "b")

    assert admit(w, event("KnowledgeCandidateReviewedV1", payload)) ==
             {:error, :knowledge_source_changed}
  end

  test "source loss blocks approval and live suggestions while rejection and withdrawal still work",
       %{world: w} do
    task = find(w, "completed_task")
    workflow = find(w, "adopted_workflow")
    w = review!(w, task["id"], "approve")
    Process.put({Host, Host.digest(@evidence)}, "tampered evidence")
    assert Knowledge.verify_availability(w.state, task) == {:error, :knowledge_source_unavailable}
    assert Knowledge.approved(w.state, @scope) == []
    assert {:ok, %{"status" => "approved"}} = Knowledge.candidate(w.state, @scope, task["id"])
    w = review!(w, task["id"], "withdraw")

    {:ok, payload} = Knowledge.review_payload(w.state, @scope, task["id"], "approve", "Reapprove")

    assert admit(w, event("KnowledgeCandidateReviewedV1", payload)) ==
             {:error, :knowledge_source_unavailable}

    {:bytes, manifest_digest} = tagged(workflow["source"]["manifest_digest"])
    Process.delete({Host, manifest_digest})

    {:ok, payload} =
      Knowledge.review_payload(w.state, @scope, workflow["id"], "approve", "Review")

    assert admit(w, event("KnowledgeCandidateReviewedV1", payload)) ==
             {:error, :knowledge_source_unavailable}

    w = review!(w, workflow["id"], "reject")
    assert {:ok, %{"status" => "rejected"}} = Knowledge.candidate(w.state, @scope, workflow["id"])
  end

  test "wrong-scope receipts do not satisfy source availability", %{world: w} do
    candidate = find(w, "completed_task")
    state = put_in(w.state, [:custody_receipts, "evidence-receipt", :project_id], "elsewhere")

    assert Knowledge.verify_availability(state, candidate) ==
             {:error, :knowledge_source_unavailable}
  end

  test "replay retains exact snapshots and decisions without reading artifacts", %{world: w} do
    task = find(w, "completed_task")
    workflow = find(w, "adopted_workflow")

    w =
      w
      |> review!(task["id"], "approve")
      |> review!(task["id"], "withdraw")
      |> review!(workflow["id"], "reject")

    expected = Knowledge.candidates(w.state, @scope)
    Process.put({Host, :no_reads}, true)
    replayed = Enum.reduce(w.events, State.init(Host), &State.handle_event/2)
    assert replayed == w.state
    assert Knowledge.candidates(replayed, @scope) == expected
  end

  defp find(w, kind), do: Enum.find(Knowledge.candidates(w.state, @scope), &(&1["kind"] == kind))

  defp blueprint do
    %{
      "schema_version" => 2,
      "project" => %{"key" => "office", "name" => "Office"},
      "roadmaps" => [
        %{
          "key" => "service",
          "name" => "Service",
          "workflows" => [
            %{
              "id" => "requests",
              "name" => "Office requests",
              "readiness_contract" => %{
                "schema_version" => 1,
                "sop_digest" => hex(Host.digest(@sop)),
                "sop_version" => "1.0.0",
                "input_digests" => %{"source_notes" => hex(Host.digest(@source))},
                "manifest_input" => "workflow_manifest"
              },
              "tasks" => [
                %{
                  "id" => "check",
                  "title" => "Check an office request",
                  "description" => "Review the requested setup.",
                  "artifact_requirements" => ~w(source_notes workflow_manifest),
                  "definition_of_done" => [
                    %{
                      "id" => "checked",
                      "description" => "The setup was checked against the request."
                    }
                  ]
                }
              ]
            }
          ]
        }
      ]
    }
  end

  defp adopt!(w, document, commit_char) do
    {:ok, normalized} = Blueprint.normalize(document)

    env =
      event("TaskBlueprintAppliedV1", %{
        "repository" => "fixture/workflows",
        "commit" => String.duplicate(commit_char, 40),
        "tree" => String.duplicate("c", 40),
        "path" => "workflows/office.json",
        "manifest_digest" => {:bytes, Host.put_blueprint(document)},
        "blueprint" => normalized
      })

    {fold!(w, env), env}
  end

  defp review!(w, id, decision) do
    {:ok, payload} =
      Knowledge.review_payload(w.state, @scope, id, decision, "Reviewed #{decision}")

    fold!(w, event("KnowledgeCandidateReviewedV1", payload))
  end

  defp step!(w, action, id \\ nil, signer \\ @op, grant \\ "operator-grant") do
    {:ok, type, payload} =
      Steps.command(w.state, @scope, action, %{
        "principal_id" => if(grant == "operator-grant", do: "operator", else: "reviewer"),
        "authorization_event_id" => grant,
        "lifecycle_version" => 1
      })

    fold!(w, event(type, payload, signer, id))
  end

  defp fold!(w, env) do
    assert admit(w, env) == :ok, "#{env.type} refused: #{inspect(admit(w, env))}"
    %{w | state: State.handle_event(env, w.state), events: w.events ++ [env]}
  end

  defp admit(w, env), do: Admission.check(env, %{orchestration: w.state, role_keys: w.keys})

  defp grant(principal, signer),
    do: %{
      "principal_id" => principal,
      "key_id" => signer.key_id,
      "pubkey" => {:bytes, signer.pubkey}
    }

  defp event(type, payload, signer \\ @gov, id \\ nil),
    do: %Event{
      event_id: id || "event-#{System.unique_integer([:positive])}",
      chapter_id: "coop",
      type: type,
      payload: Map.merge(@where, payload),
      signers: [signer]
    }

  defp key, do: {"coop", "company", "office", "check-1"}
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp tagged(hex), do: {:bytes, Base.decode16!(hex, case: :lower)}
end
