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

    test "drops the principal's pending enrolment requests in the project", w do
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

      {:ok, pending} = Offboarding.prepare("alice", @scope, w.gov.signer.key_id)
      {:ok, _} = Offboarding.offboard("alice", pending.id, sign(pending, w.gov))

      assert Enrolments.fetch(request.code) == {:error, :unknown_code}
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
