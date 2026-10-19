defmodule CoopSubstrate.OwnDevicesTest do
  @moduledoc """
  A person revokes their own devices of every kind
  (docs/architecture/2026-10-19-own-devices.md): operator and reviewer grants
  in the project, and administrator keys declared for them in the chapter,
  from any of their devices, with the command that device's role signs.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Commands, Crypto, Devices, Feed, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup do
    gov = new_member("governance")
    laptop = new_member("operator")
    tablet = new_member("reviewer")
    browser = new_member("governance")

    {:ok, [_, laptop_grant]} =
      Log.append([declare_governance(gov), operator_grant(gov, laptop, "alice")])

    {:ok, [tablet_grant]} = Log.append(reviewer_grant(gov, tablet, "alice"))
    {:ok, _} = Log.append(administrator(gov, browser, "alice"))

    %{
      gov: gov,
      laptop: laptop,
      tablet: tablet,
      browser: browser,
      laptop_grant: laptop_grant.event_id,
      tablet_grant: tablet_grant.event_id
    }
  end

  defp administrator(gov, key, principal) do
    signed_event(gov, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => key.signer.key_id,
      "pubkey" => {:bytes, key.signer.pubkey},
      "member_id" => principal
    })
  end

  # What the device does: prepare its revocation of `id`, sign, submit.
  defp revoke(device, id) do
    with {:ok, held} <- Devices.prepare_revocation("alice", device.signer.key_id, @scope, id) do
      Commands.submit("alice", held.id, Crypto.sign(held.signing_bytes, device.seed))
    end
  end

  defp kinds, do: "alice" |> Devices.list(@scope) |> Enum.map(& &1.kind)

  defp administrators,
    do: Map.keys(Log.gate().role_keys[{"chapter-genesis", "governance"}])

  test "a person's devices are their operator and reviewer grants and their administrator keys",
       w do
    assert kinds() == ["operator", "reviewer", "administrator"]

    assert %{id: id, grant_id: nil} =
             Enum.find(Devices.list("alice", @scope), &(&1.kind == "administrator"))

    assert id == w.browser.signer.key_id

    assert Devices.list("alice", {"chapter-genesis", "tenant-1", "project-2"})
           |> Enum.map(& &1.kind) == ["administrator"]
  end

  test "a reviewer device revokes itself, or the person's operator device", w do
    assert {:ok, %{type: "TaskReviewerDeviceRevokedV1"}} = revoke(w.tablet, w.laptop_grant)
    refute Log.gate().orchestration.grants[w.laptop_grant].active

    assert {:ok, %{type: "TaskReviewerDeviceRevokedV1"}} = revoke(w.tablet, w.tablet_grant)
    refute Log.gate().orchestration.dod_grants[w.tablet_grant].active
    assert kinds() == ["administrator"]
  end

  test "an operator device revokes the person's reviewer device and administrator key", w do
    assert {:ok, %{type: "TaskDeviceRevokedV1"} = env} = revoke(w.laptop, w.tablet_grant)
    assert env.payload["revoked_grant_event_id"] == w.tablet_grant
    refute Log.gate().orchestration.dod_grants[w.tablet_grant].active

    assert {:ok, %{type: "TaskDeviceRevokedV1"} = env} = revoke(w.laptop, w.browser.signer.key_id)
    assert env.payload["revoked_key_id"] == w.browser.signer.key_id
    refute w.browser.signer.key_id in administrators()

    # The key's reach ends with it: no longer an administrator's reader.
    assert Feed.authorize_principal("alice", {"chapter-genesis", "tenant-2", "p"}) ==
             {:error, :no_grant}
  end

  test "an administrator browser revokes the person's devices with governance commands", w do
    assert {:ok, %{type: "TaskOperatorRevokedV1"}} = revoke(w.browser, w.laptop_grant)
    assert {:ok, %{type: "TaskReviewerRevokedV1"}} = revoke(w.browser, w.tablet_grant)
    assert {:ok, %{type: "RoleKeyRevoked"}} = revoke(w.browser, w.browser.signer.key_id)
    assert kinds() == []
  end

  test "never another's device, nor a chapter's last administrator key", w do
    bob = new_member("operator")
    {:ok, [bob_grant]} = Log.append(operator_grant(w.gov, bob, "bob"))
    assert revoke(w.laptop, bob_grant.event_id) == {:error, :unknown_device}
    assert revoke(new_member("operator"), w.laptop_grant) == {:error, :no_device}

    # Forged directly: someone else's key, both targets, or none.
    holder = fn extra ->
      signed_event(
        w.laptop,
        "TaskDeviceRevokedV1",
        Map.merge(
          %{
            "tenant_id" => "tenant-1",
            "project_id" => "project-1",
            "principal_id" => "alice",
            "authorization_event_id" => w.laptop_grant
          },
          extra
        )
      )
    end

    assert {:error, {:reject, 0, :not_own_device}} =
             Log.append(holder.(%{"revoked_key_id" => w.gov.signer.key_id}))

    assert {:error, {:reject, 0, :invalid_revocation_target}} =
             Log.append(
               holder.(%{
                 "revoked_key_id" => w.browser.signer.key_id,
                 "revoked_grant_event_id" => w.tablet_grant
               })
             )

    assert {:error, {:reject, 0, :invalid_revocation_target}} = Log.append(holder.(%{}))

    # Alice's key as the chapter's only one: hers to give up, but not the last.
    {:ok, _} =
      Log.append(
        signed_event(w.browser, "RoleKeyRevoked", %{
          "role" => "governance",
          "key_id" => w.gov.signer.key_id
        })
      )

    assert {:error, {:invalid, :cannot_orphan_governance}} =
             revoke(w.laptop, w.browser.signer.key_id)
  end
end
