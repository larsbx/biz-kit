defmodule CoopSubstrate.FinanceNettingTest do
  @moduledoc """
  Phase 1C step 7 (docs/phase1c_plan.md P7; corpus 05 P5/P10): netting is a
  pure set-off over open mutual obligations — never across denominations,
  set-off ≤ min of the mutual gross sums, discharged and third-party
  obligations excluded — and over the real log it is reproducible with
  `as_of:`.
  """

  use CoopSubstrate.LogCase, async: false
  use ExUnitProperties

  alias CoopSubstrate.Finance
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"

  # -- the pure core, property-checked ----------------------------------------

  property "per-denomination set-off: setoff == min of gross sums; net is the residual" do
    check all(obligations <- obligations_map()) do
      for %{denomination: d, a_to_b: a_to_b, b_to_a: b_to_a, setoff: setoff, net: net} <-
            Finance.compute(obligations, @chapter, {"A", "B"}) do
        # Recompute the gross sums independently, per denomination — an open
        # obligation of another denomination, a closed one, or one touching a
        # third party must never leak in (05 P5).
        expected = fn debtor, creditor ->
          obligations
          |> Map.values()
          |> Enum.filter(
            &(&1.open and &1.denomination == d and &1.debtor_id == debtor and
                &1.creditor_id == creditor)
          )
          |> Enum.map(& &1.amount_minor)
          |> Enum.sum()
        end

        assert a_to_b == expected.("A", "B")
        assert b_to_a == expected.("B", "A")
        assert setoff == min(a_to_b, b_to_a)

        case net do
          nil -> assert a_to_b == b_to_a
          {"A", "B", n} -> assert n == a_to_b - b_to_a and n > 0
          {"B", "A", n} -> assert n == b_to_a - a_to_b and n > 0
        end
      end
    end
  end

  defp obligations_map do
    gen all(
          entries <-
            list_of(
              fixed_map(%{
                debtor_id: member_of(["A", "B", "C"]),
                creditor_id: member_of(["A", "B", "C"]),
                amount_minor: integer(1..10_000),
                denomination: member_of(["USD", "EUR", "SAR"]),
                open: boolean()
              }),
              max_length: 20
            )
        ) do
      entries
      |> Enum.reject(&(&1.debtor_id == &1.creditor_id))
      |> Enum.with_index()
      |> Map.new(fn {ob, i} -> {{@chapter, "OB-#{i}"}, ob} end)
    end
  end

  # -- over the real log --------------------------------------------------------

  test "netting over recorded obligations: open only, per denomination, as_of stable" do
    alice = new_member("member")
    bob = new_member("member")

    for {id, actor} <- [{"M-alice", alice}, {"M-bob", bob}] do
      {:ok, _} =
        Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))
    end

    as_role = fn actor, role -> %{actor | signer: %{actor.signer | role: role}} end

    record! = fn id, debtor, creditor, debtor_id, creditor_id, amount, denom ->
      {:ok, [env]} =
        Log.append(
          multi_signed_event([as_role.(debtor, "debtor"), as_role.(creditor, "creditor")],
            "ObligationRecorded",
            %{
              "obligation_id" => id,
              "debtor_id" => debtor_id,
              "creditor_id" => creditor_id,
              "amount_minor" => amount,
              "denomination" => denom
            }
          )
        )

      env.global_seq
    end

    record!.("OB-1", alice, bob, "M-alice", "M-bob", 500, "USD")
    record!.("OB-2", bob, alice, "M-bob", "M-alice", 300, "USD")
    seq_all_open = record!.("OB-3", alice, bob, "M-alice", "M-bob", 900, "EUR")

    {:ok, _} =
      Log.append(
        multi_signed_event([as_role.(alice, "debtor"), as_role.(bob, "creditor")],
          "ObligationDischarged",
          %{"obligation_id" => "OB-1"}
        )
      )

    # After the discharge: USD 500 is gone; EUR never offsets USD.
    assert {:ok,
            [
              %{denomination: "EUR", a_to_b: 900, b_to_a: 0, setoff: 0, net: {"M-alice", "M-bob", 900}},
              %{denomination: "USD", a_to_b: 0, b_to_a: 300, setoff: 0, net: {"M-bob", "M-alice", 300}}
            ]} = Finance.netting(@chapter, {"M-alice", "M-bob"})

    # Before the discharge (as_of): the USD pair nets 300, residual 200.
    assert {:ok,
            [
              %{denomination: "EUR", setoff: 0},
              %{denomination: "USD", a_to_b: 500, b_to_a: 300, setoff: 300, net: {"M-alice", "M-bob", 200}}
            ]} = Finance.netting(@chapter, {"M-alice", "M-bob"}, as_of: seq_all_open)
  end
end
