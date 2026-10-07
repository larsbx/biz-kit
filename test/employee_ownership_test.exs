defmodule Keel.EmployeeOwnershipTest do
  @moduledoc "Employee ownership: eligibility tied to employment, body scope, look-through voting."
  use ExUnit.Case, async: true

  alias Keel.{
    Body,
    Class,
    Decision,
    Forms,
    Interval,
    Invariants,
    Line,
    Org,
    Party,
    Role,
    Seat,
    Stake
  }

  @t ~D[2026-06-01]

  defp people(ids, kind \\ :person), do: for(id <- ids, do: %Party{id: id, kind: kind})
  defp names(org), do: org |> Invariants.check() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  defp staff(e, ids, during \\ Interval.always()) do
    [%Role{id: {e, :staff}, unit: {e, :hq}}] ++
      for(p <- ids, do: %Seat{party: p, role: {e, :staff}, during: during})
  end

  # Company 100% held by an employee trust; ann and bob are staff and beneficiaries.
  defp esop(extra \\ []) do
    Org.new([
      people([:ann, :bob, :dir, :tee]),
      Forms.corporation(:co, [{:trust, 1}], [:dir], :dir),
      staff(:co, [:ann, :bob]),
      Forms.employee_trust(:trust, :co, :tee, [{:ann, 60}, {:bob, 40}], [:sell, :merge]),
      extra
    ])
  end

  describe "eligibility: ownership conditional on employment" do
    test "the ESOP is well-formed" do
      assert Invariants.check(esop()) == []
    end

    test "a leaver who keeps an allocation is flagged from the leaving date" do
      org =
        Org.new([
          people([:ann, :bob, :dir, :tee]),
          Forms.corporation(:co, [{:trust, 1}], [:dir], :dir),
          staff(:co, [:ann]),
          %Seat{party: :bob, role: {:co, :staff}, during: Interval.new(nil, ~D[2026-03-01])},
          Forms.employee_trust(:trust, :co, :tee, [{:ann, 60}, {:bob, 40}], [:sell])
        ])

      assert [{:eligibility, ~D[2026-03-01], {:ineligible, :bob, :trust, :beneficial}}] =
               Invariants.check(org)
    end

    test "worker co-op membership requires a seat; consumer co-op membership does not" do
      workers = [people([:ann, :bob]), Forms.worker_cooperative(:wc, [:ann, :bob], :ann)]
      assert Invariants.check(Org.new(workers)) == []

      outsider = %Stake{holder: :cat, in: :wc, class: :membership}
      assert names(Org.new([workers, people([:cat]), outsider])) == [:eligibility]

      consumer = [people([:ann, :cat]), Forms.cooperative(:cc, [:ann, :cat], :ann)]
      assert Invariants.check(Org.new(consumer)) == []
    end

    test "class names are unique per entity" do
      dup = %Class{id: :dup, of: :wc, name: :membership}

      assert :classes in names(
               Org.new([people([:ann]), Forms.worker_cooperative(:wc, [:ann], :ann), dup])
             )
    end
  end

  describe "look-through voting" do
    test "ordinary matters: the trustee casts the trust's vote" do
      votes = %{tee: :yes, ann: :no, bob: :no}
      assert {:carried, %{yes: 1}} = Decision.decide(esop(), {:co, :owners}, :elect, votes, @t)
    end

    test "reserved matters pass through to beneficiaries, weighted by allocation" do
      votes = %{tee: :yes, ann: :no, bob: :yes}
      assert {:failed, %{no: 1}} = Decision.decide(esop(), {:co, :owners}, :sell, votes, @t)

      assert {:carried, _} =
               Decision.decide(esop(), {:co, :owners}, :sell, %{votes | ann: :yes}, @t)
    end

    test "an entity with no voice on the matter is absent" do
      org = esop()
      silent = %{org | nodes: Map.delete(org.nodes, {:trust, :trustees})}

      assert {:inquorate, %{present: 0}} =
               Decision.decide(silent, {:co, :owners}, :elect, %{tee: :yes}, @t)
    end

    test "an explicit vote by an entity overrides look-through" do
      assert {:carried, _} =
               Decision.decide(esop(), {:co, :owners}, :sell, %{trust: :yes, ann: :no}, @t)
    end

    test "two bodies of one entity may not voice the same matter" do
      clash = %Body{
        id: :clash,
        of: :trust,
        members: {:seats, [{:trust, :trustee}]},
        voices: [:sell]
      }

      assert names(esop([clash])) == [:voices]
    end

    test "ownership cycles are rejected (look-through must be well-founded)" do
      cross = [
        people([:ann]),
        Forms.corporation(:x, [{:y, 1}], [:ann], :ann),
        Forms.corporation(:y, [{:x, 1}], [:ann], :ann)
      ]

      assert names(Org.new(cross)) == [:ownership_acyclic]
    end
  end

  describe "body scope" do
    defp shop(extra) do
      Org.new([
        people([:ann, :bob]),
        Forms.sole_proprietorship(:s, :ann),
        %Role{id: :adviser, unit: {:s, :hq}},
        %Seat{party: :bob, role: :adviser},
        extra
      ])
    end

    test "an advisory body (no grants) has zero input" do
      org = shop(%Body{id: :council, of: :s, members: {:seats, [:adviser]}, grants: []})
      assert Invariants.check(org) == []
      assert {:ultra_vires, nil} = Decision.decide(org, :council, :hire, %{bob: :yes}, @t)
    end

    test "a scoped body decides only within scope" do
      org =
        shop(%Body{id: :pay, of: :s, members: {:seats, [:adviser]}, grants: [{:spend, 1_000}]})

      assert {:carried, _} = Decision.decide(org, :pay, {:spend, 500}, %{bob: :yes}, @t)
      assert {:ultra_vires, _} = Decision.decide(org, :pay, {:spend, 5_000}, %{bob: :yes}, @t)
    end

    test "bodies delegate to roles, and must attenuate" do
      board = %Body{id: :b, of: :s, members: {:seats, [:adviser]}, grants: [:hire]}
      ok = shop([board, %Line{kind: :delegates, from: :b, to: :adviser, grants: [:hire]}])
      assert Invariants.check(ok) == [] and Org.can?(ok, :bob, :hire, @t)

      over = shop([board, %Line{kind: :delegates, from: :b, to: :adviser, grants: [:fire]}])
      assert names(over) == [:attenuation]
    end
  end
end
