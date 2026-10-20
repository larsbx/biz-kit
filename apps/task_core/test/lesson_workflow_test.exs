defmodule TaskCore.LessonWorkflowTest do
  @moduledoc """
  The task core in a host that is not the ledger: a school's lessons, kept
  in memory, with no signatures checked and no store but a map. A lesson is
  a task; its prerequisite lesson a predecessor; the assessment its
  Definition of Done; the learner's work the evidence; the teacher's
  marking the review.
  """
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, Event, State, Steps}

  defmodule Host do
    @moduledoc false
    @behaviour TaskCore.Host

    # What the school's store holds, by digest.
    @store Map.new(
             ["Lesson SOP", "Worksheet", "Learner's answers"],
             &{:crypto.hash(:sha256, &1), &1}
           )

    def digest(bytes), do: :crypto.hash(:sha256, bytes)

    @impl true
    def verify_artifact(digest, limit) do
      case @store do
        %{^digest => bytes} when byte_size(bytes) <= limit -> {:ok, byte_size(bytes)}
        %{^digest => _} -> {:error, :too_large}
        _ -> {:error, :not_found}
      end
    end

    @impl true
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))

    # Blueprints: the school keeps them as encoded terms, by digest.
    @impl true
    def read_blueprint(digest) do
      case Enum.find(
             [TaskCore.BlueprintTest.doc(), curriculum_v2()],
             &(digest(encode(&1)) == digest)
           ) do
        nil -> {:error, :not_found}
        doc -> {:ok, doc}
      end
    end

    def encode(doc), do: :erlang.term_to_binary(doc)

    # The second term's revision: fractions gains a test after adding.
    def curriculum_v2 do
      test = %{
        "id" => "test",
        "title" => "End of unit test",
        "definition_of_done" => [%{"id" => "paper", "description" => "The test, marked"}],
        "depends_on" => ["adding"]
      }

      update_in(
        TaskCore.BlueprintTest.doc(),
        ["roadmaps", Access.at(0), "workflows", Access.at(0), "tasks"],
        &(&1 ++ [test])
      )
    end
  end

  @chapter "school"
  @scope {@chapter, "year-7", "maths"}
  @where %{"tenant_id" => "year-7", "project_id" => "maths"}

  @head %{key_id: "head", pubkey: "head-public-key"}
  @teacher %{key_id: "teacher-laptop", pubkey: "teacher-public-key"}
  @marker %{key_id: "marker-tablet", pubkey: "marker-public-key"}

  setup do
    school = %{
      state: State.init(Host),
      keys: %{{@chapter, "governance"} => %{"head" => "head-public-key"}}
    }

    school =
      school
      |> admit!(@head, "TaskOperatorGrantedV1", grant("teacher", @teacher), "teacher-grant")
      |> admit!(@head, "TaskReviewerGrantedV1", grant("marker", @marker), "marker-grant")

    school =
      for lesson <- ~w(intro fractions), reduce: school do
        s ->
          admit!(s, @teacher, "TaskCreatedV1", %{
            "principal_id" => "teacher",
            "authorization_event_id" => "teacher-grant",
            "lifecycle_version" => 1,
            "task_id" => lesson,
            "title" => "Lesson: #{lesson}",
            "timing" => %{"schedule" => nil, "due_ms" => nil}
          })
      end

    school =
      for bytes <- ["Lesson SOP", "Worksheet"], reduce: school do
        s -> step!(s, {:record_custody, Host.digest(bytes)}, "custody #{bytes}")
      end

    %{school: school}
  end

  test "a lesson runs from inbox to completed, and its successor waits for it", %{school: s} do
    s = s |> planned("intro", []) |> planned("fractions", ["intro"]) |> ready("intro")

    # Fractions cannot be readied before the introduction is completed.
    assert prepare(s, {:queue, "fractions"}) |> admit(s) == :ok
    s = step!(s, {:queue, "fractions"})
    ready = prepare(s, {:ready, "fractions", %{"worksheet" => "custody Worksheet"}})
    assert admit(ready, s) == {:error, :incomplete_predecessors}

    s =
      s
      |> step!({:start, "intro"})
      |> step!({:record_custody, Host.digest("Learner's answers")}, "answers")

    s = step!(s, {:submit_evidence, "intro", %{"answers" => "answers"}})
    s = step!(s, {:review, "intro", "accept", "All correct"}, nil, @marker, "marker-grant")
    review = s.state.tasks[key("intro")].dod.review.event_id
    s = step!(s, {:complete, "intro", review})

    assert s.state.tasks[key("intro")].state == "completed"

    assert s
           |> step!({:ready, "fractions", %{"worksheet" => "custody Worksheet"}})
           |> state_of("fractions") == "ready"
  end

  test "evidence the store does not hold is refused, and nothing changes", %{school: s} do
    s = s |> planned("intro", []) |> ready("intro") |> step!({:start, "intro"})

    missing = prepare(s, {:record_custody, Host.digest("Never uploaded")}, "missing")
    assert admit(missing, s) == {:error, :not_found}
  end

  test "completing without an accepting review is refused by the lifecycle's own rules", %{
    school: s
  } do
    s = s |> planned("intro", []) |> ready("intro")

    assert prepare(s, {:complete, "intro", "no-review"}) |> admit(s) ==
             {:error, {:invalid_task_transition, "ready", "completed"}}
  end

  describe "a curriculum as a blueprint" do
    test "applying it builds the hierarchy; a run creates every lesson", %{school: s} do
      {s, revision} = apply_blueprint!(s, TaskCore.BlueprintTest.doc(), "v1")

      assert %{name: "Year 7 maths", roadmaps: %{"autumn" => %{workflows: workflows}}} =
               s.state.hierarchy[@scope]

      assert workflows == %{"fractions" => %{name: "Fractions", revision: revision}}

      run = %{"intro" => "intro-7a", "adding" => "adding-7a"}
      s = step!(s, {:instantiate, revision, "autumn", "fractions", run})

      intro = s.state.tasks[key("intro-7a")]
      adding = s.state.tasks[key("adding-7a")]

      assert {intro.state, intro.title, intro.description} ==
               {"inbox", "Introducing fractions", "Halves, thirds and quarters"}

      assert adding.dod.criteria == [%{"id" => "quiz", "description" => "quiz, done"}]
      assert adding.blueprint.predecessor_ids == ["intro-7a"]
      assert intro.blueprint.artifact_requirements == ["worksheet"]

      # Readiness binds digests, and keeps the blueprint's predecessors and inputs.
      s = step!(s, {:propose, "adding-7a"})

      wrong = %{
        "artifact_requirements" => %{},
        "predecessor_ids" => [],
        "sop_digest" => {:bytes, Host.digest("Lesson SOP")}
      }

      assert govern(s, "adding-7a", "TaskReadinessDefinedV1", wrong) ==
               {:error, :blueprint_readiness_mismatch}

      s =
        govern!(s, "adding-7a", "TaskReadinessDefinedV1", %{
          wrong
          | "predecessor_ids" => ["intro-7a"]
        })

      assert s.state.tasks[key("adding-7a")].readiness.predecessor_ids == ["intro-7a"]
    end

    test "a run names every definition with new, distinct tasks", %{school: s} do
      {s, revision} = apply_blueprint!(s, TaskCore.BlueprintTest.doc(), "v1")
      run = &prepare(s, {:instantiate, revision, "autumn", "fractions", &1})

      for ids <- [
            %{"intro" => "a"},
            %{"intro" => "a", "adding" => "a"},
            %{"intro" => "a", "adding" => "b", "extra" => "c"},
            %{"intro" => "a", "adding" => "no spaces"}
          ],
          do: assert(admit(run.(ids), s) == {:error, :invalid_workflow_run})

      assert admit(run.(%{"intro" => "intro", "adding" => "b"}), s) == {:error, :task_exists}

      assert admit(prepare(s, {:instantiate, revision, "autumn", "decimals", %{}}), s) ==
               {:error, :unknown_workflow}
    end

    test "a new revision governs the workflow; runs of the old one are refused", %{school: s} do
      {s, v1} = apply_blueprint!(s, TaskCore.BlueprintTest.doc(), "v1")
      {s, v2} = apply_blueprint!(s, Host.curriculum_v2(), "v2")

      assert s.state.hierarchy[@scope].roadmaps["autumn"].workflows["fractions"].revision == v2

      old = %{"intro" => "i", "adding" => "a"}

      assert admit(prepare(s, {:instantiate, v1, "autumn", "fractions", old}), s) ==
               {:error, :stale_blueprint_revision}

      s = step!(s, {:instantiate, v2, "autumn", "fractions", Map.put(old, "test", "t")})
      assert s.state.tasks[key("t")].blueprint.predecessor_ids == ["a"]
    end

    test "only the stored, matching blueprint of this project, once per source", %{school: s} do
      doc = TaskCore.BlueprintTest.doc()
      {:ok, blueprint} = TaskCore.Blueprint.normalize(doc)
      applied = blueprint_event(doc, blueprint, "v1")

      assert admit(%{applied | signers: [@teacher]}, s) == {:error, :task_governance_not_declared}

      tampered = put_in(blueprint, ["project", "name"], "Something else")
      assert admit(blueprint_event(doc, tampered, "v1"), s) == {:error, :blueprint_mismatch}

      unknown = Map.put(applied.payload, "manifest_digest", {:bytes, Host.digest("nothing")})
      assert admit(%{applied | payload: unknown}, s) == {:error, :not_found}

      bad_source = Map.put(applied.payload, "commit", "main")
      assert admit(%{applied | payload: bad_source}, s) == {:error, :invalid_blueprint_source}

      elsewhere = Map.put(applied.payload, "project_id", "english")
      assert admit(%{applied | payload: elsewhere}, s) == {:error, :blueprint_project_mismatch}

      s = fold!(s, applied)

      assert admit(blueprint_event(doc, blueprint, "v1"), s) ==
               {:error, :blueprint_already_applied}
    end
  end

  defp apply_blueprint!(s, doc, commit) do
    {:ok, blueprint} = TaskCore.Blueprint.normalize(doc)
    event = blueprint_event(doc, blueprint, commit)
    {fold!(s, event), event.event_id}
  end

  defp blueprint_event(doc, blueprint, commit) do
    event(
      @head,
      "TaskBlueprintAppliedV1",
      Map.merge(@where, %{
        "repository" => "school/curriculum",
        "commit" => String.duplicate(if(commit == "v1", do: "a", else: "b"), 40),
        "tree" => String.duplicate("c", 40),
        "path" => "maths/year-7.yaml",
        "manifest_digest" => {:bytes, Host.digest(Host.encode(doc))},
        "blueprint" => blueprint
      }),
      nil
    )
  end

  # -- the school's side: build, check, fold ---------------------------------

  defp planned(s, lesson, prerequisites) do
    s
    |> step!({:propose, lesson})
    |> govern!(lesson, "TaskDoDDefinedV1", %{
      "criteria" => [%{"id" => "answers", "description" => "The worksheet, answered"}]
    })
    |> govern!(lesson, "TaskReadinessDefinedV1", %{
      "artifact_requirements" => %{"worksheet" => {:bytes, Host.digest("Worksheet")}},
      "predecessor_ids" => prerequisites,
      "sop_digest" => {:bytes, Host.digest("Lesson SOP")}
    })
    |> step!({:acknowledge_sop, lesson, "custody Lesson SOP"})
  end

  defp ready(s, lesson) do
    s
    |> step!({:queue, lesson})
    |> step!({:ready, lesson, %{"worksheet" => "custody Worksheet"}})
  end

  defp grant(principal, signer),
    do: %{
      "principal_id" => principal,
      "key_id" => signer.key_id,
      "pubkey" => {:bytes, signer.pubkey}
    }

  defp govern!(s, lesson, type, payload), do: fold!(s, governed(s, lesson, type, payload))
  defp govern(s, lesson, type, payload), do: admit(governed(s, lesson, type, payload), s)

  defp governed(s, lesson, type, payload) do
    expected = s.state.tasks[key(lesson)].version
    payload = Map.merge(payload, %{"task_id" => lesson, "expected_version" => expected})
    event(@head, type, Map.merge(@where, payload), nil)
  end

  # A person's step, as `TaskCore.Steps` builds it from the state.
  defp prepare(s, action, id \\ nil, signer \\ @teacher, grant \\ "teacher-grant") do
    principal = if signer == @marker, do: "marker", else: "teacher"

    actor = %{
      "principal_id" => principal,
      "authorization_event_id" => grant,
      "lifecycle_version" => 1
    }

    {:ok, type, payload} = Steps.command(s.state, @scope, action, actor)
    event(signer, type, payload, id)
  end

  defp step!(s, action, id \\ nil, signer \\ @teacher, grant \\ "teacher-grant"),
    do: fold!(s, prepare(s, action, id, signer, grant))

  defp admit!(s, signer, type, payload, id \\ nil),
    do: fold!(s, event(signer, type, Map.merge(@where, payload), id))

  defp fold!(s, event) do
    assert admit(event, s) == :ok, "#{event.type} refused"
    %{s | state: State.handle_event(event, s.state)}
  end

  defp admit(event, s), do: Admission.check(event, %{orchestration: s.state, role_keys: s.keys})

  defp event(signer, type, payload, id) do
    %Event{
      event_id: id || "e-#{System.unique_integer([:positive])}",
      chapter_id: @chapter,
      type: type,
      payload: payload,
      signers: [signer]
    }
  end

  defp key(lesson), do: {@chapter, "year-7", "maths", lesson}
  defp state_of(s, lesson), do: s.state.tasks[key(lesson)].state
end
