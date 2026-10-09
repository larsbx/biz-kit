defmodule CoopSubstrate.FloorEnforcementTest do
  @moduledoc """
  Phase 10A (docs/phase10a_plan.md): floor transitions are evidenced, not
  asserted — cure starts on a failing evaluation, clears on a passing one
  after the cure anchor, and the exit is representable only citing a
  failing evaluation at or beyond the declared cure window's end (failing
  closed while `floor/cure_window_ms` is undeclared). Hardship symmetry
  is regression-pinned: no evaluation can even be produced against a
  hardship member.
  """

  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @chapter "chapter-genesis"
  @entity "E-carrier-1"
  @member "M-ada"
  @t0 1_752_000_000_000
  @week 604_800_000

  setup do
    steward = new_member("steward")
    member = new_member("member")
    :ok = seed_membership!(steward, member, @member, @entity)

    {:ok, _} =
      Log.append(
        signed_event(steward, "FloorRuleActivated", %{
          "rule_id" => "floor-threshold-v1",
          "params" => %{"window_ms" => @week, "default_threshold_minor" => 100}
        })
      )

    %{steward: steward, member: member}
  end

  defp evaluate!(steward, id, cleared, at_ms, overrides \\ %{}) do
    Log.append(
      signed_event(
        steward,
        "FloorEvaluationRecorded",
        Map.merge(
          %{
            "evaluation_id" => id,
            "member_id" => @member,
            "entity_id" => @entity,
            "cleared" => cleared,
            "rule_id" => "floor-threshold-v1",
            "window_ms" => @week,
            "at_ms" => at_ms,
            "value" => if(cleared, do: 200, else: 0)
          },
          overrides
        )
      )
    )
  end

  defp transition(steward, type, ref) do
    Log.append(
      signed_event(steward, type, %{
        "member_id" => @member,
        "entity_id" => @entity,
        "evaluation_ref" => ref
      })
    )
  end

  defp declare_window!(value) do
    author = new_member("author")

    {:ok, _} =
      Log.append(
        signed_event(author, "CharterConstantDeclared", %{
          "name" => "floor/cure_window_ms",
          "value" => value
        })
      )
  end

  defp state do
    {:ok, s} = Log.replay(Membership)
    Membership.membership(s, @chapter, @member, @entity).state
  end

  test "cure starts only on the member's own failing evaluation", ctx do
    assert {:error, {:reject, _, {:unknown_evaluation, "EV-none"}}} =
             transition(ctx.steward, "FloorCureStarted", "EV-none")

    {:ok, _} = evaluate!(ctx.steward, "EV-pass", true, @t0)

    assert {:error, {:reject, _, :evaluation_not_failing}} =
             transition(ctx.steward, "FloorCureStarted", "EV-pass")

    # Another member's evaluation is not evidence about this one.
    other = new_member("member")

    {:ok, _} =
      Log.append(signed_event(other, "MemberRegistered", registration_payload("M-bob", other)))

    :ok = seed_membership!(ctx.steward, other, "M-bob", @entity, register_entity: false, register_member: false)

    {:ok, _} =
      evaluate!(ctx.steward, "EV-bob", false, @t0, %{"member_id" => "M-bob"})

    assert {:error, {:reject, _, :evaluation_subject_mismatch}} =
             transition(ctx.steward, "FloorCureStarted", "EV-bob")

    {:ok, _} = evaluate!(ctx.steward, "EV-fail", false, @t0)
    {:ok, _} = transition(ctx.steward, "FloorCureStarted", "EV-fail")
    assert state() == :in_cure

    # Evaluation ids are one-shot.
    assert {:error, {:reject, _, {:evaluation_already_recorded, "EV-fail"}}} =
             evaluate!(ctx.steward, "EV-fail", false, @t0 + 1)
  end

  test "the exit fails closed without the constant and opens only past the window", ctx do
    {:ok, _} = evaluate!(ctx.steward, "EV-1", false, @t0)
    {:ok, _} = transition(ctx.steward, "FloorCureStarted", "EV-1")

    {:ok, _} = evaluate!(ctx.steward, "EV-early", false, @t0 + @week - 1)
    {:ok, _} = evaluate!(ctx.steward, "EV-late", false, @t0 + @week)
    {:ok, _} = evaluate!(ctx.steward, "EV-pass", true, @t0 + @week)

    # Member-protective fail-closed: no declared window, no exit.
    assert {:error, {:reject, _, :cure_window_undeclared}} =
             transition(ctx.steward, "MembershipFloorExited", "EV-late")

    declare_window!(@week)

    assert {:error, {:reject, _, {:cure_window_not_elapsed, _}}} =
             transition(ctx.steward, "MembershipFloorExited", "EV-early")

    assert {:error, {:reject, _, :evaluation_not_failing}} =
             transition(ctx.steward, "MembershipFloorExited", "EV-pass")

    {:ok, _} = transition(ctx.steward, "MembershipFloorExited", "EV-late")
    assert state() == :floor_exited
    assert :ok = Log.verify_chains()
  end

  test "recovery needs a passing evaluation after the cure anchor; rounds start fresh", ctx do
    declare_window!(@week)

    {:ok, _} = evaluate!(ctx.steward, "EV-1", false, @t0)
    {:ok, _} = evaluate!(ctx.steward, "EV-stale-pass", true, @t0 - 1_000)
    {:ok, _} = transition(ctx.steward, "FloorCureStarted", "EV-1")

    # A passing evaluation from BEFORE the cure began proves nothing.
    assert {:error, {:reject, _, :evaluation_precedes_cure}} =
             transition(ctx.steward, "FloorCureCleared", "EV-stale-pass")

    assert {:error, {:reject, _, :evaluation_not_passing}} =
             transition(ctx.steward, "FloorCureCleared", "EV-1")

    {:ok, _} = evaluate!(ctx.steward, "EV-recovered", true, @t0 + 1_000)
    {:ok, _} = transition(ctx.steward, "FloorCureCleared", "EV-recovered")
    assert state() == :member

    # The next round anchors at ITS evaluation — the old window does not
    # carry over: an exit citing evidence from the first round's clock is
    # measured against the new anchor.
    {:ok, _} = evaluate!(ctx.steward, "EV-2", false, @t0 + 10_000)
    {:ok, _} = transition(ctx.steward, "FloorCureStarted", "EV-2")
    {:ok, _} = evaluate!(ctx.steward, "EV-2-early", false, @t0 + @week)

    assert {:error, {:reject, _, {:cure_window_not_elapsed, _}}} =
             transition(ctx.steward, "MembershipFloorExited", "EV-2-early")

    {:ok, _} = evaluate!(ctx.steward, "EV-2-late", false, @t0 + 10_000 + @week)
    {:ok, _} = transition(ctx.steward, "MembershipFloorExited", "EV-2-late")
    assert state() == :floor_exited
  end

  test "hardship symmetry: no evaluations, so no cure or exit evidence exists", ctx do
    {:ok, _} =
      Log.append(
        signed_event(ctx.member, "HardshipDeclared", %{
          "member_id" => @member,
          "entity_id" => @entity
        })
      )

    assert {:error, {:reject, _, :floor_suspended_by_hardship}} =
             evaluate!(ctx.steward, "EV-h", false, @t0)

    assert {:error, {:reject, _, {:illegal_transition, "FloorCureStarted", :hardship}}} =
             transition(ctx.steward, "FloorCureStarted", "EV-h")
  end
end
