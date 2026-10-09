defmodule Keel.PropertiesTest do
  @moduledoc "Property tests for the lemmas in docs/PRIMITIVES.md (conservation, history, consent)."
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Keel.{
    Capability,
    Decision,
    Forms,
    Interval,
    Invariants,
    Line,
    Org,
    Ownership,
    Party,
    Stake
  }

  @dates [~D[2026-02-01], ~D[2026-05-01], ~D[2026-08-01], ~D[2026-11-01]]
  @terms [nil, ~D[2026-06-01], ~D[2027-01-01]]
  @probes Enum.sort(
            [~D[2025-01-01], ~D[2028-01-01] | @dates ++ Enum.reject(@terms, &is_nil/1)],
            Date
          )

  # A partnership of 2–5 partners, each holding 1–3 stakes with optional terms.
  defp partnership do
    gen all(
          n <- integer(2..5),
          stakes <-
            list_of(list_of({integer(1..60), member_of(@terms)}, min_length: 1, max_length: 3),
              length: n
            ),
          preemption <- boolean()
        ) do
      ids = for i <- 1..n, do: :"p#{i}"

      Org.new([
        for(id <- [:out | ids], do: %Party{id: id, kind: :person}),
        Forms.partnership(:llc, [], managers: [], preemption: preemption),
        for {id, ss} <- Enum.zip(ids, stakes), {u, term} <- ss do
          %Stake{holder: id, in: :llc, class: :equity, units: u, during: Interval.new(nil, term)}
        end
      ])
    end
  end

  defp parties(org),
    do: Enum.uniq([:out | for(%Stake{holder: h} <- Org.edges(org, Stake), do: h)])

  defp held(org, t), do: Map.new(parties(org), &{&1, Org.holding(org, &1, :llc, :equity, t)})
  defp total(org, t), do: held(org, t) |> Map.values() |> Enum.sum()
  defp before?(a, b), do: Date.compare(a, b) == :lt

  defp votes do
    gen all(vs <- list_of(member_of([:yes, :no, :abstain, nil]), length: 5)) do
      for {p, v} <- Enum.zip([:p1, :p2, :p3, :p4, :p5], vs), v != nil, into: %{}, do: {p, v}
    end
  end

  # Pick the `i`th element (mod length) — derives valid inputs instead of filtering.
  defp pick(xs, i), do: Enum.at(xs, rem(i, length(xs)))

  property "transfer conserves units at every instant and never rewrites history" do
    check all(
            org <- partnership(),
            t <- member_of(@dates),
            i <- non_negative_integer(),
            j <- non_negative_integer(),
            k <- non_negative_integer()
          ) do
      holders = Ownership.holders(org, :llc, :equity, t)

      if holders != [] do
        from = pick(holders, i)
        to = pick(parties(org) -- [from], j)
        n = 1 + rem(k, Org.holding(org, from, :llc, :equity, t))
        {:ok, moved, _} = Ownership.transfer(org, from, to, :llc, :equity, n, t, price: 1)

        for p <- @probes do
          assert total(moved, p) == total(org, p)
          if before?(p, t), do: assert(held(moved, p) == held(org, p))
        end

        assert Org.holding(moved, to, :llc, :equity, t) - Org.holding(org, to, :llc, :equity, t) ==
                 n

        assert Invariants.check(moved) == []
      end
    end
  end

  property "withdrawal removes exactly the withdrawer's units, from t on" do
    check all(org <- partnership(), t <- member_of(@dates), p <- member_of([:p1, :p2])) do
      case Ownership.withdraw(org, p, :llc, t) do
        {:ok, after_} ->
          for q <- @probes do
            if before?(q, t) do
              assert held(after_, q) == held(org, q)
            else
              assert held(after_, q) == Map.put(held(org, q), p, 0)
            end
          end

        {:error, :not_owner} ->
          assert Org.holding(org, p, :llc, :equity, t) == 0
      end
    end
  end

  property "pre-emption conserves units and leaves the outsider with nothing it bought" do
    check all(
            org <- partnership(),
            t <- member_of(@dates),
            i <- non_negative_integer(),
            k <- non_negative_integer()
          ) do
      holders = Ownership.holders(org, :llc, :equity, t)

      if holders != [] do
        seller = pick(holders, i)
        n = 1 + rem(k, Org.holding(org, seller, :llc, :equity, t))
        {:ok, sold, sale} = Ownership.transfer(org, seller, :out, :llc, :equity, n, t, price: 1)

        case Ownership.preempt(sold, sale, sale.claimants) do
          {:ok, back} ->
            for p <- @probes, do: assert(total(back, p) == total(org, p))
            assert Org.holding(back, :out, :llc, :equity, t) == 0

          {:error, reason} ->
            assert reason in [:indivisible, :not_entitled]
        end
      end
    end
  end

  property "without mandates, alienation carries iff every owner votes yes" do
    check all(
            org <- partnership(),
            t <- member_of(@dates),
            votes <- votes()
          ) do
      owners = Map.keys(Org.members(org, {:llc, :owners}, t))
      {outcome, _} = Decision.decide(org, {:llc, :owners}, :sell, votes, t)

      assert outcome ==
               if(owners != [] and Enum.all?(owners, &(votes[&1] == :yes)),
                 do: :carried,
                 else: :failed
               )
    end
  end

  property "when every owner has mandated the body, alienation follows its ordinary rule" do
    check all(
            org <- partnership(),
            t <- member_of(@dates),
            votes <- votes()
          ) do
      owners = Map.keys(Org.members(org, {:llc, :owners}, t))

      mandated =
        Org.put_all(
          org,
          for(
            p <- owners,
            do: %Line{kind: :mandates, from: p, to: {:llc, :owners}, grants: [:sell]}
          )
        )

      {sale, _} = Decision.decide(mandated, {:llc, :owners}, :sell, votes, t)
      {ordinary, _} = Decision.decide(mandated, {:llc, :owners}, :amend_charter, votes, t)
      assert sale == if(owners == [], do: :failed, else: ordinary)
    end
  end

  defp capability do
    one_of([
      constant(:*),
      member_of([:spend, :hire]),
      tuple({member_of([:spend, :hire]), integer(0..100)})
    ])
  end

  property "covering is a preorder" do
    check all(a <- capability(), b <- capability(), c <- capability()) do
      assert Capability.covers?(a, a)

      if Capability.covers?(a, b) and Capability.covers?(b, c),
        do: assert(Capability.covers?(a, c))
    end
  end

  property "capabilities that cover a common matter are comparable (voice order is a chain)" do
    check all(a <- capability(), b <- capability(), m <- capability()) do
      if Capability.covers?(a, m) and Capability.covers?(b, m),
        do: assert(Capability.covers?(a, b) or Capability.covers?(b, a))
    end
  end
end
