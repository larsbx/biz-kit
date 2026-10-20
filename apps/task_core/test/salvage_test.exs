defmodule TaskCore.SalvageTest do
  @moduledoc """
  The SpruceGoose rules the ledger lacked
  (docs/architecture/2026-10-20-sprucegoose-salvage.md): no predecessor
  cycle across a project (I-19), an SOP version that never goes back
  (I-20), and todos that must be finished before a task completes.
  """
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, Event, State, Steps}

  defmodule Host do
    @moduledoc false
    @behaviour TaskCore.Host

    @store Map.new(["SOP 1.0", "SOP 1.1", "SOP 2.0", "Answers"], &{:crypto.hash(:sha256, &1), &1})

    def digest(bytes), do: :crypto.hash(:sha256, bytes)

    @impl true
    def verify_artifact(digest, _limit) do
      case @store do
        %{^digest => bytes} -> {:ok, byte_size(bytes)}
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
  @actor %{
    "principal_id" => "teacher",
    "authorization_event_id" => "teacher-grant",
    "lifecycle_version" => 1
  }

  setup do
    s = %{
      state: State.init(Host),
      keys: %{{@chapter, "governance"} => %{"head" => "head-public-key"}}
    }

    s =
      s
      |> fold!(event(@head, "TaskOperatorGrantedV1", grant("teacher", @teacher), "teacher-grant"))
      |> fold!(event(@head, "TaskReviewerGrantedV1", grant("marker", @marker), "marker-grant"))

    s =
      Enum.reduce(~w(a b c), s, fn id, acc ->
        acc
        |> fold!(
          event(@teacher, "TaskCreatedV1", %{
            "principal_id" => "teacher",
            "authorization_event_id" => "teacher-grant",
            "lifecycle_version" => 1,
            "task_id" => id,
            "title" => "Task #{id}",
            "timing" => %{"schedule" => nil, "due_ms" => nil}
          })
        )
        |> step!({:propose, id})
      end)

    s =
      Enum.reduce(["SOP 1.0", "SOP 1.1", "SOP 2.0", "Answers"], s, fn bytes, acc ->
        step!(acc, {:record_custody, Host.digest(bytes)}, "custody #{bytes}")
      end)

    %{s: s}
  end

  describe "predecessors across a project (I-19)" do
    test "a definition that closes a cycle is refused; a chain is not", %{s: s} do
      s = s |> define!("b", ["a"]) |> define!("c", ["b"])

      assert define(s, "a", ["c"]) == {:error, :predecessor_cycle}
      assert define(s, "a", ["b"]) == {:error, :predecessor_cycle}
      assert define(s, "a", []) == :ok
    end

    test "replacing a task's own predecessors is judged on the new list", %{s: s} do
      s = s |> define!("b", ["a"]) |> define!("a", [])

      # b no longer waits on a once redefined, so a may then wait on b.
      s = define!(s, "b", [])
      assert define(s, "a", ["b"]) == :ok
    end
  end

  describe "SOP versions (I-20)" do
    test "a redefinition never names a lower version", %{s: s} do
      s = define!(s, "a", [], "SOP 1.1", "1.1.0")

      assert define(s, "a", [], "SOP 1.0", "1.0.3") == {:error, :sop_version_regressed}
      assert define(s, "a", [], "SOP 2.0", "2.0.0") == :ok
      assert define(s, "a", [], "SOP 1.1", "1.1.0") == :ok
    end

    test "once versioned, a redefinition must name a version", %{s: s} do
      s = define!(s, "a", [], "SOP 1.0", "1.0.0")
      assert define(s, "a", [], "SOP 1.1") == {:error, :sop_version_required}
    end

    test "one version names one document", %{s: s} do
      s = define!(s, "a", [], "SOP 1.0", "1.0.0")
      assert define(s, "a", [], "SOP 1.1", "1.0.0") == {:error, :sop_version_conflict}
    end

    test "a version is MAJOR.MINOR.PATCH", %{s: s} do
      for bad <- ["1.0", "v1.0.0", "1.01.0", "1.0.0-rc", ""],
          do: assert(define(s, "a", [], "SOP 1.0", bad) == {:error, :invalid_sop_version})
    end

    test "an unversioned definition may be followed by any", %{s: s} do
      s = define!(s, "a", [], "SOP 1.1")
      assert define(s, "a", [], "SOP 1.0", "1.0.0") == :ok
    end
  end

  describe "todos" do
    test "added in order, completed once each, and only after what they depend on", %{s: s} do
      s =
        s
        |> step!({:add_todo, "a", "read", "Read the chapter", []})
        |> step!({:add_todo, "a", "answer", "Answer the questions", ["read"]})

      assert Enum.map(TaskCore.Todos.ordered(s.state.tasks[key("a")]), & &1.id) == [
               "read",
               "answer"
             ]

      assert step(s, {:complete_todo, "a", "answer"}) == {:error, :todo_dependencies_open}

      s = step!(s, {:complete_todo, "a", "read"})
      assert step(s, {:complete_todo, "a", "read"}) == {:error, :todo_not_open}
      s = step!(s, {:complete_todo, "a", "answer"})

      assert %{"read" => %{state: "completed"}, "answer" => %{state: "completed"}} =
               s.state.tasks[key("a")].todos
    end

    test "dependencies name existing todos of the task, and never close a cycle", %{s: s} do
      s =
        s
        |> step!({:add_todo, "a", "one", "One", []})
        |> step!({:add_todo, "a", "two", "Two", ["one"]})

      assert step(s, {:add_todo, "a", "one", "Again", []}) == {:error, :todo_exists}

      for deps <- [["missing"], ["one", "one"], "one"],
          do: assert(step(s, {:add_todo, "a", "x", "X", deps}) == {:error, :invalid_todo})

      assert step(s, {:revise_todo, "a", "one", "One", ["two"]}) == {:error, :todo_cycle}
      assert step(s, {:revise_todo, "a", "one", "One", ["one"]}) == {:error, :todo_cycle}
      assert step(s, {:add_todo, "a", "y", " ", []}) == {:error, :invalid_todo}
    end

    test "revising expects the todo's version and an open todo", %{s: s} do
      s = step!(s, {:add_todo, "a", "one", "One", []})
      stale = prepare(s, {:revise_todo, "a", "one", "First", []})
      s = step!(s, {:revise_todo, "a", "one", "Uno", []})

      assert admit(stale, s) == {:error, {:stale_todo_version, 1, 2}}
      assert s.state.tasks[key("a")].todos["one"].title == "Uno"

      s = step!(s, {:complete_todo, "a", "one"})
      assert step(s, {:revise_todo, "a", "one", "Late", []}) == {:error, :todo_not_open}
    end

    test "a todo others depend on cannot be dropped; a dropped todo frees them", %{s: s} do
      s =
        s
        |> step!({:add_todo, "a", "one", "One", []})
        |> step!({:add_todo, "a", "two", "Two", ["one"]})

      assert step(s, {:drop_todo, "a", "one", "Not needed"}) == {:error, :todo_has_dependents}
      assert step(s, {:drop_todo, "a", "two", " "}) == {:error, :invalid_reason}

      s =
        s
        |> step!({:drop_todo, "a", "two", "Not needed"})
        |> step!({:drop_todo, "a", "one", "No"})

      assert s.state.tasks[key("a")].todos["one"].state == "dropped"
      assert step(s, {:add_todo, "a", "three", "Three", ["one"]}) == {:error, :invalid_todo}
    end

    test "todos do not move the task's version", %{s: s} do
      version = s.state.tasks[key("a")].version
      s = step!(s, {:add_todo, "a", "one", "One", []})
      assert s.state.tasks[key("a")].version == version
    end

    test "only an operator of the project, on a task not yet finished", %{s: s} do
      add = prepare(s, {:add_todo, "a", "one", "One", []})
      assert admit(%{add | signers: [@marker]}, s) == {:error, :task_operator_key_mismatch}

      s = step!(s, {:cancel, "a", "Not this term"})
      assert step(s, {:add_todo, "a", "one", "One", []}) == {:error, :task_finished}
    end

    test "a task completes only once every todo is completed or dropped", %{s: s} do
      s =
        s
        |> step!({:add_todo, "a", "one", "One", []})
        |> step!({:add_todo, "a", "two", "Two", []})
        |> govern!("a", "TaskDoDDefinedV1", %{
          "criteria" => [%{"id" => "answers", "description" => "Answered"}]
        })
        |> define!("a", [])
        |> step!({:acknowledge_sop, "a", "custody SOP 1.0"})
        |> step!({:queue, "a"})
        |> step!({:ready, "a", %{}})
        |> step!({:start, "a"})
        |> step!({:submit_evidence, "a", %{"answers" => "custody Answers"}})
        |> step!({:review, "a", "accept", "Good"}, nil, @marker, "marker-grant")

      review = s.state.tasks[key("a")].dod.review.event_id
      assert step(s, {:complete, "a", review}) == {:error, :open_todos}

      s = s |> step!({:complete_todo, "a", "one"}) |> step!({:drop_todo, "a", "two", "Moot"})

      assert s |> step!({:complete, "a", review}) |> then(& &1.state.tasks[key("a")].state) ==
               "completed"
    end
  end

  # -- helpers -------------------------------------------------------------------

  defp define!(s, task, predecessors, sop \\ "SOP 1.0", version \\ nil),
    do: fold!(s, definition(s, task, predecessors, sop, version))

  defp define(s, task, predecessors, sop \\ "SOP 1.0", version \\ nil),
    do: admit(definition(s, task, predecessors, sop, version), s)

  defp definition(s, task, predecessors, sop, version) do
    payload = %{
      "artifact_requirements" => %{},
      "predecessor_ids" => predecessors,
      "sop_digest" => {:bytes, Host.digest(sop)}
    }

    payload = if version, do: Map.put(payload, "sop_version", version), else: payload
    governed(s, task, "TaskReadinessDefinedV1", payload)
  end

  defp govern!(s, task, type, payload), do: fold!(s, governed(s, task, type, payload))

  defp governed(s, task, type, payload) do
    expected = s.state.tasks[key(task)].version

    event(
      @head,
      type,
      Map.merge(payload, %{"task_id" => task, "expected_version" => expected}),
      nil
    )
  end

  defp step!(s, action, id \\ nil, signer \\ @teacher, grant \\ "teacher-grant"),
    do: fold!(s, prepare(s, action, id, signer, grant))

  defp step(s, action), do: admit(prepare(s, action), s)

  defp prepare(s, action, id \\ nil, signer \\ @teacher, grant \\ "teacher-grant") do
    principal = if signer == @marker, do: "marker", else: "teacher"
    actor = %{@actor | "principal_id" => principal, "authorization_event_id" => grant}
    {:ok, type, payload} = Steps.command(s.state, @scope, action, actor)
    event(signer, type, payload, id)
  end

  defp fold!(s, event) do
    assert admit(event, s) == :ok, "#{event.type} refused: #{inspect(admit(event, s))}"
    %{s | state: State.handle_event(event, s.state)}
  end

  defp admit(event, s), do: Admission.check(event, %{orchestration: s.state, role_keys: s.keys})

  defp grant(principal, signer),
    do:
      Map.merge(@where, %{
        "principal_id" => principal,
        "key_id" => signer.key_id,
        "pubkey" => {:bytes, signer.pubkey}
      })

  defp event(signer, type, payload, id \\ nil) do
    %Event{
      event_id: id || "e-#{System.unique_integer([:positive])}",
      chapter_id: @chapter,
      type: type,
      payload: Map.merge(@where, payload),
      signers: [signer]
    }
  end

  defp key(task), do: {@chapter, "year-7", "maths", task}
end
