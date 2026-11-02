defmodule CoopSubstrate.OwnerSuccessionTest do
  @moduledoc """
  Chapter offboarding with accountable project-owner succession: one signed
  atomic batch, strictly derived from the authoritative ledger state.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Crypto, Log, Offboarding}
  alias TaskCore.{Projects, State}

  @scope {"chapter-genesis", "tenant-1", "project-1"}
  @second_scope {"chapter-genesis", "tenant-1", "project-2"}
  @successors %{{"tenant-1", "project-1"} => "alice"}

  setup do
    gov = new_member("governance")
    alice = new_member("operator")

    {:ok, _} = Log.append([declare_governance(gov) | project_owner(gov)])
    {:ok, [_]} = Log.append(operator_grant(gov, alice, "alice"))

    {:ok, [_]} =
      Log.append(
        signed_event(gov, "TaskPrincipalKindDeclaredV1", %{
          "principal_id" => "alice",
          "kind" => "human"
        })
      )

    %{gov: gov}
  end

  defp o, do: Log.gate().orchestration
  defp signatures(batch, gov),
    do: Enum.map(batch.commands, &Crypto.sign(&1.signing_bytes, gov.seed))

  defp grant(gov, scope, principal) do
    device = new_member("operator")

    signed_event(gov, "TaskOperatorGrantedV1", %{
      "tenant_id" => elem(scope, 1),
      "project_id" => elem(scope, 2),
      "principal_id" => principal,
      "key_id" => device.signer.key_id,
      "pubkey" => {:bytes, device.signer.pubkey}
    })
  end

  defp assign(gov, scope, principal) do
    signed_event(gov, "TaskProjectOwnerAssignedV1", %{
      "tenant_id" => elem(scope, 1),
      "project_id" => elem(scope, 2),
      "principal_id" => principal
    })
  end

  test "offboarding read reports accountable owner and necessary succession", _w do
    %{projects: [owned]} = Offboarding.fetch("owner", ["chapter-genesis"])
    assert owned.accountable_owner == "owner"
    assert owned.successor_required
    assert owned.owner_eligible

    %{projects: [other]} = Offboarding.fetch("alice", ["chapter-genesis"])
    assert other.accountable_owner == "owner"
    refute other.successor_required
    assert other.owner_eligible

    assert Offboarding.fetch("owner", ["another-chapter"]).projects == []
  end

  test "a departing owner needs a successor, signed in the same batch", w do
    assert Offboarding.prepare_chapter("owner", "chapter-genesis", w.gov.signer.key_id) ==
             {:error, {:successor_required, [{"tenant-1", "project-1"}]}}

    assert {:ok, batch} =
             Offboarding.prepare_chapter(
               "owner", "chapter-genesis", w.gov.signer.key_id, @successors
             )

    assert Enum.map(batch.commands, & &1.type) == [
             "TaskPrincipalOffboardedV1",
             "TaskProjectOwnerAssignedV1"
           ]

    before = Log.head()
    assert Projects.owner(o(), @scope) == "owner"
    assert {:ok, appended} =
             Offboarding.offboard_chapter("owner", batch.id, signatures(batch, w.gov))

    assert length(appended) == 2
    assert Log.head() != before
    assert Projects.owner(o(), @scope) == "alice"
    assert Projects.eligible_owner?(o(), @scope)
    assert State.held_by(o(), "owner", @scope) == []
    assert Projects.violations(o()) == []
  end

  test "only an eligible successor in an owned project can be nominated", w do
    assert Offboarding.prepare_chapter(
             "owner", "chapter-genesis", w.gov.signer.key_id,
             %{{"tenant-1", "project-2"} => "alice"}
           ) == {:error, {:successor_required, [{"tenant-1", "project-1"}]}}

    assert Offboarding.prepare_chapter(
             "owner", "chapter-genesis", w.gov.signer.key_id,
             Map.put(@successors, {"tenant-1", "project-2"}, "alice")
           ) == {:error, :unexpected_successor_project}

    assert Offboarding.prepare_chapter(
             "owner", "chapter-genesis", w.gov.signer.key_id,
             %{{"tenant-1", "project-1"} => ""}
           ) == {:error, :invalid_successors}

    assert Offboarding.prepare_chapter(
             "owner", "chapter-genesis", w.gov.signer.key_id,
             %{{"tenant-1", "project-1"} => "undeclared"}
           ) == {:error, {:invalid, :project_owner_ineligible}}

    {:ok, _} = Log.append([
      signed_event(w.gov, "TaskPrincipalKindDeclaredV1", %{
        "principal_id" => "bot", "kind" => "agent"
      }),
      grant(w.gov, @scope, "bot")
    ])

    assert Offboarding.prepare_chapter(
             "owner", "chapter-genesis", w.gov.signer.key_id,
             %{{"tenant-1", "project-1"} => "bot"}
           ) == {:error, {:invalid, :project_owner_ineligible}}

    assert Projects.owner(o(), @scope) == "owner"
  end

  test "an owner of two projects must have a successor for both", w do
    {:ok, _} = Log.append([
      grant(w.gov, @second_scope, "owner"),
      assign(w.gov, @second_scope, "owner"),
      grant(w.gov, @second_scope, "alice")
    ])

    assert Offboarding.prepare_chapter(
             "owner", "chapter-genesis", w.gov.signer.key_id, @successors
           ) == {:error, {:successor_required, [{"tenant-1", "project-2"}]}}

    selections = Map.put(@successors, {"tenant-1", "project-2"}, "alice")
    {:ok, batch} =
      Offboarding.prepare_chapter("owner", "chapter-genesis", w.gov.signer.key_id, selections)

    assert Enum.map(batch.commands, & &1.type) == [
             "TaskPrincipalOffboardedV1",
             "TaskPrincipalOffboardedV1",
             "TaskProjectOwnerAssignedV1",
             "TaskProjectOwnerAssignedV1"
           ]

    assert {:ok, _} =
             Offboarding.offboard_chapter("owner", batch.id, signatures(batch, w.gov))

    for scope <- [@scope, @second_scope] do
      assert Projects.owner(o(), scope) == "alice"
      assert Projects.eligible_owner?(o(), scope)
      assert State.held_by(o(), "owner", scope) == []
    end
  end

  test "owner changed after preparation invalidates the held batch without offboarding", w do
    {:ok, batch} =
      Offboarding.prepare_chapter("owner", "chapter-genesis", w.gov.signer.key_id, @successors)

    {:ok, [_]} = Log.append(assign(w.gov, @scope, "alice"))
    head = Log.head()

    assert Offboarding.offboard_chapter("owner", batch.id, signatures(batch, w.gov)) ==
             {:error, :holdings_changed}

    assert Log.head() == head
    assert Projects.owner(o(), @scope) == "alice"
    refute State.held_by(o(), "owner", @scope) == []
  end

  test "new grants acquired during preparation invalidate the signed batch", w do
    {:ok, batch} =
      Offboarding.prepare_chapter("owner", "chapter-genesis", w.gov.signer.key_id, @successors)

    {:ok, [_]} = Log.append(grant(w.gov, @second_scope, "owner"))
    head = Log.head()

    assert Offboarding.offboard_chapter("owner", batch.id, signatures(batch, w.gov)) ==
             {:error, :holdings_changed}

    assert Log.head() == head
    assert Projects.owner(o(), @scope) == "owner"
  end
end
