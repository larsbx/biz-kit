defmodule CoopSubstrate.RedemptionTest do
  @moduledoc """
  Phase 1B redemption data structures (hand-off §2.3: multi-year payout,
  annual cap, FIFO, sinking fund, death-to-estate): schedules open only on
  redeemable accounts, payments consume accrual entries FIFO, and the
  entity's sinking fund tracks the accounting. Phase 7A adds enforcement
  (docs/phase7a_plan.md): the gate bounds every payment by the remaining
  balance and the schedule's per-year annual cap, from its own accrual
  fold — which must agree with the capital projection's.
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

  defp pay!(steward, amount, year_index \\ 0) do
    {:ok, _} = Log.append(payment(steward, amount, year_index))
  end

  defp payment(steward, amount, year_index) do
    signed_event(steward, "RedemptionPaid", %{
      "member_id" => @member,
      "entity_id" => @entity,
      "amount_minor" => amount,
      "year_index" => year_index
    })
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
             Log.append(payment(ctx.steward, 10, 0))

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

    # The estate is a redeemable state: a schedule opens over it and the
    # estate is paid out in full under the same enforcement.
    {:ok, _} = Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))

    {:ok, account} = Capital.account(@chapter, @member, @entity)
    assert account.status == :in_redemption
    assert account.estate_ref == "estate-42"

    pay!(ctx.steward, 100)
    assert {:ok, 0} = Capital.balance(@chapter, @member, @entity)
  end

  # -- Phase 7A: enforcement (docs/phase7a_plan.md) ---------------------------

  test "a payment never exceeds the remaining balance; exact payout is accepted", ctx do
    patronage!(ctx.steward, 100)
    retire!(ctx.member)
    {:ok, _} = Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))

    pay!(ctx.steward, 70)

    assert {:error, {:reject, 0, {:amount_exceeds_balance, 30}}} =
             Log.append(payment(ctx.steward, 40, 0))

    # Exit without forfeiture: the exact remaining balance always pays out.
    pay!(ctx.steward, 30)
    assert {:ok, 0} = Capital.balance(@chapter, @member, @entity)

    assert {:error, {:reject, 0, {:amount_exceeds_balance, 0}}} =
             Log.append(payment(ctx.steward, 1, 1))
  end

  test "the annual cap bounds each schedule year; year_index stays inside the schedule", ctx do
    patronage!(ctx.steward, 30_000)
    retire!(ctx.member)

    {:ok, _} =
      Log.append(
        signed_event(
          ctx.steward,
          "RedemptionScheduleOpened",
          schedule_payload(%{"years" => 2, "annual_cap_minor" => 10_000})
        )
      )

    pay!(ctx.steward, 6_000, 0)
    # Cumulative to exactly the cap is fine; one unit over is not.
    pay!(ctx.steward, 4_000, 0)

    assert {:error, {:reject, 0, {:annual_cap_exceeded, 0}}} =
             Log.append(payment(ctx.steward, 1, 0))

    # The next schedule year has its own cap.
    pay!(ctx.steward, 10_000, 1)

    assert {:error, {:reject, 0, {:year_outside_schedule, 2, 2}}} =
             Log.append(payment(ctx.steward, 1, 2))

    assert {:error, {:reject, 0, {:year_outside_schedule, -1, 2}}} =
             Log.append(payment(ctx.steward, 1, -1))
  end

  test "the gate's balance agrees with the capital fold across a rule change", ctx do
    patronage!(ctx.steward, 100)

    # Forward-only rule change: later patronage credits at half weight.
    {:ok, _} =
      Log.append(
        signed_event(ctx.steward, "AccrualRuleActivated", %{
          "rule_id" => "capital-accrual-v1",
          "params" => %{"default_weight_bp" => 5_000}
        })
      )

    patronage!(ctx.steward, 100)
    retire!(ctx.member)
    {:ok, _} = Log.append(signed_event(ctx.steward, "RedemptionScheduleOpened", schedule_payload()))

    # Capital says 100 + 50; the gate must draw the same line.
    assert {:ok, 150} = Capital.balance(@chapter, @member, @entity)

    assert {:error, {:reject, 0, {:amount_exceeds_balance, 150}}} =
             Log.append(payment(ctx.steward, 151, 0))

    pay!(ctx.steward, 150)
    assert {:ok, 0} = Capital.balance(@chapter, @member, @entity)
  end
end
