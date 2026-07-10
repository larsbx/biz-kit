defmodule CoopSubstrate.RedemptionTest do
  @moduledoc """
  Phase 1B redemption DATA STRUCTURES (hand-off §2.3: multi-year payout,
  annual cap, FIFO, sinking fund, death-to-estate — modeled now, workflow
  later): schedules open only on redeemable accounts, payments consume
  accrual entries FIFO, and the entity's sinking fund tracks the accounting.
  Cap/eligibility ENFORCEMENT is deferred workflow (docs/phase1b_plan.md).
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Capital
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"

  setup do
    steward = new_member("steward")
    member = new_member("member")

    seed_membership!(steward, member, @member, @entity)

    {:ok, _} =
      Log.append(
        signed_event(steward, "AccrualRuleActivated", %{
          "rule_id" => "capital-accrual-v1",
          "params" => %{}
        })
      )

    %{steward: steward, member: member}
  end

  defp patronage!(steward, amount) do
    {:ok, _} =
      Log.append(
        signed_event(steward, "PatronageRecorded", %{
          "member_id" => @member,
          "entity_id" => @entity,
          "kind" => "delivery",
          "amount_minor" => amount
        })
      )
  end

  defp retire!(member) do
    {:ok, _} =
      Log.append(
        signed_event(member, "MembershipRetired", %{
          "member_id" => @member,
          "entity_id" => @entity
        })
      )
  end

  defp schedule_payload(overrides \\ %{}) do
    Map.merge(
      %{
        "member_id" => @member,
        "entity_id" => @entity,
        "years" => 5,
        "annual_cap_minor" => 10_000,
        "method" => "fifo"
      },
      overrides
    )
  end

  defp pay!(steward, amount) do
    {:ok, _} =
      Log.append(
        signed_event(steward, "RedemptionPaid", %{
          "member_id" => @member,
          "entity_id" => @entity,
          "amount_minor" => amount
        })
      )
  end

  test "a schedule opens only on a redeemable (terminal) account", ctx do
    patronage!(ctx.steward, 100)

    assert {:error, {:reject, 0, {:account_not_redeemable, :member}}} =
             Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))

    retire!(ctx.member)
    assert {:ok, _} = Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))

    {:ok, account} = Capital.account(@chapter, @member, @entity)
    assert account.status == :in_redemption

    assert %{years: 5, annual_cap_minor: 10_000, method: "fifo", payments: []} =
             account.schedule

    # A second schedule cannot open over an open one.
    assert {:error, {:reject, 0, :schedule_already_open}} =
             Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))
  end

  test "schedule terms are validated at the gate", ctx do
    retire!(ctx.member)

    assert {:error, {:reject, 0, :bad_schedule_terms}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "RedemptionScheduleOpened",
                 schedule_payload(%{"years" => 0})
               )
             )

    assert {:error, {:reject, 0, {:unknown_redemption_method, "lifo"}}} =
             Log.append(
               signed_event(
                 ctx.steward,
                 "RedemptionScheduleOpened",
                 schedule_payload(%{"method" => "lifo"})
               )
             )
  end

  test "payments require an open schedule and consume entries FIFO", ctx do
    assert {:error, {:reject, 0, :no_open_schedule}} =
             Log.append(
               signed_event(ctx.steward, "RedemptionPaid", %{
                 "member_id" => @member,
                 "entity_id" => @entity,
                 "amount_minor" => 10
               })
             )

    patronage!(ctx.steward, 60)
    patronage!(ctx.steward, 40)
    retire!(ctx.member)

    {:ok, _} = Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))

    pay!(ctx.steward, 70)

    {:ok, account} = Capital.account(@chapter, @member, @entity)
    assert account.redeemed_minor == 70
    assert {:ok, 30} = Capital.balance(@chapter, @member, @entity)

    # FIFO: the oldest entry is fully consumed first.
    assert [%{credited_minor: 60, remaining_minor: 0}, %{credited_minor: 40, remaining_minor: 30}] =
             account.entries

    assert [%{amount_minor: 70}] = account.schedule.payments

    pay!(ctx.steward, 30)
    {:ok, account} = Capital.account(@chapter, @member, @entity)
    assert {:ok, 0} = Capital.balance(@chapter, @member, @entity)
    assert Enum.all?(account.entries, &(&1.remaining_minor == 0))
    assert length(account.schedule.payments) == 2
  end

  test "the sinking fund accumulates contributions and is drawn by payments", ctx do
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "SinkingFundContributed", %{
          "entity_id" => @entity,
          "amount_minor" => 500
        })
      )

    assert {:ok, 500} = Capital.sinking_fund(@chapter, @entity)

    patronage!(ctx.steward, 100)
    retire!(ctx.member)
    {:ok, _} = Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))
    pay!(ctx.steward, 70)

    assert {:ok, 430} = Capital.sinking_fund(@chapter, @entity)

    # Contributions are gated: entity must exist, amount positive.
    assert {:error, {:reject, 0, {:unregistered_entity, "E-ghost"}}} =
             Log.append(
               signed_event(ctx.steward, "SinkingFundContributed", %{
                 "entity_id" => "E-ghost",
                 "amount_minor" => 1
               })
             )
  end

  test "death-to-estate: the estate account can enter redemption", ctx do
    patronage!(ctx.steward, 100)

    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "MembershipDeceased", %{
          "member_id" => @member,
          "entity_id" => @entity,
          "estate_ref" => "estate-42"
        })
      )

    {:ok, account} = Capital.account(@chapter, @member, @entity)
    assert account.status == :estate
    assert account.estate_ref == "estate-42"

    # The estate is a redeemable state: a schedule opens over it.
    {:ok, _} = Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))

    {:ok, account} = Capital.account(@chapter, @member, @entity)
    assert account.status == :in_redemption
    assert account.estate_ref == "estate-42"
  end
end
