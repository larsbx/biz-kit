defmodule TaskCore.IntakeTest do
  @moduledoc """
  Typed intake (docs/architecture/2026-11-02-typed-intake.md): a request
  type fixes the shape of a task's Definition of Done, governance fills only
  its declared parameters, and the person who proposed the task agrees to
  that exact definition before it can be queued.
  """
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, Event, Intake, State, Steps}

  @catalogue %{
    "request_types" => %{
      "feature" => %{
        "params" => ["area", "kill_rate"],
        "criteria" => [
          %{"id" => "tests", "description" => "Property tests for {area} pass"},
          %{
            "id" => "mutation",
            "description" => "Mutation kill rate for {area} is at least {kill_rate}"
          }
        ]
      },
      "research-note" => %{
        "params" => ["topic"],
        "criteria" => [
          %{"id" => "grounded", "description" => "Every claim about {topic} cites a source"}
        ]
      }
    }
  }

  defmodule Host do
    @moduledoc false
    @behaviour TaskCore.Host

    def digest(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))

    def sop, do: :crypto.hash(:sha256, "SOP")

    @impl true
    def verify_artifact(digest, limit) do
      if digest == sop() and limit >= 3, do: {:ok, 3}, else: {:error, :not_found}
    end

    @impl true
    def hash(term), do: digest(term)

    # The catalogues the host holds, by digest.
    @impl true
    def read_catalogue(digest) do
      case Enum.find([TaskCore.IntakeTest.catalogue()], &(digest(&1) == digest)) do
        nil -> {:error, :not_found}
        doc -> {:ok, doc}
      end
    end
  end

  # A host that predates typed intake and holds no catalogues.
  defmodule PlainHost do
    @moduledoc false
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))
  end

  def catalogue, do: @catalogue

  @chapter "acme"
  @where %{"tenant_id" => "ops", "project_id" => "kernel"}
  @head %{key_id: "head", pubkey: "head-public-key"}
  @lars %{key_id: "lars-phone", pubkey: "lars-public-key"}
  @agent %{key_id: "agent-box", pubkey: "agent-public-key"}

  # -- the catalogue and its templates --------------------------------------

  describe "instantiate/3" do
    test "fills a request type's parameters into its fixed criteria" do
      assert Intake.instantiate(@catalogue, "feature", %{"area" => "dedup", "kill_rate" => "0.8"}) ==
               {:ok,
                [
                  %{"id" => "tests", "description" => "Property tests for dedup pass"},
                  %{
                    "id" => "mutation",
                    "description" => "Mutation kill rate for dedup is at least 0.8"
                  }
                ]}
    end

    test "parameters must be exactly those the request type declares" do
      for params <- [
            %{"area" => "dedup"},
            %{"area" => "dedup", "kill_rate" => "0.8", "deadline" => "friday"},
            %{}
          ] do
        assert Intake.instantiate(@catalogue, "feature", params) ==
                 {:error, :intake_params_mismatch}
      end
    end

    test "each parameter is a nonblank bounded string" do
      for value <- ["", "   ", 7, String.duplicate("x", 257)] do
        assert Intake.instantiate(@catalogue, "research-note", %{"topic" => value}) ==
                 {:error, :invalid_intake_param}
      end
    end

    test "an unknown request type has no template" do
      assert Intake.instantiate(@catalogue, "vibes", %{}) == {:error, :unknown_request_type}
    end

    test "a value is substituted once, never read as a further hole" do
      assert {:ok, [%{"description" => "Every claim about {area} cites a source"}]} =
               Intake.instantiate(@catalogue, "research-note", %{"topic" => "{area}"})
    end
  end

  describe "normalize_catalogue/1" do
    test "accepts the fixture" do
      assert {:ok, _} = Intake.normalize_catalogue(@catalogue)
    end

    test "refuses a hole no parameter declares, and a parameter no criterion uses" do
      undeclared = put_in(@catalogue, ["request_types", "research-note", "params"], [])

      unused =
        put_in(@catalogue, ["request_types", "research-note", "params"], ["topic", "audience"])

      for doc <- [undeclared, unused] do
        assert Intake.normalize_catalogue(doc) == {:error, :invalid_intake_catalogue}
      end
    end

    test "refuses malformed shapes" do
      for doc <- [
            %{},
            %{"request_types" => %{}},
            %{"request_types" => %{"bad name!" => @catalogue["request_types"]["feature"]}},
            put_in(@catalogue, ["request_types", "feature", "criteria"], []),
            put_in(@catalogue, ["request_types", "feature", "params"], [
              "area",
              "kill_rate",
              "area"
            ])
          ] do
        assert Intake.normalize_catalogue(doc) == {:error, :invalid_intake_catalogue}
      end
    end
  end

  # -- on the ledger ---------------------------------------------------------

  setup do
    s = %{
      state: State.init(Host),
      keys: %{{@chapter, "governance"} => %{"head" => "head-public-key"}}
    }

    s =
      s
      |> admit!(@head, "TaskOperatorGrantedV1", grant("lars", @lars), "lars-grant")
      |> admit!(@head, "TaskOperatorGrantedV1", grant("agent", @agent), "agent-grant")
      |> admit!(@head, "TaskOperatorGrantedV1", grant("head-as-operator", @head), "head-grant")
      |> admit!(@lars, "TaskCreatedV1", %{
        "principal_id" => "lars",
        "authorization_event_id" => "lars-grant",
        "lifecycle_version" => 1,
        "task_id" => "t1",
        "title" => "Make dedup keys stable",
        "timing" => %{"schedule" => nil, "due_ms" => nil}
      })
      |> step!({:propose, "t1"})

    %{s: s}
  end

  test "a typed definition must be its template's instance", %{s: s} do
    assert govern(s, "TaskDoDDefinedV2", typed()) == :ok

    added =
      typed(%{
        "criteria" =>
          typed()["criteria"] ++
            [%{"id" => "extra", "description" => "Something governance slipped in"}]
      })

    reworded = typed(%{"criteria" => [hd(typed()["criteria"])]})
    assert govern(s, "TaskDoDDefinedV2", added) == {:error, :intake_template_mismatch}
    assert govern(s, "TaskDoDDefinedV2", reworded) == {:error, :intake_template_mismatch}

    assert govern(s, "TaskDoDDefinedV2", Map.put(typed(), "params", %{"area" => "dedup"})) ==
             {:error, :intake_params_mismatch}
  end

  test "an unknown catalogue, or a host without catalogues, refuses", %{s: s} do
    elsewhere = typed(%{"catalogue_ref" => {:bytes, Host.digest(:other)}})
    assert govern(s, "TaskDoDDefinedV2", elsewhere) == {:error, :intake_catalogue_unavailable}

    plain = %{s | state: %{s.state | host: PlainHost}}
    assert govern(plain, "TaskDoDDefinedV2", typed()) == {:error, :intake_catalogue_unavailable}
  end

  test "a typed definition queues only once the requester agrees to it", %{s: s} do
    s = s |> govern!("TaskDoDDefinedV2", typed()) |> readied()
    assert admit(prepare(s, {:queue, "t1"}), s) == {:error, :dod_not_agreed}

    s = step!(s, {:agree_dod, "t1"})
    assert s.state.tasks[key()].dod.agreement.principal_id == "lars"
    assert admit(prepare(s, {:queue, "t1"}), s) == :ok
  end

  test "only the person who proposed the task agrees, once", %{s: s} do
    s = govern!(s, "TaskDoDDefinedV2", typed())

    assert admit(prepare(s, {:agree_dod, "t1"}, @agent, "agent-grant"), s) ==
             {:error, :dod_agreement_not_requester}

    s = step!(s, {:agree_dod, "t1"})
    assert admit(prepare(s, {:agree_dod, "t1"}), s) == {:error, :dod_already_agreed}
  end

  test "agreement is a second key: governance cannot agree with its own", %{s: s} do
    s =
      s
      |> admit!(@head, "TaskCreatedV1", %{
        "principal_id" => "head-as-operator",
        "authorization_event_id" => "head-grant",
        "lifecycle_version" => 1,
        "task_id" => "t2",
        "title" => "Self-defined",
        "timing" => %{"schedule" => nil, "due_ms" => nil}
      })
      |> step!({:propose, "t2"}, @head, "head-grant")
      |> govern!("TaskDoDDefinedV2", typed(), "t2")

    assert admit(prepare(s, {:agree_dod, "t2"}, @head, "head-grant"), s) ==
             {:error, :dod_agreement_same_key}
  end

  test "a redefinition voids the agreement, and an old one cannot be replayed", %{s: s} do
    s = s |> govern!("TaskDoDDefinedV2", typed()) |> readied()
    stale = prepare(s, {:agree_dod, "t1"})
    s = step!(s, {:agree_dod, "t1"})

    s =
      govern!(
        s,
        "TaskDoDDefinedV2",
        typed(%{"params" => %{"area" => "dedup", "kill_rate" => "0.6"}})
      )

    assert s.state.tasks[key()].dod.agreement == nil
    assert admit(prepare(s, {:queue, "t1"}), s) == {:error, :dod_not_agreed}

    replay = put_in(stale.payload["expected_version"], s.state.tasks[key()].version)
    assert admit(replay, s) == {:error, :dod_revision_mismatch}
  end

  test "agreement applies only to typed definitions, and only while proposed", %{s: s} do
    untyped =
      govern!(s, "TaskDoDDefinedV1", %{
        "criteria" => [%{"id" => "done", "description" => "It is done"}]
      })

    assert admit(prepare(untyped, {:agree_dod, "t1"}), untyped) == {:error, :dod_not_typed}
    assert admit(prepare(readied(untyped), {:queue, "t1"}), readied(untyped)) == :ok

    agreed = s |> govern!("TaskDoDDefinedV2", typed()) |> readied() |> step!({:agree_dod, "t1"})
    queued = step!(agreed, {:queue, "t1"})
    started = queued |> step!({:ready, "t1", %{}}) |> step!({:start, "t1"})

    # Unlike evidence, which is of the work under way, agreement closes with `proposed`.
    for s <- [queued, started] do
      assert admit(prepare(s, {:agree_dod, "t1"}), s) == {:error, :dod_task_not_proposed}
    end
  end

  test "Steps refuses to build an agreement where there is no definition", %{s: s} do
    actor = %{
      "principal_id" => "lars",
      "authorization_event_id" => "lars-grant",
      "lifecycle_version" => 1
    }

    assert Steps.command(s.state, {@chapter, "ops", "kernel"}, {:agree_dod, "t1"}, actor) ==
             {:error, {:invalid, :dod_not_defined}}
  end

  # -- helpers ---------------------------------------------------------------

  defp typed(overrides \\ %{}) do
    params = Map.get(overrides, "params", %{"area" => "dedup", "kill_rate" => "0.8"})
    {:ok, criteria} = Intake.instantiate(@catalogue, "feature", params)

    Map.merge(
      %{
        "request_type" => "feature",
        "params" => params,
        "catalogue_ref" => {:bytes, Host.digest(@catalogue)},
        "criteria" => criteria
      },
      overrides
    )
  end

  # Readiness with no inputs and an SOP the host holds, acknowledged by the
  # requester: what queueing needs besides the Definition of Done.
  defp readied(s) do
    s
    |> step!({:record_custody, Host.sop()}, @lars, "lars-grant", "sop-receipt")
    |> govern!("TaskReadinessDefinedV1", %{
      "artifact_requirements" => %{},
      "predecessor_ids" => [],
      "sop_digest" => {:bytes, Host.sop()}
    })
    |> step!({:acknowledge_sop, "t1", "sop-receipt"})
  end

  defp grant(principal, signer),
    do: %{
      "principal_id" => principal,
      "key_id" => signer.key_id,
      "pubkey" => {:bytes, signer.pubkey}
    }

  defp govern!(s, type, payload, task \\ "t1"), do: fold!(s, governed(s, type, payload, task))
  defp govern(s, type, payload), do: admit(governed(s, type, payload, "t1"), s)

  defp governed(s, type, payload, task) do
    expected = s.state.tasks[key(task)].version
    fields = Map.merge(payload, %{"task_id" => task, "expected_version" => expected})
    event(@head, type, Map.merge(@where, fields))
  end

  defp prepare(s, action, signer \\ @lars, grant \\ "lars-grant", id \\ nil) do
    principal = %{@lars => "lars", @agent => "agent", @head => "head-as-operator"}[signer]

    actor = %{
      "principal_id" => principal,
      "authorization_event_id" => grant,
      "lifecycle_version" => 1
    }

    {:ok, type, payload} = Steps.command(s.state, {@chapter, "ops", "kernel"}, action, actor)
    event(signer, type, payload, id)
  end

  defp step!(s, action, signer \\ @lars, grant \\ "lars-grant", id \\ nil),
    do: fold!(s, prepare(s, action, signer, grant, id))

  defp admit!(s, signer, type, payload, id \\ nil),
    do: fold!(s, event(signer, type, Map.merge(@where, payload), id))

  defp fold!(s, event) do
    assert admit(event, s) == :ok, "#{event.type} refused: #{inspect(admit(event, s))}"
    %{s | state: State.handle_event(event, s.state)}
  end

  defp admit(event, s), do: Admission.check(event, %{orchestration: s.state, role_keys: s.keys})

  defp event(signer, type, payload, id \\ nil),
    do: %Event{
      event_id: id || "e-#{System.unique_integer([:positive])}",
      chapter_id: @chapter,
      type: type,
      payload: payload,
      signers: [signer]
    }

  defp key(task \\ "t1"), do: {@chapter, "ops", "kernel", task}
end
