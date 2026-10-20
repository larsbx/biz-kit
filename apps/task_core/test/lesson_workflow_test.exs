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

  defp govern!(s, lesson, type, payload) do
    expected = s.state.tasks[key(lesson)].version

    admit!(
      s,
      @head,
      type,
      Map.merge(payload, %{"task_id" => lesson, "expected_version" => expected})
    )
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
