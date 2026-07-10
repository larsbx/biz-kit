defmodule CoopSubstrate.CapitalAccountsTest.DoubleRule do
  @moduledoc "Test-only accrual rule: credits twice the amount. Injected as v2."
  @behaviour CoopSubstrate.Capital.AccrualRule

  @impl true
  def credit(_params, _kind, amount_minor), do: amount_minor * 2

  @impl true
  def validate_params(_params), do: :ok
end

defmodule CoopSubstrate.CapitalAccountsTest do
  @moduledoc """
  Phase 1B acceptance item 11: the capital account is a pure fold of
  (events, rule version); a rule change applies forward only and never
  mutates historical results; every exit type reaches a redeemable account;
  any member's balance is reproducible from events alone by independent
  computation.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Capital
  alias CoopSubstrate.CapitalAccountsTest.DoubleRule
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.CapitalAccounts

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"

  setup do
    %{steward: new_member("steward"), member: new_member("member")}
  end

  defp activate_rule!(steward, rule_id \\ "capital-accrual-v1", params \\ %{}) do
    {:ok, [env]} =
      Log.append(
        signed_event(steward, "AccrualRuleActivated", %{"rule_id" => rule_id, "params" => params})
      )

    env.global_seq
  end

  defp patronage!(steward, kind, amount, opts \\ []) do
    payload = %{
      "member_id" => Keyword.get(opts, :member_id, @member),
      "entity_id" => Keyword.get(opts, :entity_id, @entity),
      "kind" => kind,
      "amount_minor" => amount
    }

    {:ok, [env]} = Log.append(signed_event(steward, "PatronageRecorded", payload))
    env.global_seq
  end

  defp balance!(opts \\ []) do
    {:ok, balance} = Capital.balance(@chapter, @member, @entity, opts)
    balance
  end

  test "patronage requires an active accrual rule for the chapter", ctx do
    seed_membership!(ctx.steward, ctx.member, @member, @entity)

    assert {:error, {:reject, 0, {:no_active_accrual_rule, @chapter}}} =
             Log.append(
               signed_event(ctx.steward, "PatronageRecorded", %{
                 "member_id" => @member,
                 "entity_id" => @entity,
                 "kind" => "delivery",
                 "amount_minor" => 100
               })
             )
  end

  test "patronage requires an active membership and a positive amount", ctx do
    seed_membership!(ctx.steward, ctx.member, @member, @entity, to: :invited)
    activate_rule!(ctx.steward)

    event = fn payload_overrides ->
      signed_event(
        ctx.steward,
        "PatronageRecorded",
        Map.merge(
          %{
            "member_id" => @member,
            "entity_id" => @entity,
            "kind" => "delivery",
            "amount_minor" => 100
          },
          payload_overrides
        )
      )
    end

    # :invited is not an accruing state (PLACEHOLDER: probationary+ counts).
    assert {:error, {:reject, 0, {:membership_not_active, :invited}}} =
             Log.append(event.(%{}))

    assert {:error, {:reject, 0, {:no_membership, "M-ghost", @entity}}} =
             Log.append(event.(%{"member_id" => "M-ghost"}))

    {:ok, _} =
      Log.append(
        signed_event(ctx.member, "MembershipProbationStarted", %{
          "member_id" => @member,
          "entity_id" => @entity
        })
      )

    assert {:error, {:reject, 0, :amount_must_be_positive}} =
             Log.append(event.(%{"amount_minor" => 0}))

    # Probationary patronage accrues.
    assert {:ok, _} = Log.append(event.(%{}))
    assert balance!() == 100
  end

  test "accrual math under the placeholder linear rule, entries record the rule", ctx do
    seed_membership!(ctx.steward, ctx.member, @member, @entity)

    activate_rule!(ctx.steward, "capital-accrual-v1", %{
      "weights_bp" => %{"delivery" => 5_000},
      "default_weight_bp" => 10_000
    })

    patronage!(ctx.steward, "delivery", 1_000)
    patronage!(ctx.steward, "labor_hour", 300)

    assert balance!() == 500 + 300

    {:ok, account} = Capital.account(@chapter, @member, @entity)
    assert account.status == :accruing
    assert account.credited_minor == 800

    assert [
             %{kind: "delivery", amount_minor: 1_000, credited_minor: 500, rule_id: "capital-accrual-v1"},
             %{kind: "labor_hour", amount_minor: 300, credited_minor: 300, rule_id: "capital-accrual-v1"}
           ] = account.entries
  end

  test "unknown rules and invalid params are rejected at the gate", ctx do
    assert {:error, {:reject, 0, :unknown_rule}} =
             Log.append(
               signed_event(ctx.steward, "AccrualRuleActivated", %{
                 "rule_id" => "capital-accrual-v99",
                 "params" => %{}
               })
             )

    assert {:error, {:reject, 0, {:unknown_params, ["surprise"]}}} =
             Log.append(
               signed_event(ctx.steward, "AccrualRuleActivated", %{
                 "rule_id" => "capital-accrual-v1",
                 "params" => %{"surprise" => 1}
               })
             )
  end

  test "a rule change applies forward only — historical results never mutate", ctx do
    Application.put_env(:coop_substrate, :extra_accrual_rules, %{
      "capital-accrual-v2-test" => DoubleRule
    })

    on_exit(fn -> Application.delete_env(:coop_substrate, :extra_accrual_rules) end)

    seed_membership!(ctx.steward, ctx.member, @member, @entity)
    activate_rule!(ctx.steward)

    v1_seq = patronage!(ctx.steward, "delivery", 1_000)
    assert balance!() == 1_000

    activate_rule!(ctx.steward, "capital-accrual-v2-test")
    patronage!(ctx.steward, "delivery", 1_000)

    # New rule forward: 1000 (v1) + 2000 (v2).
    assert balance!() == 3_000

    # History as of the v1 era is untouched — same events, same answer.
    assert balance!(as_of: v1_seq) == 1_000

    {:ok, account} = Capital.account(@chapter, @member, @entity)

    assert [
             %{rule_id: "capital-accrual-v1", credited_minor: 1_000},
             %{rule_id: "capital-accrual-v2-test", credited_minor: 2_000}
           ] = account.entries
  end

  test "dual membership: one member, two entities, two independent accounts", ctx do
    seed_membership!(ctx.steward, ctx.member, @member, @entity)

    seed_membership!(ctx.steward, ctx.member, @member, "E-mech-1",
      class: "mechanics_coop",
      register_member: false
    )

    activate_rule!(ctx.steward)
    patronage!(ctx.steward, "delivery", 500)
    patronage!(ctx.steward, "repair", 200, entity_id: "E-mech-1")

    assert {:ok, 500} = Capital.balance(@chapter, @member, @entity)
    assert {:ok, 200} = Capital.balance(@chapter, @member, "E-mech-1")
  end

  test "every exit type reaches a redeemable account (incl. death-to-estate)", ctx do
    activate_rule!(ctx.steward)

    exits = [
      {"M-dep", :invited, "MembershipDeparted", :member_signed, %{}, :redeemable},
      {"M-ret", :member, "MembershipRetired", :member_signed, %{}, :redeemable},
      {"M-floor", :member, "MembershipFloorExited", :steward_signed, %{}, :redeemable},
      {"M-dec", :member, "MembershipDeceased", :steward_signed, %{"estate_ref" => "estate-9"},
       :estate}
    ]

    for {member_id, from, exit_type, signer, extra, expected_status} <- exits do
      actor = new_member("member")

      seed_membership!(ctx.steward, actor, member_id, @entity,
        to: from,
        register_entity: member_id == "M-dep"
      )

      if from == :member do
        patronage!(ctx.steward, "delivery", 100, member_id: member_id)
      end

      payload = Map.merge(%{"member_id" => member_id, "entity_id" => @entity}, extra)

      exit_event =
        case signer do
          :member_signed -> signed_event(actor, exit_type, payload)
          :steward_signed -> signed_event(ctx.steward, exit_type, payload)
        end

      {:ok, _} = Log.append(exit_event)

      {:ok, account} = Capital.account(@chapter, member_id, @entity)
      assert account.status == expected_status, "#{exit_type} must reach a redeemable state"

      if expected_status == :estate do
        assert account.estate_ref == "estate-9"
      end

      if from == :member do
        assert CoopSubstrate.Projections.CapitalAccounts.balance(
                 elem(Log.replay(CapitalAccounts), 1),
                 @chapter,
                 member_id,
                 @entity
               ) == 100
      end
    end
  end

  test "balance is reproducible from events alone by independent computation", ctx do
    seed_membership!(ctx.steward, ctx.member, @member, @entity)

    activate_rule!(ctx.steward, "capital-accrual-v1", %{"weights_bp" => %{"delivery" => 2_500}})
    patronage!(ctx.steward, "delivery", 1_000)
    patronage!(ctx.steward, "labor_hour", 77)
    activate_rule!(ctx.steward, "capital-accrual-v1", %{"weights_bp" => %{"delivery" => 7_500}})
    patronage!(ctx.steward, "delivery", 1_000)

    # Independent computation: a naive fold over the raw event list, sharing
    # no code with the projection or the rule module — just the frozen
    # arithmetic of the placeholder rule.
    {:ok, events} = Log.read_all()

    {_params, independent_balance} =
      Enum.reduce(events, {nil, 0}, fn env, {params, sum} ->
        case {env.type, env.chapter_id, env.payload} do
          {"AccrualRuleActivated", @chapter, p} ->
            {p["params"], sum}

          {"PatronageRecorded", @chapter, %{"member_id" => @member, "entity_id" => @entity} = p} ->
            weights = Map.get(params, "weights_bp", %{})
            default = Map.get(params, "default_weight_bp", 10_000)
            bp = Map.get(weights, p["kind"], default)
            {params, sum + div(p["amount_minor"] * bp, 10_000)}

          _ ->
            {params, sum}
        end
      end)

    assert independent_balance == 250 + 77 + 750
    assert balance!() == independent_balance

    # And the same fold over an independently VERIFIED export reproduces it:
    # merge the relevant streams by global_seq (ordering authority is
    # sequence, never wall-clock).
    {:ok, rules_export} = Log.export_stream(@chapter <> "/accrual_rules")
    {:ok, patronage_export} = Log.export_stream(@chapter <> "/patronage/#{@member}/#{@entity}")

    {:ok, rule_events} = Log.verify_export(rules_export)
    {:ok, patronage_events} = Log.verify_export(patronage_export)

    merged = Enum.sort_by(rule_events ++ patronage_events, & &1.global_seq)

    {_params, export_balance} =
      Enum.reduce(merged, {nil, 0}, fn env, {params, sum} ->
        case env.type do
          "AccrualRuleActivated" ->
            {env.payload["params"], sum}

          "PatronageRecorded" ->
            weights = Map.get(params, "weights_bp", %{})
            default = Map.get(params, "default_weight_bp", 10_000)
            bp = Map.get(weights, env.payload["kind"], default)
            {params, sum + div(env.payload["amount_minor"] * bp, 10_000)}
        end
      end)

    assert export_balance == independent_balance
  end

  test "the fold replays deterministically", ctx do
    seed_membership!(ctx.steward, ctx.member, @member, @entity)
    activate_rule!(ctx.steward)
    patronage!(ctx.steward, "delivery", 123)

    {:ok, once} = Log.replay(CapitalAccounts)
    {:ok, twice} = Log.replay(CapitalAccounts)
    assert once == twice
  end
end
