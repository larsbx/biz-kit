defmodule CoopSubstrate.MembershipGateTest do
  @moduledoc """
  Phase 1B acceptance item 10 over the real log: every membership transition
  is a signed event; illegal facts are rejected AT THE APPEND GATE — before
  persistence — leaving the log unchanged and both chains intact; dual
  membership across entities works; member-role signatures must come from
  the member's currently registered key.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"

  setup do
    %{steward: new_member("steward"), member: new_member("member")}
  end

  defp register!(%{steward: steward, member: member}, opts \\ []) do
    chapter = Keyword.get(opts, :chapter_id, @chapter)

    {:ok, _} =
      Log.append(
        signed_event(
          steward,
          "EntityRegistered",
          %{"entity_id" => @entity, "class" => "carriers_coop"},
          chapter_id: chapter
        )
      )

    {:ok, _} =
      Log.append(
        signed_event(member, "MemberRegistered", registration_payload(@member, member),
          chapter_id: chapter
        )
      )

    :ok
  end

  defp membership_payload, do: %{"member_id" => @member, "entity_id" => @entity}

  defp invite(steward, attrs \\ []) do
    signed_event(
      steward,
      "MembershipInvited",
      Map.put(membership_payload(), "class", "carriers_coop"),
      attrs
    )
  end

  defp membership_state do
    {:ok, state} = Log.replay(Membership)
    Membership.membership(state, @chapter, @member, @entity)
  end

  defp assert_rejected_without_persisting(envelope_or_batch, expected_reason) do
    before_head = Log.head()

    assert {:error, {:reject, _index, reason}} = Log.append(envelope_or_batch)
    assert reason == expected_reason

    assert Log.head() == before_head
    assert :ok = Log.verify_chains()
  end

  test "lifecycle events require a registered member and entity", ctx do
    assert_rejected_without_persisting(invite(ctx.steward), {:unregistered_member, @member})

    {:ok, _} =
      Log.append(
        signed_event(ctx.member, "MemberRegistered", registration_payload(@member, ctx.member))
      )

    assert_rejected_without_persisting(invite(ctx.steward), {:unregistered_entity, @entity})
  end

  test "duplicate registrations are rejected", ctx do
    register!(ctx)

    assert_rejected_without_persisting(
      signed_event(ctx.steward, "EntityRegistered", %{
        "entity_id" => @entity,
        "class" => "workers_coop"
      }),
      {:entity_already_registered, @entity}
    )

    other_keypair = new_member("member")

    assert_rejected_without_persisting(
      signed_event(other_keypair, "MemberRegistered", registration_payload(@member, other_keypair)),
      {:member_already_registered, @member}
    )
  end

  test "member registration must be self-signed by the registered key", ctx do
    foreign = new_member("member")

    payload = %{
      "member_id" => @member,
      "pubkey" => {:bytes, foreign.signer.pubkey},
      "key_id" => foreign.signer.key_id
    }

    # ctx.member signs, but the payload registers a DIFFERENT key.
    assert_rejected_without_persisting(
      signed_event(ctx.member, "MemberRegistered", payload),
      :registration_must_be_self_signed
    )
  end

  test "unknown entity class is rejected", ctx do
    assert_rejected_without_persisting(
      signed_event(ctx.steward, "EntityRegistered", %{
        "entity_id" => @entity,
        "class" => "surveillance_coop"
      }),
      {:unknown_entity_class, "surveillance_coop"}
    )
  end

  test "the full lifecycle happy path, each transition a signed event", ctx do
    register!(ctx)

    {:ok, _} = Log.append(invite(ctx.steward))
    assert %{state: :invited, class: "carriers_coop"} = membership_state()

    {:ok, _} =
      Log.append(signed_event(ctx.member, "MembershipProbationStarted", membership_payload()))

    assert %{state: :probationary} = membership_state()

    # Dual-signed confirmation: member + steward over the same core.
    {:ok, _} =
      Log.append(
        multi_signed_event([ctx.member, ctx.steward], "MembershipConfirmed", membership_payload())
      )

    assert %{state: :member} = membership_state()

    {:ok, _} = Log.append(signed_event(ctx.member, "MembershipRetired", membership_payload()))
    assert %{state: :retired} = membership_state()
    assert :ok = Log.verify_chains()
  end

  test "illegal transitions are rejected before persistence", ctx do
    register!(ctx)
    {:ok, _} = Log.append(invite(ctx.steward))

    # Confirm straight from :invited (must pass through probation).
    assert_rejected_without_persisting(
      multi_signed_event([ctx.member, ctx.steward], "MembershipConfirmed", membership_payload()),
      {:illegal_transition, "MembershipConfirmed", :invited}
    )

    # Retire from :invited.
    assert_rejected_without_persisting(
      signed_event(ctx.member, "MembershipRetired", membership_payload()),
      {:illegal_transition, "MembershipRetired", :invited}
    )

    # Second invite over an existing membership.
    assert_rejected_without_persisting(
      invite(ctx.steward),
      {:illegal_transition, "MembershipInvited", :invited}
    )
  end

  test "terminal states accept no further lifecycle events", ctx do
    register!(ctx)
    {:ok, _} = Log.append(invite(ctx.steward))

    {:ok, _} =
      Log.append(
        signed_event(ctx.member, "MembershipDeparted", membership_payload(), [])
      )

    assert %{state: :departed} = membership_state()

    assert_rejected_without_persisting(
      signed_event(ctx.member, "MembershipProbationStarted", membership_payload()),
      {:illegal_transition, "MembershipProbationStarted", :departed}
    )
  end

  test "invited class must match the entity's registered class", ctx do
    register!(ctx)

    assert_rejected_without_persisting(
      signed_event(
        ctx.steward,
        "MembershipInvited",
        Map.put(membership_payload(), "class", "workers_coop")
      ),
      {:class_mismatch, "workers_coop", "carriers_coop"}
    )
  end

  test "member-role signatures must use the member's current registered key", ctx do
    register!(ctx)
    {:ok, _} = Log.append(invite(ctx.steward))

    imposter = new_member("member")

    assert_rejected_without_persisting(
      signed_event(imposter, "MembershipProbationStarted", membership_payload()),
      {:not_the_members_current_key, imposter.signer.key_id}
    )

    # Rotate to a new key: the OLD key is now rejected, the new one accepted.
    rotated = new_member("member")

    {:ok, _} =
      Log.append(
        signed_event(new_member("author"), "KeyRotated", %{
          "member_id" => @member,
          "old_key_id" => ctx.member.signer.key_id,
          "new_key_id" => rotated.signer.key_id,
          "new_pubkey" => {:bytes, rotated.signer.pubkey}
        })
      )

    assert_rejected_without_persisting(
      signed_event(ctx.member, "MembershipProbationStarted", membership_payload()),
      {:not_the_members_current_key, ctx.member.signer.key_id}
    )

    {:ok, _} =
      Log.append(signed_event(rotated, "MembershipProbationStarted", membership_payload()))

    assert %{state: :probationary} = membership_state()
  end

  test "dual membership: one person-key, two entities, independent records", ctx do
    register!(ctx)

    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "EntityRegistered", %{
          "entity_id" => "E-mech-1",
          "class" => "mechanics_coop"
        })
      )

    {:ok, _} = Log.append(invite(ctx.steward))

    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "MembershipInvited", %{
          "member_id" => @member,
          "entity_id" => "E-mech-1",
          "class" => "mechanics_coop"
        })
      )

    # Advance only the carrier membership; the mechanic one stays invited.
    {:ok, _} =
      Log.append(signed_event(ctx.member, "MembershipProbationStarted", membership_payload()))

    {:ok, state} = Log.replay(Membership)

    assert [{"E-carrier-1", %{state: :probationary, class: "carriers_coop"}},
            {"E-mech-1", %{state: :invited, class: "mechanics_coop"}}] =
             state |> Membership.memberships_of(@chapter, @member) |> Enum.sort()
  end

  test "batches are atomic: a later-invalid event aborts earlier-valid ones", ctx do
    register!(ctx)

    batch = [
      invite(ctx.steward),
      # Illegal from :invited — the whole batch must vanish, including the
      # valid invite before it.
      signed_event(ctx.member, "MembershipRetired", membership_payload())
    ]

    assert_rejected_without_persisting(
      batch,
      {:illegal_transition, "MembershipRetired", :invited}
    )

    assert membership_state() == nil
  end

  test "intra-batch visibility: registration and first transitions in ONE atomic append", ctx do
    batch = [
      signed_event(ctx.steward, "EntityRegistered", %{
        "entity_id" => @entity,
        "class" => "carriers_coop"
      }),
      signed_event(ctx.member, "MemberRegistered", registration_payload(@member, ctx.member)),
      invite(ctx.steward),
      signed_event(ctx.member, "MembershipProbationStarted", membership_payload())
    ]

    assert {:ok, _} = Log.append(batch)
    assert %{state: :probationary} = membership_state()
  end

  test "chapter isolation: registrations in one chapter do not exist in another", ctx do
    register!(ctx)

    assert_rejected_without_persisting(
      invite(ctx.steward, chapter_id: "chapter-two"),
      {:unregistered_member, @member}
    )
  end

  # -- Phase 1C: floor cure/hardship states over the real log ------------------

  test "cure round-trip: member → in_cure → member, and in_cure → floor_exited", ctx do
    :ok = seed_membership!(ctx.steward, ctx.member, @member, @entity)

    {:ok, _} = Log.append(signed_event(ctx.steward, "FloorCureStarted", membership_payload()))
    assert %{state: :in_cure} = membership_state()

    {:ok, _} = Log.append(signed_event(ctx.steward, "FloorCureCleared", membership_payload()))
    assert %{state: :member} = membership_state()

    {:ok, _} = Log.append(signed_event(ctx.steward, "FloorCureStarted", membership_payload()))

    {:ok, _} =
      Log.append(signed_event(ctx.steward, "MembershipFloorExited", membership_payload()))

    assert %{state: :floor_exited} = membership_state()
    assert :ok = Log.verify_chains()
  end

  test "hardship round-trip is member-signed; cure cannot start from hardship", ctx do
    :ok = seed_membership!(ctx.steward, ctx.member, @member, @entity)

    {:ok, _} = Log.append(signed_event(ctx.member, "HardshipDeclared", membership_payload()))
    assert %{state: :hardship} = membership_state()

    assert_rejected_without_persisting(
      signed_event(ctx.steward, "FloorCureStarted", membership_payload()),
      {:illegal_transition, "FloorCureStarted", :hardship}
    )

    # Floor exit from hardship is illegal too (hardship suspends the floor).
    assert_rejected_without_persisting(
      signed_event(ctx.steward, "MembershipFloorExited", membership_payload()),
      {:illegal_transition, "MembershipFloorExited", :hardship}
    )

    {:ok, _} = Log.append(signed_event(ctx.member, "HardshipEnded", membership_payload()))
    assert %{state: :member} = membership_state()
  end

  test "hardship declaration must use the member's current key", ctx do
    :ok = seed_membership!(ctx.steward, ctx.member, @member, @entity)

    imposter = new_member("member")

    assert_rejected_without_persisting(
      signed_event(imposter, "HardshipDeclared", membership_payload()),
      {:not_the_members_current_key, imposter.signer.key_id}
    )
  end

  test "departure and death remain reachable from cure and hardship", ctx do
    :ok = seed_membership!(ctx.steward, ctx.member, @member, @entity)

    {:ok, _} = Log.append(signed_event(ctx.steward, "FloorCureStarted", membership_payload()))
    {:ok, _} = Log.append(signed_event(ctx.member, "MembershipDeparted", membership_payload()))
    assert %{state: :departed} = membership_state()
  end

  test "the gate state survives appender restarts (rebuilt from the ledger)", ctx do
    register!(ctx)
    {:ok, _} = Log.append(invite(ctx.steward))

    restart_log()

    # Still knows the membership is :invited — illegal transition rejected...
    assert_rejected_without_persisting(
      signed_event(ctx.member, "MembershipRetired", membership_payload()),
      {:illegal_transition, "MembershipRetired", :invited}
    )

    # ...and the legal one accepted.
    {:ok, _} =
      Log.append(signed_event(ctx.member, "MembershipProbationStarted", membership_payload()))

    assert %{state: :probationary} = membership_state()
  end
end
