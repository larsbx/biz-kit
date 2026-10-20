defmodule CoopSubstrate.OffboardingTest do
  @moduledoc """
  Offboarding (docs/architecture/2026-10-19-offboarding.md): one governance
  event per project ends everything a principal holds there, as of its
  admission: device, suggester and reviewer grants, and delegations to or by
  them. Nothing else changes, and governance may grant the principal afresh.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Crypto, Enrolments, Feed, Log, Offboarding}
  alias CoopSubstrate.Governance.Read
  alias CoopSubstrate.Projections.Tasks, as: State

  @scope {"chapter-genesis", "tenant-1", "project-1"}
  @project_2 %{"tenant_id" => "tenant-1", "project_id" => "project-2"}

  setup do
    gov = new_member("governance")

    [laptop, phone, agent, reviewer, bob, other] =
      Enum.map(1..6, fn _ -> new_member("operator") end)

    deleg = as_role(new_member("operator"), "operator")
    {:ok, _} = Log.append(declare_governance(gov))

    {:ok, [laptop_g, phone_g, suggester_g, reviewer_g, bob_g, elsewhere_g]} =
      Log.append([
        device_grant(gov, laptop, "alice", "Laptop"),
        device_grant(gov, phone, "alice", "Phone"),
        suggester_grant(gov, as_role(agent, "suggester"), "alice"),
        reviewer_grant(gov, reviewer, "alice"),
        device_grant(gov, bob, "bob", "Bob's laptop"),
        signed_event(
          gov,
          "TaskOperatorGrantedV1",
          Map.merge(@project_2, %{
            "principal_id" => "alice",
            "key_id" => other.signer.key_id,
            "pubkey" => {:bytes, other.signer.pubkey}
          })
        )
      ])

    {:ok, [by_alice]} = Log.append(delegation(laptop, laptop_g, deleg, "alice-bot"))
    {:ok, [to_alice]} = Log.append(delegation(bob, bob_g, deleg, "alice"))

    %{
      gov: gov,
      laptop: laptop,
      bob: bob,
      deleg: deleg,
      alice: [laptop_g, phone_g, suggester_g, reviewer_g, by_alice, to_alice],
      bob_g: bob_g,
      elsewhere_g: elsewhere_g
    }
  end

  defp o, do: Log.gate().orchestration
  defp held(principal, scope \\ @scope), do: State.held_by(o(), principal, scope)
  defp ids(held), do: held |> Enum.map(&elem(&1, 1)) |> Enum.sort()

  test "ends everything the principal holds in the project, and only that", w do
    assert ids(held("alice")) == w.alice |> Enum.map(& &1.event_id) |> Enum.sort()
    assert {:ok, _} = Feed.authorize_principal("alice", @scope)

    assert {:ok, [_]} = Log.append(offboard(w.gov, "alice"))

    assert held("alice") == []
    assert Feed.authorize_principal("alice", @scope) == {:error, :no_grant}

    # The laptop, and the agent it delegated to, can no longer act.
    assert {:error, {:reject, 0, :task_grant_revoked}} =
             Log.append(create(w.laptop, hd(w.alice), "task-1", unscheduled()))

    by_alice = Enum.at(w.alice, 4)

    assert {:error, {:reject, 0, :delegation_revoked}} =
             Log.append(create(w.deleg, by_alice, "task-1", timed(t0() + 3_600_000)))

    # Bob, his own delegation's grant, and Alice's other project are untouched.
    assert o().grants[w.bob_g.event_id].active
    assert o().grants[w.elsewhere_g.event_id].active

    assert {:ok, _} =
             Feed.authorize_principal("alice", {"chapter-genesis", "tenant-1", "project-2"})
  end

  test "only with a declared governance key", w do
    assert {:error, {:reject, 0, {:role_key_not_declared, "governance", _}}} =
             Log.append(offboard(as_role(w.laptop, "governance"), "alice"))

    assert length(held("alice")) == 6
  end

  test "refused when there is nothing to end", w do
    assert {:error, {:reject, 0, :nothing_to_offboard}} = Log.append(offboard(w.gov, "nobody"))

    {:ok, _} = Log.append(offboard(w.gov, "alice"))

    assert {:error, {:reject, 0, :nothing_to_offboard}} = Log.append(offboard(w.gov, "alice"))
  end

  test "governance may grant the principal afresh; what ended stays ended", w do
    {:ok, _} = Log.append(offboard(w.gov, "alice"))

    {:ok, [fresh]} =
      Log.append(device_grant(w.gov, new_member("operator"), "alice", "New laptop"))

    assert ids(held("alice")) == [fresh.event_id]
    refute o().delegations[Enum.at(w.alice, 4).event_id].active
  end

  describe "through the server" do
    defp sign(pending, member), do: Crypto.sign(pending.signing_bytes, member.seed)

    test "lists, prepares and submits; a grant added in between ends too", w do
      %{projects: projects} = Offboarding.fetch("alice", ["chapter-genesis"])
      assert Enum.map(projects, & &1.project_id) == ["project-1", "project-2"]

      [p1, _] = projects
      kinds = p1.held |> Enum.map(&{&1.kind, &1.direction}) |> Enum.sort()

      assert kinds == [
               {"delegation", "by"},
               {"delegation", "to"},
               {"operator", nil},
               {"operator", nil},
               {"reviewer", nil},
               {"suggester", nil}
             ]

      assert Offboarding.fetch("alice", ["another-chapter"]).projects == []

      {:ok, pending} = Offboarding.prepare("alice", @scope, w.gov.signer.key_id)

      assert pending.payload == %{
               "tenant_id" => "tenant-1",
               "project_id" => "project-1",
               "principal_id" => "alice"
             }

      {:ok, [late]} = Log.append(device_grant(w.gov, new_member("operator"), "alice", "Late"))

      assert {:ok, _} = Offboarding.offboard("alice", pending.id, sign(pending, w.gov))
      assert held("alice") == []
      refute o().grants[late.event_id].active

      assert Offboarding.prepare("alice", @scope, w.gov.signer.key_id) ==
               {:error, :nothing_to_offboard}
    end

    test "only the governance key it was prepared for, and only for that principal", w do
      {:ok, pending} = Offboarding.prepare("alice", @scope, w.gov.signer.key_id)

      assert {:error, {:invalid_signature, _}} =
               Offboarding.offboard("alice", pending.id, sign(pending, w.laptop))

      {:ok, pending} = Offboarding.prepare("alice", @scope, w.gov.signer.key_id)

      assert Offboarding.offboard("bob", pending.id, sign(pending, w.gov)) ==
               {:error, :unknown_command}

      assert Offboarding.prepare("alice", @scope, w.laptop.signer.key_id) ==
               {:error, :unknown_governance_key}

      assert length(held("alice")) == 6
    end

    test "drops pending enrolment requests, even an approval already signed", w do
      key = new_member("operator")
      identity = %{issuer: "https://idp.test", subject: "sub-alice"}

      {:ok, c} =
        Enrolments.begin(
          "alice",
          identity,
          @scope,
          key.signer.key_id,
          key.signer.pubkey,
          "Tablet"
        )

      {:ok, request} = Enrolments.prove("alice", c.id, Crypto.sign(c.statement, key.seed))

      # An administrator has already prepared and signed the approval.
      {:ok, approval} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)
      approval_sig = sign(approval, w.gov)

      {:ok, pending} = Offboarding.prepare("alice", @scope, w.gov.signer.key_id)
      {:ok, _} = Offboarding.offboard("alice", pending.id, sign(pending, w.gov))

      assert Enrolments.fetch(request.code) == {:error, :unknown_code}

      assert Enrolments.approve(request.code, approval.id, approval_sig) ==
               {:error, :unknown_code}

      assert held("alice") == []
    end
  end

  describe "from the whole chapter (docs/architecture/2026-10-19-chapter-offboarding.md)" do
    alias CoopSubstrate.Administrators

    defp administrator!(gov, principal) do
      browser = new_member("governance")

      {:ok, _} =
        Log.append(
          signed_event(gov, "RoleKeyDeclared", %{
            "role" => "governance",
            "key_id" => browser.signer.key_id,
            "pubkey" => {:bytes, browser.signer.pubkey},
            "member_id" => principal
          })
        )

      browser
    end

    defp keys, do: Enum.map(Administrators.list("chapter-genesis"), & &1.key_id)

    defp signatures(batch, member),
      do: Enum.map(batch.commands, &Crypto.sign(&1.signing_bytes, member.seed))

    test "ends everything the principal holds in every project, and their administrator keys, at once",
         w do
      browser = administrator!(w.gov, "alice")

      assert %{keys: [%{chapter_id: "chapter-genesis", key_id: key}]} =
               Offboarding.fetch("alice", ["chapter-genesis"])

      assert key == browser.signer.key_id

      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)

      assert Enum.map(batch.commands, &{&1.type, &1.payload}) == [
               {"TaskPrincipalOffboardedV1",
                %{
                  "tenant_id" => "tenant-1",
                  "project_id" => "project-1",
                  "principal_id" => "alice"
                }},
               {"TaskPrincipalOffboardedV1",
                %{
                  "tenant_id" => "tenant-1",
                  "project_id" => "project-2",
                  "principal_id" => "alice"
                }},
               {"RoleKeyRevoked", %{"role" => "governance", "key_id" => key}}
             ]

      {:ok, appended} =
        Offboarding.offboard_chapter("alice", batch.id, signatures(batch, w.gov))

      # One append: consecutive positions.
      [first | _] = seqs = Enum.map(appended, & &1.global_seq)
      assert seqs == Enum.to_list(first..(first + 2))

      assert held("alice") == []
      assert held("alice", {"chapter-genesis", "tenant-1", "project-2"}) == []
      refute key in keys()

      assert Offboarding.fetch("alice", ["chapter-genesis"]) == %{
               principal_id: "alice",
               projects: [],
               keys: []
             }

      assert Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id) ==
               {:error, :nothing_to_offboard}
    end

    test "all or nothing: one bad signature, or an orphaned chapter, ends nothing", w do
      browser = administrator!(w.gov, "alice")
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)
      [_ | rest] = signatures(batch, w.gov)

      assert {:error, _} =
               Offboarding.offboard_chapter("alice", batch.id, [
                 Crypto.sign(hd(batch.commands).signing_bytes, w.laptop.seed) | rest
               ])

      assert length(held("alice")) == 6
      assert browser.signer.key_id in keys()

      # Alice's key is the chapter's last: her offboarding would orphan it.
      {:ok, _} =
        Log.append(
          signed_event(browser, "RoleKeyRevoked", %{
            "role" => "governance",
            "key_id" => w.gov.signer.key_id
          })
        )

      assert Offboarding.prepare_chapter("alice", "chapter-genesis", browser.signer.key_id) ==
               {:error, {:invalid, :cannot_orphan_governance}}

      assert length(held("alice")) == 6
    end

    test "an administrator offboarding themselves gives up the signing key last", w do
      first = administrator!(w.gov, "alice")
      second = administrator!(w.gov, "alice")

      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", second.signer.key_id)

      assert [_, _, %{payload: %{"key_id" => k1}}, %{payload: %{"key_id" => k2}}] =
               batch.commands

      assert {k1, k2} == {first.signer.key_id, second.signer.key_id}
      assert {:ok, _} = Offboarding.offboard_chapter("alice", batch.id, signatures(batch, second))
      assert keys() == [w.gov.signer.key_id]
    end

    test "drops the principal's pending requests anywhere in the chapter", w do
      key = new_member("governance")
      identity = %{issuer: "https://idp.test", subject: "sub-alice"}
      elsewhere = {"chapter-genesis", "tenant-9", "nowhere"}

      {:ok, c} =
        Enrolments.begin(
          "alice",
          identity,
          elsewhere,
          key.signer.key_id,
          key.signer.pubkey,
          "Office",
          "governance"
        )

      {:ok, request} = Enrolments.prove("alice", c.id, Crypto.sign(c.statement, key.seed))

      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)
      {:ok, _} = Offboarding.offboard_chapter("alice", batch.id, signatures(batch, w.gov))

      assert Enrolments.fetch(request.code) == {:error, :unknown_code}
    end

    test "refused, ending nothing, if what the principal holds changed since it was prepared",
         w do
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)

      # Granted afresh in a project the batch does not name, while it waited.
      {:ok, [late]} =
        Log.append(
          signed_event(
            w.gov,
            "TaskOperatorGrantedV1",
            %{
              "tenant_id" => "tenant-1",
              "project_id" => "project-3",
              "principal_id" => "alice",
              "key_id" => new_member("operator").signer.key_id,
              "pubkey" => {:bytes, new_member("operator").signer.pubkey}
            }
          )
        )

      assert Offboarding.offboard_chapter("alice", batch.id, signatures(batch, w.gov)) ==
               {:error, :holdings_changed}

      assert length(held("alice")) == 6
      assert o().grants[late.event_id].active

      # So with a key declared for them meanwhile.
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)
      browser = administrator!(w.gov, "alice")

      assert Offboarding.offboard_chapter("alice", batch.id, signatures(batch, w.gov)) ==
               {:error, :holdings_changed}

      assert browser.signer.key_id in keys()
    end

    test "a bad submission keeps the principal's pending requests", w do
      key = new_member("governance")
      identity = %{issuer: "https://idp.test", subject: "sub-alice"}

      {:ok, c} =
        Enrolments.begin(
          "alice",
          identity,
          @scope,
          key.signer.key_id,
          key.signer.pubkey,
          "Office",
          "governance"
        )

      {:ok, request} = Enrolments.prove("alice", c.id, Crypto.sign(c.statement, key.seed))
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)
      [_ | rest] = signatures(batch, w.gov)
      forged = Crypto.sign(hd(batch.commands).signing_bytes, w.laptop.seed)

      assert {:error, {:invalid_signature, _}} =
               Offboarding.offboard_chapter("alice", batch.id, [forged | rest])

      assert Offboarding.offboard_chapter("alice", batch.id, rest) == {:error, :signature_count}
      assert {:ok, _} = Enrolments.fetch(request.code)
    end

    test "a ledger change after preliminary validation rejects without losing requests", w do
      key = new_member("operator")
      identity = %{issuer: "https://idp.test", subject: "sub-alice"}

      {:ok, challenge} =
        Enrolments.begin(
          "alice",
          identity,
          {"chapter-genesis", "tenant-9", "pending-only"},
          key.signer.key_id,
          key.signer.pubkey,
          "Pending tablet"
        )

      {:ok, request} =
        Enrolments.prove("alice", challenge.id, Crypto.sign(challenge.statement, key.seed))

      {:ok, before} = Enrolments.fetch(request.code)
      {:ok, approval} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)
      approval_sig = Crypto.sign(approval.signing_bytes, w.gov.seed)
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)
      signed = signatures(batch, w.gov)
      enrolments = BizKit.Cluster.Singleton.whereis_name(Enrolments)

      # The offboarder reaches Enrolments only AFTER its preliminary holdings
      # check. Hold it there while another administrator changes the ledger.
      # This barrier forces the race; there is no scheduler/timing assumption.
      :ok = :sys.suspend(enrolments)

      result =
        try do
          task = traced_task(fn -> Offboarding.offboard_chapter("alice", batch.id, signed) end)
          pid = task.pid
          assert_receive {:trace, ^pid, :send, {:"$gen_call", _, _}, ^enrolments}, 2_000

          late_key = new_member("operator")

          {:ok, [_]} =
            Log.append(
              signed_event(w.gov, "TaskOperatorGrantedV1", %{
                "tenant_id" => "tenant-1",
                "project_id" => "project-3",
                "principal_id" => "alice",
                "key_id" => late_key.signer.key_id,
                "pubkey" => {:bytes, late_key.signer.pubkey}
              })
            )

          head = Log.head()
          :ok = :sys.resume(enrolments)
          assert Task.await(task) == {:error, :holdings_changed}
          assert Log.head() == head
          Enrolments.fetch(request.code)
        after
          :sys.resume(enrolments)
        end

      assert result == {:ok, before}
      # The failed admission spends the offboarding batch, not the request
      # or its separately held, already signed approval.
      assert Offboarding.offboard_chapter("alice", batch.id, signed) ==
               {:error, :unknown_command}

      assert {:ok, _} = Enrolments.approve(request.code, approval.id, approval_sig)
    end

    defp traced_task(fun) do
      task = Task.async(fn -> receive do: (:go -> fun.()) end)
      :erlang.trace(task.pid, true, [:send, {:tracer, self()}])
      send(task.pid, :go)
      task
    end

    defp request!(principal, scope, role) do
      key = new_member(role)
      identity = %{issuer: "https://idp.test", subject: "sub-#{principal}"}

      {:ok, challenge} =
        Enrolments.begin(
          principal,
          identity,
          scope,
          key.signer.key_id,
          key.signer.pubkey,
          "Pending #{role}",
          role
        )

      {:ok, request} =
        Enrolments.prove(principal, challenge.id, Crypto.sign(challenge.statement, key.seed))

      request
    end

    test "approvals queued during successful admission cannot restore project or administrator access",
         w do
      requests =
        for role <- ~w(operator reviewer governance) do
          request = request!("alice", @scope, role)
          {:ok, approval} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)
          {request, approval, Crypto.sign(approval.signing_bytes, w.gov.seed)}
        end

      bob = request!("bob", @scope, "operator")
      elsewhere = request!("alice", {"other-chapter", "tenant-1", "project-1"}, "operator")
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)
      signed = signatures(batch, w.gov)
      enrolments = BizKit.Cluster.Singleton.whereis_name(Enrolments)
      log = BizKit.Cluster.Singleton.whereis_name(Log)
      :ok = :sys.suspend(enrolments)
      :erlang.trace(enrolments, true, [:send, {:tracer, self()}])

      try do
        offboarding =
          traced_task(fn -> Offboarding.offboard_chapter("alice", batch.id, signed) end)

        pid = offboarding.pid
        assert_receive {:trace, ^pid, :send, {:"$gen_call", _, _}, ^enrolments}, 2_000

        # Pause actual ledger admission with the enrolment coordinator holding
        # the operation. Queue already signed approvals behind that operation.
        :ok = :sys.suspend(log)
        :ok = :sys.resume(enrolments)

        assert_receive {:trace, ^enrolments, :send, {:"$gen_call", _, {:append, _, _}}, ^log},
                       2_000

        approvals =
          for {request, approval, signature} <- requests do
            task = traced_task(fn -> Enrolments.approve(request.code, approval.id, signature) end)
            pid = task.pid
            assert_receive {:trace, ^pid, :send, {:"$gen_call", _, _}, ^enrolments}, 2_000
            task
          end

        :ok = :sys.resume(log)
        assert {:ok, _} = Task.await(offboarding)
        for task <- approvals, do: assert(Task.await(task) == {:error, :unknown_code})
      after
        :sys.resume(log)
        :sys.resume(enrolments)
        :erlang.trace(enrolments, false, [:send])
      end

      for {request, _, _} <- requests do
        assert Enrolments.fetch(request.code) == {:error, :unknown_code}
      end

      assert {:ok, _} = Enrolments.fetch(bob.code)
      assert {:ok, _} = Enrolments.fetch(elsewhere.code)

      assert Offboarding.fetch("alice", ["chapter-genesis"]) == %{
               principal_id: "alice",
               projects: [],
               keys: []
             }
    end

    test "governance refusal at admission preserves requests even when holdings are unchanged",
         w do
      alice = administrator!(w.gov, "alice")
      request = request!("alice", @scope, "operator")
      {:ok, before} = Enrolments.fetch(request.code)
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", alice.signer.key_id)
      signed = signatures(batch, alice)
      enrolments = BizKit.Cluster.Singleton.whereis_name(Enrolments)
      :ok = :sys.suspend(enrolments)

      try do
        task = traced_task(fn -> Offboarding.offboard_chapter("alice", batch.id, signed) end)
        pid = task.pid
        assert_receive {:trace, ^pid, :send, {:"$gen_call", _, _}, ^enrolments}, 2_000

        # The batch still describes Alice exactly, but admitting it now would
        # remove the last governance key. This fails AFTER the atomic guard.
        {:ok, _} =
          Log.append(
            signed_event(alice, "RoleKeyRevoked", %{
              "role" => "governance",
              "key_id" => w.gov.signer.key_id
            })
          )

        head = Log.head()
        :ok = :sys.resume(enrolments)
        assert {:error, {:reject, 2, :cannot_orphan_governance}} = Task.await(task)
        assert Log.head() == head
      after
        :sys.resume(enrolments)
      end

      assert Enrolments.fetch(request.code) == {:ok, before}
      assert alice.signer.key_id in keys()
      assert length(held("alice")) == 6
    end

    test "an approval admitted first in a named project is ended by the following offboarding",
         w do
      request = request!("alice", @scope, "operator")
      {:ok, approval} = Enrolments.prepare_approval(request.code, w.gov.signer.key_id)
      signature = Crypto.sign(approval.signing_bytes, w.gov.seed)
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)
      signed = signatures(batch, w.gov)
      enrolments = BizKit.Cluster.Singleton.whereis_name(Enrolments)
      log = BizKit.Cluster.Singleton.whereis_name(Log)
      :erlang.trace(enrolments, true, [:send, {:tracer, self()}])
      :ok = :sys.suspend(log)

      try do
        approving = Task.async(fn -> Enrolments.approve(request.code, approval.id, signature) end)
        assert_receive {:trace, ^enrolments, :send, {:"$gen_call", _, {:append, _}}, ^log}, 2_000

        offboarding =
          traced_task(fn -> Offboarding.offboard_chapter("alice", batch.id, signed) end)

        pid = offboarding.pid
        assert_receive {:trace, ^pid, :send, {:"$gen_call", _, :gate}, ^log}, 2_000

        :ok = :sys.resume(log)
        assert {:ok, grant} = Task.await(approving)
        assert {:ok, [first | _]} = Task.await(offboarding)
        assert grant.global_seq < first.global_seq
        refute o().grants[grant.event_id].active
        assert held("alice") == []
      after
        :sys.resume(log)
        :erlang.trace(enrolments, false, [:send])
      end
    end

    test "only for the principal it was prepared for, once", w do
      {:ok, batch} = Offboarding.prepare_chapter("alice", "chapter-genesis", w.gov.signer.key_id)

      assert Offboarding.offboard_chapter("bob", batch.id, signatures(batch, w.gov)) ==
               {:error, :unknown_command}

      assert Offboarding.offboard_chapter("alice", batch.id, tl(signatures(batch, w.gov))) ==
               {:error, :signature_count}

      assert {:ok, _} = Offboarding.offboard_chapter("alice", batch.id, signatures(batch, w.gov))

      assert Offboarding.offboard_chapter("alice", batch.id, signatures(batch, w.gov)) ==
               {:error, :unknown_command}
    end
  end

  describe "governance reads" do
    defp read(key_id, opts \\ []) do
      %{
        method: "GET",
        path: "/api/v1/principals/alice",
        timestamp_ms: Keyword.get(opts, :at, System.system_time(:millisecond)),
        nonce: Keyword.get(opts, :nonce, String.duplicate("n", 16)),
        key_id: key_id
      }
    end

    defp chapters(request, member, now \\ System.system_time(:millisecond)),
      do:
        Read.chapters(
          Log.gate().role_keys,
          request,
          Crypto.sign(Read.signing_bytes(request), member.seed),
          now
        )

    test "a declared governance key reads its chapters", w do
      assert chapters(read(w.gov.signer.key_id), w.gov) == {:ok, ["chapter-genesis"]}
    end

    test "refused for any other key, a stale or reused request, or another path", w do
      assert chapters(read(w.laptop.signer.key_id), w.laptop) == {:error, :not_governance}
      assert chapters(read(w.gov.signer.key_id), w.laptop) == {:error, :not_governance}

      stale = read(w.gov.signer.key_id, at: System.system_time(:millisecond) - 120_000)
      assert chapters(stale, w.gov) == {:error, :stale_request}

      assert chapters(read(w.gov.signer.key_id, nonce: "short"), w.gov) ==
               {:error, :invalid_nonce}

      request = read(w.gov.signer.key_id)
      signature = Crypto.sign(Read.signing_bytes(request), w.gov.seed)

      assert Read.chapters(
               Log.gate().role_keys,
               %{request | path: "/api/v1/principals/bob"},
               signature,
               request.timestamp_ms
             ) ==
               {:error, :not_governance}

      nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      once = read(w.gov.signer.key_id, nonce: nonce)
      once_sig = Crypto.sign(Read.signing_bytes(once), w.gov.seed)
      assert {:ok, _} = Read.authorize(once, once_sig)
      assert Read.authorize(once, once_sig) == {:error, :replayed}
    end
  end
end
