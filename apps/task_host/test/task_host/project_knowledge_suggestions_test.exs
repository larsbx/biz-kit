defmodule TaskHost.ProjectKnowledgeSuggestionsTest do
  use ExUnit.Case, async: true

  alias TaskCore.{Blueprint, Hierarchy, Knowledge, State}
  alias TaskHost.ProjectKnowledgeSuggestions, as: Suggestions

  defmodule Host do
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term, [:deterministic]))

    def verify_artifact(digest, _limit) do
      Process.put(:knowledge_source_checks, Process.get(:knowledge_source_checks, 0) + 1)

      if digest in Process.get(:missing_knowledge_sources, []),
        do: {:error, :not_found},
        else: {:ok, 32}
    end
  end

  @scope {"chapter", "tenant", "project"}
  @pubkey :binary.copy(<<7>>, 32)

  # These are canonical projection fixtures. Real signature, artifact and HTTP
  # admission are exercised separately by ProjectKnowledgeTest.
  defp workflow(state, scope, id, revision, title \\ "Device onboarding") do
    {chapter, tenant, project} = scope

    {:ok, blueprint} =
      Blueprint.normalize(%{
        "schema_version" => 2,
        "project" => %{"key" => project, "name" => "Operations"},
        "roadmaps" => [
          %{
            "key" => "ops",
            "name" => "Operations",
            "workflows" => [
              %{
                "id" => id,
                "name" => title,
                "tasks" => [
                  %{
                    "id" => "setup",
                    "title" => "Set up device access",
                    "definition_of_done" => [
                      %{"id" => "ready", "description" => "Access confirmed"}
                    ]
                  }
                ]
              }
            ]
          }
        ]
      })

    env = %{
      type: "TaskBlueprintAppliedV1",
      event_id: revision,
      chapter_id: chapter,
      payload: %{
        "tenant_id" => tenant,
        "project_id" => project,
        "repository" => "synthetic/operations",
        "commit" => String.duplicate("a", 40),
        "tree" => String.duplicate("b", 40),
        "path" => "workflow.json",
        "manifest_digest" => {:bytes, Host.hash([scope, revision, blueprint])},
        "blueprint" => blueprint
      }
    }

    Hierarchy.handle_event(env, state)
  end

  defp task(state, scope, id, title, binding \\ nil) do
    task = State.new_task(%{event_id: "created-" <> id}, %{title: title})
    task = if binding, do: Map.put(task, :blueprint, binding), else: task
    put_in(state, [:tasks, Access.key(Tuple.insert_at(scope, 3, id))], task)
  end

  defp completed(state, scope, id, binding) do
    {chapter, tenant, project} = scope
    digest = Host.hash(["evidence", scope, id])
    criteria = [%{"id" => "ready", "description" => "Device access confirmed"}]

    task =
      State.new_task(%{event_id: "completion-" <> id}, %{
        title: "Device onboarding recap",
        state: "completed",
        version: 3,
        blueprint: binding,
        dod: %{
          event_id: "definition-" <> id,
          definition_ref: {:bytes, Host.hash(criteria)},
          criteria: criteria,
          submission: %{
            event_id: "submission-" <> id,
            evidence: %{"ready" => {:bytes, digest}},
            custody_receipts: %{"ready" => "receipt-" <> id}
          },
          review: %{
            event_id: "review-" <> id,
            decision: "accept",
            submission_event_id: "submission-" <> id
          }
        }
      })

    state
    |> put_in([:tasks, Access.key(Tuple.insert_at(scope, 3, id))], task)
    |> put_in([:custody_receipts, Access.key("receipt-" <> id)], %{
      chapter_id: chapter,
      tenant_id: tenant,
      project_id: project,
      digest: {:bytes, digest}
    })
    |> put_in([:dod_commands, Access.key("completion-" <> id)], %{
      type: "TaskCompletedV1",
      event_id: "completion-" <> id,
      chapter_id: chapter,
      payload: %{
        "tenant_id" => tenant,
        "project_id" => project,
        "task_id" => id,
        "expected_version" => 2,
        "review_event_id" => "review-" <> id
      }
    })
  end

  defp workflow_binding(revision),
    do: %{
      revision_event_id: revision,
      roadmap_key: "ops",
      workflow_id: "onboarding",
      definition_id: "setup"
    }

  defp decide(state, candidate, decision) do
    scope = candidate["source"]["scope"]
    scope = {scope["chapter_id"], scope["tenant_id"], scope["project_id"]}
    {chapter, _, _} = scope

    {:ok, payload} =
      Knowledge.review_payload(state, scope, candidate["id"], decision, "Checked source")

    env = %{
      type: "KnowledgeCandidateReviewedV1",
      chapter_id: chapter,
      event_id: "decision-#{candidate["id"]}-#{payload["expected_review_version"]}",
      payload: payload,
      signers: [%{role: "governance", key_id: "admin", pubkey: @pubkey}]
    }

    assert :ok = Knowledge.check(env, state, %{{chapter, "governance"} => %{"admin" => @pubkey}})
    Knowledge.handle_event(env, state)
  end

  defp approve_all(state, scope) do
    Enum.reduce(Knowledge.candidates(state, scope), state, &decide(&2, &1, "approve"))
  end

  test "existing sources are pending automatically; only approved knowledge is suggested" do
    state =
      State.init(Host)
      |> workflow(@scope, "onboarding", "revision-1")
      |> task(@scope, "new-hire", "Device onboarding for a new colleague")

    [draft] = Knowledge.candidates(state, @scope)
    assert draft["status"] == "pending"
    assert {:ok, %{"items" => []}} = Suggestions.select(state, @scope, %{"task_id" => "new-hire"})
    approved = decide(state, draft, "approve")

    assert {:ok, %{"items" => [item], "context" => %{"task_id" => "new-hire"}}} =
             Suggestions.select(approved, @scope, %{"task_id" => "new-hire"})

    assert item["id"] == draft["id"]
    assert item["reason"] =~ "topic"
    assert item["status"] == "approved"
    assert Knowledge.candidates(state, @scope) == [draft]
  end

  test "the adopted revision and same workflow step outrank a shared topic" do
    state =
      State.init(Host)
      |> workflow(@scope, "onboarding", "revision-1", "Colleague setup")
      |> workflow(@scope, "repairs", "repairs-1", "Device onboarding repairs")
      |> task(@scope, "next", "Device onboarding", workflow_binding("revision-1"))
      |> completed(@scope, "previous", workflow_binding("revision-1"))
      |> approve_all(@scope)

    assert {:ok, %{"items" => [workflow, completion, topic]}} =
             Suggestions.select(state, @scope, %{"task_id" => "next"})

    assert workflow["source"]["workflow_id"] == "onboarding"
    assert workflow["reason"] =~ "adopted workflow"
    assert completion["source"]["task_id"] == "previous"
    assert completion["reason"] =~ "workflow step"
    assert topic["source"]["workflow_id"] == "repairs"
    assert topic["score"] < completion["score"]

    {:ok, own} = Suggestions.select(state, @scope, %{"task_id" => "previous"})
    refute Enum.any?(own["items"], &(&1["source"]["task_id"] == "previous"))
  end

  test "candidate content and caller-supplied context cannot cross a project" do
    other = {"chapter", "tenant", "other-project"}

    state =
      State.init(Host)
      |> workflow(other, "onboarding", "private-revision", "Private device onboarding")
      |> approve_all(other)
      |> task(@scope, "target", "Device onboarding")

    assert {:ok, %{"items" => []}} = Suggestions.select(state, @scope, %{"task_id" => "target"})

    assert {:error, :unknown_knowledge_context} =
             Suggestions.select(state, other, %{"task_id" => "target"})

    assert {:error, :unknown_knowledge_context} =
             Suggestions.select(state, @scope, %{
               "roadmap_key" => "ops",
               "workflow_id" => "onboarding"
             })

    for context <- [%{}, %{"query" => "private"}, %{"task_id" => "target", "title" => "private"}] do
      assert {:error, :invalid_knowledge_context} = Suggestions.select(state, @scope, context)
    end
  end

  test "rejection, withdrawal and source unavailability suppress suggestions" do
    pending =
      State.init(Host)
      |> workflow(@scope, "onboarding", "revision-1")
      |> task(@scope, "next", "Device onboarding")

    [candidate] = Knowledge.candidates(pending, @scope)
    rejected = decide(pending, candidate, "reject")
    assert {:ok, %{"items" => []}} = Suggestions.select(rejected, @scope, %{"task_id" => "next"})

    approved = decide(pending, candidate, "approve")
    withdrawn = decide(approved, candidate, "withdraw")
    assert {:ok, %{"items" => []}} = Suggestions.select(withdrawn, @scope, %{"task_id" => "next"})

    Process.put(:missing_knowledge_sources, [
      Base.decode16!(candidate["source"]["manifest_digest"], case: :lower)
    ])

    assert {:ok, %{"items" => []}} = Suggestions.select(approved, @scope, %{"task_id" => "next"})
    assert Knowledge.counts(approved, @scope)["approved"] == 1
  end

  test "a source revision change requires review and never recommends a different revision to a pinned run" do
    old =
      State.init(Host)
      |> workflow(@scope, "onboarding", "revision-1")
      |> completed(@scope, "previous", workflow_binding("revision-1"))
      |> task(@scope, "old-run", "Device onboarding", workflow_binding("revision-1"))
      |> approve_all(@scope)

    current = workflow(old, @scope, "onboarding", "revision-2")
    assert Knowledge.counts(current, @scope)["pending"] == 1
    context = %{"roadmap_key" => "ops", "workflow_id" => "onboarding"}
    assert {:ok, %{"items" => []}} = Suggestions.select(current, @scope, context)

    updated =
      Enum.find(Knowledge.candidates(current, @scope), &(&1["kind"] == "adopted_workflow"))

    current = decide(current, updated, "approve")
    assert {:ok, %{"items" => [item]}} = Suggestions.select(current, @scope, context)
    assert item["source"]["revision_event_id"] == "revision-2"

    {:ok, old_context} = Suggestions.select(current, @scope, %{"task_id" => "old-run"})
    assert Enum.all?(old_context["items"], &(&1["kind"] == "completed_task"))
  end

  test "results are deterministic, bounded, and stop expensive availability checks after the limit" do
    state =
      Enum.reduce(1..25, State.init(Host), fn i, state ->
        workflow(state, @scope, "devices-#{i}", "revision-#{i}")
      end)
      |> task(@scope, "target", "Device onboarding")
      |> approve_all(@scope)

    Process.put(:knowledge_source_checks, 0)

    assert {:ok, %{"items" => items, "limit" => 5}} =
             Suggestions.select(state, @scope, %{"task_id" => "target"})

    assert length(items) == 5
    assert Enum.map(items, & &1["id"]) == Enum.map(items, & &1["id"]) |> Enum.sort()
    assert Process.get(:knowledge_source_checks) == 5

    missing =
      Enum.map(
        Knowledge.candidates(state, @scope),
        &Base.decode16!(&1["source"]["manifest_digest"], case: :lower)
      )

    Process.put(:missing_knowledge_sources, missing)
    Process.put(:knowledge_source_checks, 0)
    assert {:ok, %{"items" => []}} = Suggestions.select(state, @scope, %{"task_id" => "target"})
    assert Process.get(:knowledge_source_checks) == 20
  end
end
