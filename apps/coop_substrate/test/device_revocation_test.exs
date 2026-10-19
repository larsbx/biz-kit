defmodule CoopSubstrate.DeviceRevocationTest do
  @moduledoc """
  Revoking a device (docs/architecture/2026-10-19-device-revocation.md): its
  holder can revoke any of their own device grants in the project, from any
  device still enrolled there, including the device itself. Governance can
  revoke any grant, as before. Revocation only ever removes authority.
  """
  use ExUnit.Case, async: false
  use CoopSubstrate.LogCase

  import CoopSubstrate.TaskTimingFixtures

  alias CoopSubstrate.{Commands, Crypto, Devices, Log}

  @scope {"chapter-genesis", "tenant-1", "project-1"}

  setup do
    gov = new_member("governance")
    laptop = new_member("operator")
    phone = new_member("operator")
    bob_key = new_member("operator")
    {:ok, _} = Log.append(declare_governance(gov))

    {:ok, [laptop_grant, phone_grant, bob_grant]} =
      Log.append([
        device_grant(gov, laptop, "alice", "Laptop"),
        device_grant(gov, phone, "alice", "Phone"),
        device_grant(gov, bob_key, "bob", "Bob's laptop")
      ])

    %{
      gov: gov,
      laptop: laptop,
      phone: phone,
      bob_key: bob_key,
      laptop_grant: laptop_grant,
      phone_grant: phone_grant,
      bob_grant: bob_grant
    }
  end

  defp grant(id), do: Log.gate().orchestration.grants[id]

  test "a grant carries its device's label", w do
    assert grant(w.laptop_grant.event_id).device_label == "Laptop"
  end

  test "a lost device is revoked from another of the holder's devices", w do
    assert {:ok, [_]} = Log.append(device_revoke(w.phone, w.phone_grant, w.laptop_grant))

    refute grant(w.laptop_grant.event_id).active
    assert grant(w.phone_grant.event_id).active

    # The lost laptop can no longer act.
    assert {:error, {:reject, 0, :task_grant_revoked}} =
             Log.append(create(w.laptop, w.laptop_grant, "task-1", unscheduled()))
  end

  test "a device can revoke itself", w do
    assert {:ok, [_]} = Log.append(device_revoke(w.laptop, w.laptop_grant, w.laptop_grant))
    refute grant(w.laptop_grant.event_id).active
  end

  test "never another principal's device", w do
    assert {:error, {:reject, 0, :not_own_device}} =
             Log.append(device_revoke(w.laptop, w.laptop_grant, w.bob_grant))

    assert grant(w.bob_grant.event_id).active
  end

  test "only from a device that is itself still enrolled, with its own key", w do
    {:ok, _} = Log.append(device_revoke(w.laptop, w.laptop_grant, w.laptop_grant))

    assert {:error, {:reject, 0, :task_grant_revoked}} =
             Log.append(device_revoke(w.laptop, w.laptop_grant, w.phone_grant))

    assert {:error, {:reject, 0, :task_operator_key_mismatch}} =
             Log.append(device_revoke(w.laptop, w.phone_grant, w.phone_grant))
  end

  test "a grant is revoked once, and must exist", w do
    {:ok, _} = Log.append(device_revoke(w.phone, w.phone_grant, w.laptop_grant))

    assert {:error, {:reject, 0, :grant_already_revoked}} =
             Log.append(device_revoke(w.phone, w.phone_grant, w.laptop_grant))

    assert {:error, {:reject, 0, :unknown_task_grant}} =
             Log.append(device_revoke(w.phone, w.phone_grant, %{event_id: "no-such-grant"}))
  end

  test "delegations made from a revoked device's grant end with it", w do
    agent = as_role(new_member("operator"), "operator")
    {:ok, [delegation]} = Log.append(delegation(w.laptop, w.laptop_grant, agent, "bot"))
    {:ok, _} = Log.append(device_revoke(w.phone, w.phone_grant, w.laptop_grant))

    assert {:error, {:reject, 0, :delegator_grant_revoked}} =
             Log.append(create(agent, delegation, "task-9", timed(t0())))
  end

  test "governance can still revoke any grant", w do
    assert {:ok, [_]} = Log.append(operator_revoke(w.gov, w.bob_grant))
    refute grant(w.bob_grant.event_id).active
  end

  describe "Devices" do
    test "lists the holder's enrolled devices with their labels", w do
      labels = "alice" |> Devices.list(@scope) |> Enum.map(& &1.label) |> Enum.sort()
      assert labels == ["Laptop", "Phone"]

      {:ok, _} = Log.append(device_revoke(w.phone, w.phone_grant, w.laptop_grant))
      assert [%{label: "Phone"}] = Devices.list("alice", @scope)
    end

    test "the holder's revocation is prepared for one of their devices to sign", w do
      {:ok, held} =
        Devices.prepare_revocation(
          "alice",
          w.phone.signer.key_id,
          @scope,
          w.laptop_grant.event_id
        )

      assert held.type == "TaskDeviceRevokedV1"
      assert held.payload["revoked_grant_event_id"] == w.laptop_grant.event_id

      assert {:ok, _} =
               Commands.submit("alice", held.id, Crypto.sign(held.signing_bytes, w.phone.seed))

      refute grant(w.laptop_grant.event_id).active
    end

    test "never for another's device, nor signed by a key that is not enrolled", w do
      assert Devices.prepare_revocation(
               "alice",
               w.phone.signer.key_id,
               @scope,
               w.bob_grant.event_id
             ) ==
               {:error, :unknown_device}

      assert Devices.prepare_revocation(
               "alice",
               w.bob_key.signer.key_id,
               @scope,
               w.laptop_grant.event_id
             ) ==
               {:error, :no_operator_grant}
    end

    test "governance revokes any grant by its ID", w do
      {:ok, held} =
        Devices.prepare_governance_revocation(w.bob_grant.event_id, w.gov.signer.key_id)

      assert held.type == "TaskOperatorRevokedV1"

      other = new_member("governance")

      assert {:error, {:invalid_signature, _}} =
               Devices.revoke(
                 w.bob_grant.event_id,
                 held.id,
                 Crypto.sign(held.signing_bytes, other.seed)
               )

      {:ok, held} =
        Devices.prepare_governance_revocation(w.bob_grant.event_id, w.gov.signer.key_id)

      assert {:ok, _} =
               Devices.revoke(
                 w.bob_grant.event_id,
                 held.id,
                 Crypto.sign(held.signing_bytes, w.gov.seed)
               )

      assert Devices.prepare_governance_revocation(w.bob_grant.event_id, w.gov.signer.key_id) ==
               {:error, :grant_already_revoked}

      assert Devices.prepare_governance_revocation("no-such-grant", w.gov.signer.key_id) ==
               {:error, :unknown_grant}
    end
  end
end
