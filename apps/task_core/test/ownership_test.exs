defmodule TaskCore.OwnershipTest do
  @moduledoc """
  Project ownership (docs/architecture/2026-11-02-project-ownership.md):
  ownership establishes accountability, grants establish authority, and
  governance controls both.

    * a project's owner is one principal that governance has declared human
      and that holds an active operator grant in the project;
    * no task is created, workflow run or baseline recorded in a project
      without such an owner;
    * no admitted transition leaves a project with an ineligible owner, by
      whatever route its owner loses eligibility, unless the same batch
      assigns an eligible successor.
  """
  use ExUnit.Case, async: true

  alias TaskCore.{Admission, Event, Projects, State}

  defmodule Host do
    @moduledoc false
    def hash(term), do: :crypto.hash(:sha256, :erlang.term_to_binary(term))
  end

  @chapter "acme"
  @here {"acme", "ops", "kernel"}
  @where %{"tenant_id" => "ops", "project_id" => "kernel"}
  @elsewhere %{"tenant_id" => "ops", "project_id" => "other"}
  @head %{key_id: "head", pubkey: "head-public-key"}
  @ann %{key_id: "ann-phone", pubkey: "ann-public-key"}
  @ann2 %{key_id: "ann-laptop", pubkey: "ann-laptop-key"}
  @bob %{key_id: "bob-phone", pubkey: "bob-public-key"}
  @bot %{key_id: "bot-box", pubkey: "bot-public-key"}

  setup do
    s = %{
      state: State.init(Host),
      keys: %{{@chapter, "governance"} => %{"head" => "head-public-key"}}
    }

    s =
      s
      |> gov!("TaskOperatorGrantedV1", grant("ann", @ann), "ann-grant")
      |> gov!("TaskOperatorGrantedV1", grant("bob", @bob), "bob-grant")
      |> gov!("TaskOperatorGrantedV1", grant("bot", @bot), "bot-grant")

    %{s: s}
  end

  # -- principal kinds -------------------------------------------------------

  describe "principal kinds" do
    test "governance declares a principal human or agent, chapter-wide", %{s: s} do
      s = s |> kind!("ann", "human") |> kind!("bot", "agent")
      assert Projects.kind(s.state, @chapter, "ann") == "human"
      assert Projects.kind(s.state, @chapter, "bot") == "agent"
      assert Projects.kind(s.state, @chapter, "bob") == nil
      assert Projects.kind(s.state, "other-chapter", "ann") == nil
    end

    test "only governance declares, only known kinds, and only changes", %{s: s} do
      by_ann = event(@ann, "TaskPrincipalKindDeclaredV1", kind("ann", "human"))
      assert admit(by_ann, s) == {:error, :task_governance_not_declared}

      for k <- ["robot", "", "Human"] do
        assert admit(event(@head, "TaskPrincipalKindDeclaredV1", kind("ann", k)), s) ==
                 {:error, :invalid_principal_kind}
      end

      s = kind!(s, "ann", "human")

      assert admit(event(@head, "TaskPrincipalKindDeclaredV1", kind("ann", "human")), s) ==
               {:error, :principal_kind_unchanged}

      withdrawn = event(@head, "TaskPrincipalKindWithdrawnV1", %{"principal_id" => "bob"})
      assert admit(withdrawn, s) == {:error, :principal_kind_not_declared}

      bad_chapter = %{
        event(@head, "TaskPrincipalKindDeclaredV1", kind("bob", "human"))
        | chapter_id: "no spaces"
      }

      assert admit(bad_chapter, s) == {:error, :invalid_task_scope}
    end
  end

  # -- eligibility and assignment ---------------------------------------------

  describe "assigning an owner" do
    test "the owner must be a declared human holding an active operator grant", %{s: s} do
      # Undeclared: no silent qualification.
      assert assign(s, "ann") == {:error, :project_owner_ineligible}

      s = s |> kind!("ann", "human") |> kind!("bot", "agent") |> kind!("carol", "human")
      assert assign(s, "bot") == {:error, :project_owner_ineligible}
      # Human, but no grant in this project.
      assert assign(s, "carol") == {:error, :project_owner_ineligible}

      revoked = gov!(s, "TaskOperatorRevokedV1", %{"authorization_event_id" => "ann-grant"})
      assert assign(revoked, "ann") == {:error, :project_owner_ineligible}

      s = assign!(s, "ann")
      assert Projects.owner(s.state, @here) == "ann"
      assert Projects.eligible_owner?(s.state, @here)
    end

    test "only governance assigns or transfers ownership", %{s: s} do
      s = s |> kind!("ann", "human") |> kind!("bob", "human") |> assign!("ann")

      # The owner cannot hand the project on, nor can another operator take it.
      for signer <- [@ann, @bob] do
        transfer =
          event(signer, "TaskProjectOwnerAssignedV1", Map.put(@where, "principal_id", "bob"))

        assert admit(transfer, s) == {:error, :task_governance_not_declared}
      end

      s = assign!(s, "bob")
      assert Projects.owner(s.state, @here) == "bob"
    end

    test "every assignment is a signed, attributable governance event", %{s: s} do
      s = s |> kind!("ann", "human") |> assign!("ann", "first-owner")
      assert s.state.projects[@here].owner_event_id == "first-owner"
      assert s.state.project_commands["first-owner"].signers == [@head]
    end
  end

  # -- owner before work -------------------------------------------------------

  describe "owner before work" do
    test "no task is created or baseline recorded without an eligible owner", %{s: s} do
      assert admit(create(s, "t1"), s) == {:error, :project_has_no_owner}
      assert admit(baseline(s, "t1"), s) == {:error, :project_has_no_owner}

      s = s |> kind!("ann", "human") |> assign!("ann")
      assert admit(create(s, "t1"), s) == :ok
      assert admit(baseline(s, "t1"), s) == :ok
    end

    test "governance bootstraps a project without needing an owner", %{s: s} do
      # Declaring, granting and assigning are not work; none needs an owner.
      fresh = %{s | state: State.init(Host)}

      fresh =
        fresh
        |> kind!("ann", "human")
        |> gov!("TaskOperatorGrantedV1", grant("ann", @ann), "ann-grant")
        |> assign!("ann")

      assert admit(create(fresh, "t1"), fresh) == :ok
    end

    test "a project's owner does not license work in another project", %{s: s} do
      s =
        s
        |> kind!("ann", "human")
        |> assign!("ann")
        |> gov!("TaskOperatorGrantedV1", grant("ann", @ann2), "ann-other", @elsewhere)

      elsewhere = create(s, "t1", @ann2, "ann-other", @elsewhere)
      assert admit(elsewhere, s) == {:error, :project_has_no_owner}
    end

    test "ownership confers no authority: grants alone do", %{s: s} do
      s = s |> kind!("ann", "human") |> kind!("bob", "human") |> assign!("ann")

      # Bob, an operator who is not the owner, works as before.
      assert admit(create(s, "t1", @bob, "bob-grant"), s) == :ok

      # Ann, the owner, signs no governance command by being owner.
      grant_by_owner =
        event(@ann, "TaskOperatorGrantedV1", Map.merge(@where, grant("carol", @bot)))

      assert admit(grant_by_owner, s) == {:error, :task_governance_not_declared}

      # An owner without the right grant is refused like anyone else.
      assert admit(create(s, "t1", @ann, "bob-grant"), s) == {:error, :task_principal_mismatch}
    end
  end

  # -- no orphans --------------------------------------------------------------

  describe "no orphaned project" do
    setup %{s: s} do
      s =
        s
        |> kind!("ann", "human")
        |> kind!("bob", "human")
        |> assign!("ann")

      %{s: s}
    end

    test "revoking the owner's last operator grant is refused", %{s: s} do
      revoke =
        event(
          @head,
          "TaskOperatorRevokedV1",
          Map.put(@where, "authorization_event_id", "ann-grant")
        )

      assert admit(revoke, s) == {:error, :project_owner_ineligible}
    end

    test "revoking one of two owner grants is not", %{s: s} do
      s = gov!(s, "TaskOperatorGrantedV1", grant("ann", @ann2), "ann-grant-2")
      assert gov(s, "TaskOperatorRevokedV1", %{"authorization_event_id" => "ann-grant"}) == :ok
    end

    test "the owner revoking their own last device is refused", %{s: s} do
      own =
        event(
          @ann,
          "TaskDeviceRevokedV1",
          Map.merge(@where, %{
            "principal_id" => "ann",
            "authorization_event_id" => "ann-grant",
            "revoked_grant_event_id" => "ann-grant"
          })
        )

      assert admit(own, s) == {:error, :project_owner_ineligible}
    end

    test "offboarding the owner is refused", %{s: s} do
      assert gov(s, "TaskPrincipalOffboardedV1", %{"principal_id" => "ann"}) ==
               {:error, :project_owner_ineligible}

      # Offboarding someone else is unaffected.
      assert gov(s, "TaskPrincipalOffboardedV1", %{"principal_id" => "bob"}) == :ok
    end

    test "re-declaring the owner an agent, or withdrawing their kind, is refused", %{s: s} do
      assert admit(event(@head, "TaskPrincipalKindDeclaredV1", kind("ann", "agent")), s) ==
               {:error, :project_owner_ineligible}

      withdraw = event(@head, "TaskPrincipalKindWithdrawnV1", %{"principal_id" => "ann"})
      assert admit(withdraw, s) == {:error, :project_owner_ineligible}
    end

    test "the guard follows the owner into every project they own", %{s: s} do
      s =
        s
        |> gov!("TaskOperatorGrantedV1", grant("ann", @ann2, @elsewhere), "ann-other", @elsewhere)
        |> assign!("ann", nil, @elsewhere)

      # A project-scoped offboarding is checked against that project's owner.
      assert gov(s, "TaskPrincipalOffboardedV1", %{"principal_id" => "ann"}, @elsewhere) ==
               {:error, :project_owner_ineligible}

      # Chapter-wide, the kind withdrawal would orphan both.
      withdraw = event(@head, "TaskPrincipalKindWithdrawnV1", %{"principal_id" => "ann"})
      assert admit(withdraw, s) == {:error, :project_owner_ineligible}
    end
  end

  # -- batches -----------------------------------------------------------------

  describe "a batch is validated together" do
    setup %{s: s} do
      %{s: s |> kind!("ann", "human") |> kind!("bob", "human") |> assign!("ann")}
    end

    test "offboarding and reassignment succeed together, in either order", %{s: s} do
      offboard = governed("TaskPrincipalOffboardedV1", %{"principal_id" => "ann"})
      successor = governed("TaskProjectOwnerAssignedV1", %{"principal_id" => "bob"})

      for batch <- [[offboard, successor], [successor, offboard]] do
        assert Admission.check_batch(batch, gate(s)) == :ok
      end

      # Alone, the offboarding still orphans the project.
      assert Admission.check_batch([offboard], gate(s)) ==
               {:error, {:batch, :project_owner_ineligible}}
    end

    test "simultaneous revocation and reassignment, in either order", %{s: s} do
      revoke = governed("TaskOperatorRevokedV1", %{"authorization_event_id" => "ann-grant"})
      successor = governed("TaskProjectOwnerAssignedV1", %{"principal_id" => "bob"})

      for batch <- [[revoke, successor], [successor, revoke]] do
        assert Admission.check_batch(batch, gate(s)) == :ok
      end
    end

    test "a successor must be eligible at the end of the batch", %{s: s} do
      s = kind!(s, "bot", "agent")
      offboard = governed("TaskPrincipalOffboardedV1", %{"principal_id" => "ann"})
      to_agent = governed("TaskProjectOwnerAssignedV1", %{"principal_id" => "bot"})

      assert Admission.check_batch([offboard, to_agent], gate(s)) ==
               {:error, {:batch, :project_owner_ineligible}}

      # A successor made eligible within the same batch qualifies.
      declare = event(@head, "TaskPrincipalKindDeclaredV1", kind("bot", "human"))
      assert Admission.check_batch([offboard, to_agent, declare], gate(s)) == :ok
    end

    test "each event's own rules still apply inside a batch, at its position", %{s: s} do
      forged = event(@ann, "TaskProjectOwnerAssignedV1", Map.put(@where, "principal_id", "bob"))
      offboard = governed("TaskPrincipalOffboardedV1", %{"principal_id" => "ann"})

      assert Admission.check_batch([offboard, forged], gate(s)) ==
               {:error, {1, :task_governance_not_declared}}
    end

    test "a batch never relaxes owner-before-work", %{s: s} do
      fresh = %{s | state: put_in(s.state, [:projects], %{})}
      successor = governed("TaskProjectOwnerAssignedV1", %{"principal_id" => "ann"})

      # Work before the owner in the batch is refused at its position…
      assert Admission.check_batch([create(fresh, "t1"), successor], gate(fresh)) ==
               {:error, {0, :project_has_no_owner}}

      # …and after it, admitted.
      assert Admission.check_batch([successor, create(fresh, "t1")], gate(fresh)) == :ok
    end
  end

  test "a state that already holds a violation takes no new work, and blocks nothing else", %{
    s: s
  } do
    # Folded, not admitted, as a replay of some other history would be: the
    # owner's only grant revoked after assignment.
    s = s |> kind!("ann", "human") |> kind!("bob", "human") |> assign!("ann")

    revoke = governed("TaskOperatorRevokedV1", %{"authorization_event_id" => "ann-grant"})

    s = %{s | state: State.handle_event(revoke, s.state)}
    assert Projects.violations(s.state) == [@here]

    assert admit(create(s, "t1", @bob, "bob-grant"), s) == {:error, :project_owner_ineligible}

    # Unrelated governance still goes through, and reassignment repairs it.
    assert gov(s, "TaskOperatorGrantedV1", grant("carol", @bot)) == :ok
    s = assign!(s, "bob")
    assert Projects.violations(s.state) == []
    assert admit(create(s, "t1", @bob, "bob-grant"), s) == :ok
  end

  # -- legacy ------------------------------------------------------------------

  test "an ownerless legacy project is backfilled without rewriting its history", %{s: s} do
    # A project worked before ownership existed: its events were admitted
    # under the old rules, so here they are folded as replay folds them.
    legacy = [
      event(@ann, "TaskCreatedV1", create_payload("old-1", "ann", "ann-grant")),
      event(@ann, "TaskCreatedV1", create_payload("old-2", "ann", "ann-grant"))
    ]

    s = %{s | state: Enum.reduce(legacy, s.state, &State.handle_event/2)}
    history = s.state.tasks

    # Readable, and its work can go on, but it accepts no new work.
    assert map_size(history) == 2
    assert admit(create(s, "new-1"), s) == {:error, :project_has_no_owner}
    propose = event(@ann, "TaskProposedV1", propose_payload("old-1"))
    assert admit(propose, s) == :ok

    # Governance backfills in one batch: declare, then assign.
    backfill = [
      event(@head, "TaskPrincipalKindDeclaredV1", kind("ann", "human")),
      governed("TaskProjectOwnerAssignedV1", %{"principal_id" => "ann"})
    ]

    assert Admission.check_batch(backfill, gate(s)) == :ok
    s = %{s | state: Enum.reduce(backfill, s.state, &State.handle_event/2)}

    assert admit(create(s, "new-1"), s) == :ok
    # The history is what it was: the backfill adds facts, it rewrites none.
    assert s.state.tasks == history
    assert Enum.reduce(legacy, State.init(Host), &State.handle_event/2).tasks == history
  end

  # -- the invariant, over reachable states ------------------------------------

  @principals ~w(ann bob bot)
  @projects [@where, @elsewhere]

  test "no admitted sequence reaches an ineligible owner, or work without one" do
    stats =
      for seed <- 1..150, reduce: %{} do
        acc ->
          :rand.seed(:exsss, {seed, seed * 7, seed * 13})
          walk(40, start(), acc)
      end

    # Not vacuous: the walks did admit and refuse what the rules are about.
    for key <- [
          {:ok, "TaskProjectOwnerAssignedV1"},
          {:ok, "TaskCreatedV1"},
          {:ok, "TaskOperatorRevokedV1"},
          {:ok, :batch},
          {:refused, :project_owner_ineligible},
          {:refused, :project_has_no_owner}
        ] do
      assert Map.get(stats, key, 0) > 0, "never reached #{inspect(key)}"
    end
  end

  defp start do
    s = %{
      state: State.init(Host),
      keys: %{{@chapter, "governance"} => %{"head" => "head-public-key"}}
    }

    %{s: s, grants: []}
  end

  defp walk(0, _w, acc), do: acc

  defp walk(n, w, acc) do
    batch =
      if :rand.uniform(4) == 1, do: [random_event(w), random_event(w)], else: [random_event(w)]

    before = w.s.state

    result =
      case batch do
        [one] -> admit(one, w.s)
        many -> Admission.check_batch(many, gate(w.s))
      end

    case result do
      :ok ->
        after_state = Enum.reduce(batch, before, &State.handle_event/2)
        assert Projects.violations(after_state) == []

        for %{type: "TaskCreatedV1", payload: p} = e <- batch,
            length(batch) == 1 do
          assert Projects.eligible_owner?(before, State.scope(e)), inspect(p)
        end

        grants = for %{type: "TaskOperatorGrantedV1", event_id: id} <- batch, do: id
        key = if length(batch) == 1, do: {:ok, hd(batch).type}, else: {:ok, :batch}

        walk(
          n - 1,
          %{w | s: %{w.s | state: after_state}, grants: w.grants ++ grants},
          bump(acc, key)
        )

      {:error, reason} ->
        reason = with {_where, r} <- reason, do: r
        walk(n - 1, w, bump(acc, {:refused, reason}))
    end
  end

  defp bump(acc, key), do: Map.update(acc, key, 1, &(&1 + 1))

  defp random_event(w) do
    who = Enum.random(@principals)
    where = Enum.random(@projects)
    signer = %{key_id: "#{who}-key", pubkey: "#{who}-pub"}

    case :rand.uniform(7) do
      1 ->
        event(@head, "TaskPrincipalKindDeclaredV1", kind(who, Enum.random(~w(human agent))))

      2 ->
        event(@head, "TaskPrincipalKindWithdrawnV1", %{"principal_id" => who})

      3 ->
        event(
          @head,
          "TaskOperatorGrantedV1",
          Map.merge(where, grant(who, signer)),
          "g-#{System.unique_integer([:positive])}"
        )

      4 when w.grants != [] ->
        event(
          @head,
          "TaskOperatorRevokedV1",
          Map.put(where, "authorization_event_id", Enum.random(w.grants))
        )

      5 ->
        event(@head, "TaskPrincipalOffboardedV1", Map.put(where, "principal_id", who))

      6 ->
        event(@head, "TaskProjectOwnerAssignedV1", Map.put(where, "principal_id", who))

      _ ->
        held = for id <- w.grants, g = w.s.state.grants[id], g.principal_id == who, do: id
        grant_id = if held == [], do: "none", else: Enum.random(held)

        event(
          signer,
          "TaskCreatedV1",
          Map.merge(
            where,
            create_payload("t-#{System.unique_integer([:positive])}", who, grant_id)
          )
        )
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp grant(principal, signer, _where \\ @where),
    do: %{
      "principal_id" => principal,
      "key_id" => signer.key_id,
      "pubkey" => {:bytes, signer.pubkey}
    }

  defp kind(principal, kind), do: %{"principal_id" => principal, "kind" => kind}

  defp kind!(s, principal, k),
    do: fold!(s, event(@head, "TaskPrincipalKindDeclaredV1", kind(principal, k)))

  defp assign(s, principal, where \\ @where),
    do: admit(governed("TaskProjectOwnerAssignedV1", %{"principal_id" => principal}, where), s)

  defp assign!(s, principal, id \\ nil, where \\ @where),
    do:
      fold!(s, governed("TaskProjectOwnerAssignedV1", %{"principal_id" => principal}, where, id))

  defp create_payload(task, principal, grant),
    do:
      Map.merge(@where, %{
        "principal_id" => principal,
        "authorization_event_id" => grant,
        "lifecycle_version" => 1,
        "task_id" => task,
        "title" => "Task #{task}",
        "timing" => %{"schedule" => nil, "due_ms" => nil}
      })

  defp create(_s, task, signer \\ @ann, grant \\ "ann-grant", where \\ @where) do
    principal = %{@ann => "ann", @ann2 => "ann", @bob => "bob", @bot => "bot"}[signer]
    event(signer, "TaskCreatedV1", Map.merge(create_payload(task, principal, grant), where))
  end

  defp propose_payload(task),
    do:
      Map.merge(@where, %{
        "task_id" => task,
        "principal_id" => "ann",
        "authorization_event_id" => "ann-grant",
        "expected_version" => 1,
        "lifecycle_version" => 1
      })

  defp baseline(_s, task),
    do:
      governed("TaskBaselineRecordedV1", %{
        "task_id" => task,
        "legacy_row_id" => "row-#{task}",
        "source_digest" => {:bytes, Host.hash(task)},
        "definition_ref" => {:bytes, Host.hash(:dod)},
        "title" => "Baseline #{task}",
        "definition_of_done" => "Done"
      })

  defp gov!(s, type, payload, id \\ nil, where \\ @where),
    do: fold!(s, governed(type, payload, where, id))

  defp gov(s, type, payload, where \\ @where), do: admit(governed(type, payload, where), s)

  defp governed(type, payload, where \\ @where, id \\ nil),
    do: event(@head, type, Map.merge(where, payload), id)

  defp fold!(s, event) do
    assert admit(event, s) == :ok, "#{event.type} refused: #{inspect(admit(event, s))}"
    %{s | state: State.handle_event(event, s.state)}
  end

  defp gate(s), do: %{orchestration: s.state, role_keys: s.keys}
  defp admit(event, s), do: Admission.check(event, gate(s))

  defp event(signer, type, payload, id \\ nil),
    do: %Event{
      event_id: id || "e-#{System.unique_integer([:positive])}",
      chapter_id: @chapter,
      type: type,
      payload: payload,
      signers: [signer]
    }
end
