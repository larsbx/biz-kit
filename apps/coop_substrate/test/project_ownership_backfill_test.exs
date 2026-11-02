defmodule CoopSubstrate.ProjectOwnershipBackfillTest do
  @moduledoc "Governance-owned, signed and replay-safe legacy-project owner backfill."
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Crypto, Log, ProjectOwnership}
  alias TaskCore.Projects

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup do
    gov = new_member("governance")
    alice = new_member("operator")

    {:ok, [_]} = Log.append(declare_governance(gov))
    {:ok, [_]} = Log.append(operator_grant(gov, alice, "alice"))
    %{gov: gov, alice: alice}
  end

  defp o, do: Log.gate().orchestration
  defp sign(batch, gov),
    do: Enum.map(batch.commands, &Crypto.sign(&1.signing_bytes, gov.seed))

  defp device(key), do: %{key_id: key.signer.key_id, pubkey: key.signer.pubkey}

  test "ownerless legacy project is readable but not operational until backfilled", w do
    assert [%{project_id: "project-1", owner: nil}] =
             ProjectOwnership.ownerless("chapter-genesis")
    assert ProjectOwnership.ownerless("unrelated-chapter") == []
    assert Projects.accepts_work(o(), @scope) == {:error, :project_has_no_owner}

    assert {:ok, batch} =
             ProjectOwnership.prepare_backfill(
               @scope, "alice", w.gov.signer.key_id, nil
             )

    assert Enum.map(batch.commands, & &1.type) == [
             "TaskPrincipalKindDeclaredV1",
             "TaskProjectOwnerAssignedV1"
           ]

    before = Log.head()
    assert {:ok, appended} =
             ProjectOwnership.backfill(@scope, "alice", batch.id, sign(batch, w.gov))

    assert length(appended) == 2
    assert Log.head() != before
    assert Projects.owner(o(), @scope) == "alice"
    assert Projects.eligible_owner?(o(), @scope)
    assert Projects.accepts_work(o(), @scope) == :ok
    assert Projects.violations(o()) == []
    assert ProjectOwnership.ownerless("chapter-genesis") == []
    assert ProjectOwnership.prepare_backfill(@scope, "alice", w.gov.signer.key_id, nil) ==
             {:error, :project_already_owned}
  end

  test "ungranted human needs a real operator device in the same batch", w do
    key = new_member("operator")
    assert ProjectOwnership.prepare_backfill(@scope, "bob", w.gov.signer.key_id, nil) ==
             {:error, :operator_device_required}

    assert ProjectOwnership.prepare_backfill(
             @scope, "bob", w.gov.signer.key_id,
             %{key_id: key.signer.key_id, pubkey: <<0>>}
           ) == {:error, :operator_device_required}

    {:ok, batch} =
      ProjectOwnership.prepare_backfill(@scope, "bob", w.gov.signer.key_id, device(key))

    assert Enum.map(batch.commands, & &1.type) == [
             "TaskPrincipalKindDeclaredV1",
             "TaskOperatorGrantedV1",
             "TaskProjectOwnerAssignedV1"
           ]

    assert {:ok, _} =
             ProjectOwnership.backfill(@scope, "bob", batch.id, sign(batch, w.gov))

    assert Projects.owner(o(), @scope) == "bob"
    assert Projects.eligible_owner?(o(), @scope)
  end

  test "agent principals are refused; no silent conversion to human", w do
    {:ok, [_]} = Log.append(signed_event(w.gov, "TaskPrincipalKindDeclaredV1", %{
      "principal_id" => "bot", "kind" => "agent"
    }))

    assert ProjectOwnership.prepare_backfill(
             @scope, "bot", w.gov.signer.key_id, device(new_member("operator"))
           ) == {:error, :principal_not_human}

    assert Projects.owner(o(), @scope) == nil
  end

  test "stale prepared backfill refuses to overwrite a newly assigned owner", w do
    {:ok, held} =
      ProjectOwnership.prepare_backfill(@scope, "alice", w.gov.signer.key_id)

    {:ok, _} =
      Log.append([
        signed_event(w.gov, "TaskPrincipalKindDeclaredV1", %{
          "principal_id" => "alice", "kind" => "human"
        }),
        signed_event(w.gov, "TaskProjectOwnerAssignedV1", %{
          "tenant_id" => "tenant-1",
          "project_id" => "project-1",
          "principal_id" => "alice"
        })
      ])

    head = Log.head()
    assert ProjectOwnership.backfill(@scope, "alice", held.id, sign(held, w.gov)) ==
             {:error, :backfill_changed}
    assert Log.head() == head
  end

  test "a grant added after preparation invalidates stale backfill", w do
    bob = new_member("operator")
    {:ok, held} =
      ProjectOwnership.prepare_backfill(@scope, "bob", w.gov.signer.key_id, device(bob))

    {:ok, [_]} = Log.append(operator_grant(w.gov, bob, "bob"))
    head = Log.head()

    assert ProjectOwnership.backfill(@scope, "bob", held.id, sign(held, w.gov)) ==
             {:error, :backfill_changed}
    assert Log.head() == head
  end

  test "foreign scope, unknown project and unknown governance key are refused", w do
    assert ProjectOwnership.prepare_backfill(
             {"other-chapter", "tenant-1", "project-1"}, "alice", w.gov.signer.key_id
           ) == {:error, :unknown_legacy_project}

    assert ProjectOwnership.prepare_backfill(
             {"chapter-genesis", "tenant-2", "project-1"}, "alice", w.gov.signer.key_id
           ) == {:error, :unknown_legacy_project}

    assert ProjectOwnership.prepare_backfill(
             @scope, "alice", "unknown-governance-key"
           ) == {:error, :unknown_governance_key}
  end
end
