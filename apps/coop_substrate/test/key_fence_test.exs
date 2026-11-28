defmodule CoopSubstrate.KeyFenceTest do
  @moduledoc """
  The chapter key fence at the append gate and at Commands preflight. Within a
  chapter, no restaurant grant holds a declared role key, and no role key is
  declared on a key the chapter ever granted, revoked or not. A revoked role
  key is forgotten, so it may be granted later. Another chapter's keys never
  count, and a domain refusal comes before the fence's.
  """
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{Commands, Constants, KeyFence, Log}

  @ch "chapter-genesis"
  @other "chapter-two"

  setup do
    gov = new_member("governance")
    {:ok, _} = Log.append(declare(gov, "governance", gov.signer.key_id, gov))
    {:ok, gov: gov}
  end

  defp declare(gov, role, key_id, key, chapter \\ @ch),
    do:
      signed_event(
        gov,
        "RoleKeyDeclared",
        %{"role" => role, "key_id" => key_id, "pubkey" => {:bytes, key.signer.pubkey}},
        chapter_id: chapter
      )

  defp device_payload(merchant, key_id, key),
    do: %{
      "merchant_id" => merchant,
      "device_id" => "device-" <> key_id,
      "key_id" => key_id,
      "pubkey" => {:bytes, key.signer.pubkey},
      "actor" => "staff",
      "actions" => ["accept"]
    }

  defp device(gov, merchant, key_id, key, chapter \\ @ch),
    do:
      signed_event(gov, "RestaurantDeviceGrantedV1", device_payload(merchant, key_id, key),
        chapter_id: chapter
      )

  defp revoke_device(gov, merchant, key_id),
    do:
      signed_event(gov, "RestaurantDeviceRevokedV1", %{
        "merchant_id" => merchant,
        "key_id" => key_id
      })

  defp revoke_role(gov, role, key_id),
    do: signed_event(gov, "RoleKeyRevoked", %{"role" => role, "key_id" => key_id})

  # A fresh key, declared in `role` under the key ID "k-<role>".
  defp declared(gov, role) do
    key = new_member()
    {:ok, _} = Log.append(declare(gov, role, "k-" <> role, key))
    key
  end

  defp refused(event, reason \\ :key_not_separate) do
    head = Log.head()
    assert Log.append(event) == {:error, {:reject, 0, reason}}, event.type
    assert Log.head() == head
  end

  test "a device grant on any declared role key appends nothing", %{gov: gov} do
    for role <- Constants.declarable_roles() do
      key = if role == "governance", do: gov, else: declared(gov, role)
      refused(device(gov, "shop", "board-" <> role, key))
    end
  end

  test "no key the chapter granted, revoked or not, is declared a role key", %{gov: gov} do
    active = new_member()
    revoked = new_member()

    {:ok, _} =
      Log.append([
        device(gov, "shop", "pos", active),
        device(gov, "shop", "old", revoked),
        revoke_device(gov, "shop", "old")
      ])

    for role <- Constants.declarable_roles(),
        key <- [active, revoked],
        do: refused(declare(gov, role, "k-" <> role, key))

    assert {:ok, _} = Log.append(declare(gov, "steward", "k-fresh", new_member()))
  end

  test "a revoked role key is forgotten: it may be granted, and is then never declared again",
       %{gov: gov} do
    steward = declared(gov, "steward")
    {:ok, _} = Log.append(revoke_role(gov, "steward", "k-steward"))

    assert {:ok, _} = Log.append(device(gov, "shop", "board", steward))
    refused(declare(gov, "steward", "k-again", steward))
  end

  test "role plus role breaks nothing: one key may serve several roles", %{gov: gov} do
    steward = declared(gov, "steward")

    assert {:ok, _} =
             Log.append([
               declare(gov, "checkpoint", "k-checkpoint", steward),
               declare(gov, "commercial_setoff_reviewer", "k-reviewer", gov)
             ])
  end

  test "another chapter's keys never count", %{gov: gov} do
    other_gov = new_member("governance")
    steward = declared(gov, "steward")
    board = new_member()

    {:ok, _} =
      Log.append([
        declare(other_gov, "governance", other_gov.signer.key_id, other_gov, @other),
        device(gov, "shop", "board", board)
      ])

    assert {:ok, _} =
             Log.append([
               device(other_gov, "shop", "board", steward, @other),
               device(other_gov, "deli", "gov", gov, @other),
               declare(other_gov, "checkpoint", "k-checkpoint", board, @other),
               device(gov, "deli", "other-gov", other_gov)
             ])
  end

  test "a domain refusal comes before the fence's", %{gov: gov} do
    steward = declared(gov, "steward")
    pos = new_member()
    {:ok, _} = Log.append(device(gov, "shop", "pos", pos))

    refused(device(gov, "shop", "pos", steward), :restaurant_key_already_granted)

    refused(
      declare(gov, "steward", "k-steward", pos),
      {:role_key_already_declared, "steward", "k-steward"}
    )
  end

  test "names each holding a claim breaks against, and claims nothing else", %{gov: gov} do
    pos = new_member()

    {:ok, _} =
      Log.append([device(gov, "shop", "pos", pos), revoke_device(gov, "shop", "pos")])

    gate = Log.gate()

    assert KeyFence.holdings(gate, @ch, pos.signer.pubkey) ==
             [{:restaurant_core, {:grant, "shop", "pos"}}]

    assert KeyFence.holdings(gate, @ch, gov.signer.pubkey) ==
             [{:restaurant_core, {:role, "governance", gov.signer.key_id}}]

    assert KeyFence.holdings(gate, @other, pos.signer.pubkey) == []

    assert KeyFence.conflicts(declare(gov, "checkpoint", "k-checkpoint", pos), gate) ==
             [{:device_role_key_reuse, {:grant, "shop", "pos"}}]

    assert KeyFence.conflicts(device(gov, "deli", "board", gov), gate) ==
             [{:device_role_key_reuse, {:role, "governance", gov.signer.key_id}}]

    # As history from before the fence may hold: pos declared after its grant.
    # A claim at its merchant breaks both rules and is refused as separate.
    held = put_in(gate, [:role_keys, {@ch, "checkpoint"}], %{"k-pos" => pos.signer.pubkey})
    board = device(gov, "shop", "board", pos)

    assert KeyFence.conflicts(board, held) == [
             {:device_role_key_reuse, {:role, "checkpoint", "k-pos"}},
             {:merchant_key_reuse, {:grant, "shop", "pos"}}
           ]

    assert KeyFence.check(board, held) == {:error, :key_not_separate}

    assert KeyFence.holder(revoke_device(gov, "shop", "pos")) == nil
    assert KeyFence.conflicts(revoke_device(gov, "shop", "pos"), gate) == []
    assert KeyFence.conflicts(revoke_role(gov, "governance", gov.signer.key_id), gate) == []

    assert Map.new(KeyFence.rules(), &{&1, KeyFence.refusal(&1)}) == %{
             device_dispatch_key_reuse: :key_not_separate,
             device_role_key_reuse: :key_not_separate,
             dispatch_role_key_reuse: :key_not_separate,
             dispatch_cross_tenant_key_reuse: :key_not_separate,
             merchant_key_reuse: :restaurant_key_already_granted,
             holder_key_reuse: :key_not_separate
           }
  end

  test "Commands preflight refuses the claim before anyone signs", %{gov: gov} do
    steward = declared(gov, "steward")
    pos = new_member()
    {:ok, _} = Log.append(device(gov, "shop", "pos", pos))

    assert Commands.hold(
             :key_fence_test,
             @ch,
             "RestaurantDeviceGrantedV1",
             device_payload("shop", "board", steward),
             gov.signer
           ) == {:error, {:invalid, :key_not_separate}}

    assert Commands.hold(
             :key_fence_test,
             @ch,
             "RoleKeyDeclared",
             %{
               "role" => "checkpoint",
               "key_id" => "k-pos",
               "pubkey" => {:bytes, pos.signer.pubkey}
             },
             gov.signer
           ) == {:error, {:invalid, :key_not_separate}}
  end
end
