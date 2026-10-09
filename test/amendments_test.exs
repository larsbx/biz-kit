defmodule Keel.AmendmentsTest do
  @moduledoc "Each test pins a harmful outcome the previous policy allowed (docs/PRIMITIVES.md § Amendments)."
  use ExUnit.Case, async: true
  alias Keel.{Body, Decision, Forms, Invariants, Org, Party, Role, Seat}

  @t ~D[2026-06-01]

  defp people(ids), do: for(id <- ids, do: %Party{id: id, kind: :person})
  defp names(org), do: org |> Invariants.check() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  defp esop do
    Org.new([
      people([:ann, :bob, :dir, :tee]),
      Forms.corporation(:co, [{:trust, 1}], [:dir], :dir),
      %Role{id: {:co, :staff}, unit: {:co, :hq}},
      for(p <- [:ann, :bob], do: %Seat{party: p, role: {:co, :staff}}),
      Forms.employee_trust(:trust, :co, :tee, [{:ann, 60}, {:bob, 40}], [:sell, :merge])
    ])
  end

  describe "A1 — fundamental matters are reserved to the owners" do
    test "an executive with plenary grants cannot sell the company" do
      assert Invariants.check(esop()) == []
      refute Org.can?(esop(), :dir, :sell, @t)
      assert Org.can?(esop(), :dir, :hire, @t)
    end

    test "nor can the board decide it; only the owners body can" do
      assert {:ultra_vires, nil} = Decision.decide(esop(), {:co, :board}, :sell, %{dir: :yes}, @t)

      assert {:failed, _} =
               Decision.decide(esop(), {:co, :owners}, :sell, %{ann: :no, bob: :yes}, @t)
    end

    test "a sole proprietor is not encumbered: owner and executive coincide" do
      org = Org.new([people([:ann]), Forms.sole_proprietorship(:s, :ann)])
      assert Org.can?(org, :ann, :sell, @t)
    end
  end

  describe "A2 — an entity's vote cannot be asserted around its own bodies" do
    test "a direct `trust: :yes` does not bypass the beneficiaries on a reserved matter" do
      votes = %{trust: :yes, tee: :yes, ann: :no, bob: :no}
      assert {:failed, _} = Decision.decide(esop(), {:co, :owners}, :sell, votes, @t)
    end

    test "an entity with no bodies (outside the model) still votes directly" do
      org =
        Org.new([
          people([:dir]),
          %Party{id: :fund, kind: :entity},
          Forms.corporation(:co, [{:fund, 1}], [:dir], :dir)
        ])

      assert {:carried, _} = Decision.decide(org, {:co, :owners}, :sell, %{fund: :yes}, @t)
    end
  end

  describe "A3 — no one sells what they do not fully own" do
    test "the trustee holds title, not ownership: it can never sell" do
      assert {:failed, _} = Decision.decide(esop(), {:co, :owners}, :sell, %{tee: :yes}, @t)
    end

    test "owner-employees must engage: an absent owner is a refusal" do
      assert {:failed, _} = Decision.decide(esop(), {:co, :owners}, :sell, %{ann: :yes}, @t)

      assert {:failed, _} =
               Decision.decide(esop(), {:co, :owners}, :merge, %{ann: :yes, bob: :abstain}, @t)

      assert {:carried, _} =
               Decision.decide(esop(), {:co, :owners}, :sell, %{ann: :yes, bob: :yes}, @t)
    end

    test "a majority is not the whole: a 51% partner cannot sell" do
      org = Org.new([people([:ann, :bob]), Forms.partnership(:llc, [{:ann, 51}, {:bob, 49}])])
      assert {:failed, _} = Decision.decide(org, {:llc, :owners}, :sell, %{ann: :yes}, @t)

      assert {:failed, _} =
               Decision.decide(org, {:llc, :owners}, :merge, %{ann: :yes, bob: :no}, @t)
    end

    test "every co-op member must consent" do
      org =
        Org.new([
          people([:ann, :bob, :cat]),
          Forms.worker_cooperative(:wc, [:ann, :bob, :cat], :ann)
        ])

      assert {:failed, _} =
               Decision.decide(org, {:wc, :assembly}, :sell, %{ann: :yes, bob: :yes}, @t)
    end

    test "acting alone requires holding everything" do
      sole = Org.new([people([:ann]), Forms.sole_proprietorship(:s, :ann)])
      assert Org.can?(sole, :ann, :sell, @t)

      hired =
        Org.new([
          people([:ann, :mgr]),
          Forms.sole_proprietorship(:s, :ann),
          %Seat{party: :mgr, role: {:s, :principal}, during: Keel.Interval.new(~D[2027-01-01])}
        ])

      refute Org.can?(hired, :mgr, :sell, ~D[2027-06-01])
      refute Org.can?(hired, :mgr, :*, ~D[2027-06-01])
      assert Org.can?(hired, :mgr, :hire, ~D[2027-06-01])
    end

    test "a body of seats can never decide a sale, whatever its grants" do
      org = Org.new([people([:ann]), Forms.sole_proprietorship(:s, :ann)])
      seats = %Body{id: :b, of: :s, members: {:seats, [{:s, :principal}]}, grants: [:*]}

      assert {:ultra_vires, nil} =
               Decision.decide(Org.put(org, seats), :b, :sell, %{ann: :yes}, @t)
    end

    test "structures where only non-owners could speak to a sale are flagged" do
      seats = [
        %Body{
          id: :b,
          of: :s,
          members: {:seats, [{:s, :principal}]},
          grants: [:*],
          reserves: [:sell]
        }
      ]

      assert names(Org.new([people([:ann]), Forms.sole_proprietorship(:s, :ann), seats])) == [
               :alienation
             ]

      trustee_only = %Body{
        id: :t2,
        of: :trust,
        members: {:seats, [{:trust, :trustee}]},
        grants: [:*],
        voices: [:*]
      }

      org =
        Org.new([
          people([:tee]),
          Forms.entity(:trust),
          %Keel.Role{id: {:trust, :trustee}, unit: {:trust, :hq}},
          trustee_only
        ])

      assert :alienation in names(org)
    end
  end

  describe "A4 — bodies are fail-closed" do
    test "a body declared without grants decides nothing" do
      org =
        Org.new([
          people([:ann]),
          Forms.sole_proprietorship(:s, :ann),
          %Body{id: :committee, of: :s, members: {:seats, [{:s, :principal}]}}
        ])

      assert {:ultra_vires, nil} = Decision.decide(org, :committee, :hire, %{ann: :yes}, @t)
    end
  end

  describe "A5 — reservations must be decidable and uncontested" do
    defp shop(extra), do: Org.new([people([:ann]), Forms.sole_proprietorship(:s, :ann), extra])

    defp body(id, opts),
      do: struct!(Body, [id: id, of: :s, members: {:seats, [{:s, :principal}]}] ++ opts)

    test "a body cannot reserve what it may not decide (permanent deadlock)" do
      assert names(shop(body(:b, reserves: [:amend_charter]))) == [:reserves]
    end

    test "two bodies cannot reserve overlapping matters (contested authority)" do
      both = [
        body(:x, grants: [:*], reserves: [:amend_charter]),
        body(:y, grants: [:*], reserves: [:amend_charter])
      ]

      assert names(shop(both)) == [:reserves]
    end
  end
end
