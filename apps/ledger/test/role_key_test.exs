defmodule CoopSubstrate.RoleKeyTest do
  @moduledoc """
  Phase 1D step 3 (docs/phase1d_plan.md P3–P4) over the real log: the
  role-key registry. Genesis is trust-on-first-use and self-certified;
  everything after is governance-signed against the registry; bootstrap
  mode closes irreversibly per role; a chapter can never orphan its own
  governance. All rejections pre-persistence, chains intact.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @chapter "chapter-genesis"

  setup do
    %{gov: new_member("governance"), steward: new_member("steward")}
  end

  defp declare(signer, role, key_owner, attrs \\ []) do
    signed_event(
      signer,
      "RoleKeyDeclared",
      %{
        "role" => role,
        "key_id" => key_owner.signer.key_id,
        "pubkey" => {:bytes, key_owner.signer.pubkey}
      },
      attrs
    )
  end

  defp revoke(signer, role, key_owner) do
    signed_event(signer, "RoleKeyRevoked", %{
      "role" => role,
      "key_id" => key_owner.signer.key_id
    })
  end

  defp genesis!(gov), do: {:ok, _} = Log.append(declare(gov, "governance", gov))

  defp assert_rejected(envelope, expected_reason) do
    before_head = Log.head()
    assert {:error, {:reject, _i, reason}} = Log.append(envelope)
    assert reason == expected_reason
    assert Log.head() == before_head
    assert :ok = Log.verify_chains()
  end

  defp role_keys(role) do
    {:ok, state} = Log.replay(Membership)
    state.role_keys[{@chapter, role}]
  end

  test "genesis: self-certified TOFU; nothing else is representable before it", ctx do
    # Pre-genesis: declaring a steward key or revoking anything is rejected.
    assert_rejected(declare(ctx.gov, "steward", ctx.steward), :genesis_required)
    assert_rejected(revoke(ctx.gov, "governance", ctx.gov), :genesis_required)

    # A genesis whose declared key is NOT the signing key is rejected.
    other = new_member("governance")
    assert_rejected(declare(ctx.gov, "governance", other), :genesis_must_be_self_signed)

    genesis!(ctx.gov)
    assert %{} = keys = role_keys("governance")
    assert keys[ctx.gov.signer.key_id] == ctx.gov.signer.pubkey
  end

  test "post-genesis declarations are governance-signed against the registry", ctx do
    genesis!(ctx.gov)

    # An undeclared governance key cannot declare anything.
    rogue = new_member("governance")

    assert_rejected(
      declare(rogue, "steward", ctx.steward),
      {:role_key_not_declared, "governance", rogue.signer.key_id}
    )

    # The declared governance key can.
    {:ok, _} = Log.append(declare(ctx.gov, "steward", ctx.steward))
    assert role_keys("steward")[ctx.steward.signer.key_id]

    # Unknown roles and duplicate keys are unrepresentable.
    assert_rejected(declare(ctx.gov, "member", ctx.steward), {:undeclarable_role, "member"})

    assert_rejected(
      declare(ctx.gov, "steward", ctx.steward),
      {:role_key_already_declared, "steward", ctx.steward.signer.key_id}
    )
  end

  test "bootstrap-then-enforce: declaring the first steward key closes the door", ctx do
    anybody = new_member("steward")

    # Bootstrap: an arbitrary steward key is accepted (pre-1D behavior).
    {:ok, _} =
      Log.append(
        signed_event(anybody, "EntityRegistered", %{
          "entity_id" => "E-boot",
          "class" => "carriers_coop"
        })
      )

    genesis!(ctx.gov)
    {:ok, _} = Log.append(declare(ctx.gov, "steward", ctx.steward))

    # Closed: the same arbitrary key is now rejected...
    assert_rejected(
      signed_event(anybody, "EntityRegistered", %{
        "entity_id" => "E-2",
        "class" => "carriers_coop"
      }),
      {:role_key_not_declared, "steward", anybody.signer.key_id}
    )

    # ...and the declared steward works.
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "EntityRegistered", %{
          "entity_id" => "E-2",
          "class" => "carriers_coop"
        })
      )
  end

  test "multiple keys per role; revocation; an emptied role stays closed", ctx do
    genesis!(ctx.gov)
    second = new_member("steward")
    {:ok, _} = Log.append(declare(ctx.gov, "steward", ctx.steward))
    {:ok, _} = Log.append(declare(ctx.gov, "steward", second))

    entity = fn steward, id ->
      signed_event(steward, "EntityRegistered", %{"entity_id" => id, "class" => "carriers_coop"})
    end

    {:ok, _} = Log.append(entity.(ctx.steward, "E-1"))
    {:ok, _} = Log.append(entity.(second, "E-2"))

    {:ok, _} = Log.append(revoke(ctx.gov, "steward", ctx.steward))

    assert_rejected(
      entity.(ctx.steward, "E-3"),
      {:role_key_not_declared, "steward", ctx.steward.signer.key_id}
    )

    {:ok, _} = Log.append(entity.(second, "E-3"))

    # Empty the role entirely: the door stays closed (no steward act at all),
    # never reopens to bootstrap.
    {:ok, _} = Log.append(revoke(ctx.gov, "steward", second))
    assert role_keys("steward") == %{}

    assert_rejected(
      entity.(second, "E-4"),
      {:role_key_not_declared, "steward", second.signer.key_id}
    )
  end

  test "a chapter can never orphan its own governance", ctx do
    genesis!(ctx.gov)

    assert_rejected(revoke(ctx.gov, "governance", ctx.gov), :cannot_orphan_governance)

    # With a second governance key, revoking one is fine; the last is not.
    gov2 = new_member("governance")
    {:ok, _} = Log.append(declare(ctx.gov, "governance", gov2))
    {:ok, _} = Log.append(revoke(gov2, "governance", ctx.gov))

    assert_rejected(
      declare(ctx.gov, "steward", ctx.steward),
      {:role_key_not_declared, "governance", ctx.gov.signer.key_id}
    )

    assert_rejected(revoke(gov2, "governance", gov2), :cannot_orphan_governance)
  end

  test "governance is chapter-scoped: another chapter stays in bootstrap", ctx do
    genesis!(ctx.gov)
    {:ok, _} = Log.append(declare(ctx.gov, "steward", ctx.steward))

    # chapter-two never declared anything: arbitrary steward still accepted.
    anybody = new_member("steward")

    {:ok, _} =
      Log.append(
        signed_event(
          anybody,
          "EntityRegistered",
          %{"entity_id" => "E-two", "class" => "carriers_coop"},
          chapter_id: "chapter-two"
        )
      )

    # And chapter-two's genesis is its own TOFU event.
    gov_two = new_member("governance")
    {:ok, _} = Log.append(declare(gov_two, "governance", gov_two, chapter_id: "chapter-two"))
  end

  test "the registry survives appender restarts", ctx do
    genesis!(ctx.gov)
    {:ok, _} = Log.append(declare(ctx.gov, "steward", ctx.steward))

    restart_log()

    anybody = new_member("steward")

    assert_rejected(
      signed_event(anybody, "EntityRegistered", %{
        "entity_id" => "E-r",
        "class" => "carriers_coop"
      }),
      {:role_key_not_declared, "steward", anybody.signer.key_id}
    )
  end
end
