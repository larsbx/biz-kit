defmodule Keel.FormsTest do
  @moduledoc "Generalization evidence: distinct real-world forms are configurations of one kernel."
  use ExUnit.Case, async: true
  alias Keel.{Decision, Forms, Interval, Invariants, Line, Org, Party, Role, Seat, Stake}

  @t ~D[2026-06-01]

  defp people(ids, kind \\ :person), do: for(id <- ids, do: %Party{id: id, kind: kind})
  defp valid!(items), do: Org.new(items) |> tap(&assert(Invariants.check(&1) == []))

  test "sole proprietorship" do
    org = valid!([people([:ann]), Forms.sole_proprietorship(:shop, :ann)])
    assert Org.can?(org, :ann, :anything, @t)
    assert {:carried, _} = Decision.decide(org, {:shop, :owners}, %{ann: :yes}, @t)
  end

  test "partnership / LLC: control follows units" do
    org = valid!([people([:ann, :bob]), Forms.partnership(:llc, [{:ann, 51}, {:bob, 49}])])
    assert Enum.sort(Org.holders(org, {:llc, :manager}, @t)) == [:ann, :bob]
    assert {:carried, _} = Decision.decide(org, {:llc, :owners}, %{ann: :yes, bob: :no}, @t)
  end

  test "corporation: shareholders → board → CEO" do
    org =
      valid!([
        people([:ann, :bob, :cat, :dan]),
        Forms.corporation(:corp, [{:ann, 900}, {:bob, 100}], [:bob, :cat], :dan)
      ])

    assert {:failed, _} = Decision.decide(org, {:corp, :board}, %{bob: :yes, cat: :no}, @t)
    assert Org.can?(org, :dan, :hire, @t)
    refute Org.can?(org, :cat, :hire, @t)
  end

  test "worker co-op: per-capita control, capital tracked separately" do
    org =
      valid!([
        people([:ann, :bob, :cat]),
        Forms.cooperative(:coop, [:ann, :bob, :cat], :ann,
          capital: %{ann: 5_000, bob: 100, cat: 100}
        )
      ])

    assert Org.members(org, {:coop, :assembly}, @t) == %{ann: 1, bob: 1, cat: 1}

    assert {:failed, _} =
             Decision.decide(org, {:coop, :assembly}, %{ann: :yes, bob: :no, cat: :no}, @t)
  end

  test "membership ends in time without mutating history" do
    exit = %Stake{
      holder: :dan,
      in: :coop,
      class: :membership,
      during: Interval.new(nil, ~D[2026-03-01])
    }

    org = valid!([people([:ann, :dan]), Forms.cooperative(:coop, [:ann], :ann), exit])
    assert Map.keys(Org.members(org, {:coop, :assembly}, ~D[2026-01-01])) == [:ann, :dan]
    assert Map.keys(Org.members(org, {:coop, :assembly}, @t)) == [:ann]
  end

  test "holding: an entity is a shareholder of another — composition, not a new form" do
    valid!([
      people([:ann, :bob]),
      Forms.corporation(:parent, [{:ann, 1}], [:ann], :ann),
      Forms.corporation(:sub, [{:parent, 1}], [:bob], :bob)
    ])
  end

  test "owner-operator trucking: one person, many hats; an agent dispatches under a human" do
    org =
      valid!([
        people([:ann]),
        people([:hermes], :agent),
        Forms.sole_proprietorship(:haul, :ann),
        Forms.department(:haul, :dispatch, {:haul, :principal}, [:dispatch, {:spend, 500}]),
        %Seat{party: :ann, role: {:haul, :dispatch, :head}},
        %Role{id: {:haul, :dispatch, :desk}, unit: {:haul, :dispatch}},
        %Seat{party: :hermes, role: {:haul, :dispatch, :desk}},
        %Line{from: {:haul, :dispatch, :desk}, to: {:haul, :dispatch, :head}},
        %Line{
          kind: :delegates,
          from: {:haul, :dispatch, :head},
          to: {:haul, :dispatch, :desk},
          grants: [:dispatch, {:spend, 100}]
        }
      ])

    assert Org.can?(org, :hermes, {:spend, 100}, @t)
    refute Org.can?(org, :hermes, {:spend, 101}, @t)
  end

  test "a department cannot be granted more than its superior holds" do
    org =
      Org.new([
        people([:ann, :bob]),
        Forms.sole_proprietorship(:shop, :ann),
        Forms.department(:shop, :ops, {:shop, :principal}, [{:spend, 1_000}]),
        Forms.department(:shop, :yard, {:shop, :ops, :head}, [{:spend, 5_000}])
      ])

    assert [
             {:attenuation, _,
              {:exceeds, {:shop, :ops, :head}, {:shop, :yard, :head}, {:spend, 5_000}}}
           ] = Invariants.check(org)
  end
end
