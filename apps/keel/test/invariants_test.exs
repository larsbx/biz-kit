defmodule Keel.InvariantsTest do
  use ExUnit.Case, async: true
  alias Keel.{Body, Interval, Invariants, Line, Org, Party, Role, Seat, Stake, Unit}

  @base [
    %Party{id: :acme, kind: :entity},
    %Party{id: :ann, kind: :person},
    %Party{id: :bot, kind: :agent},
    %Unit{id: :hq, of: :acme},
    %Role{id: :ceo, unit: :hq, grants: [:*], seats: 1},
    %Role{id: :a, unit: :hq},
    %Role{id: :b, unit: :hq},
    %Seat{party: :ann, role: :ceo}
  ]

  defp violations(extra), do: Invariants.check(Org.new(@base ++ extra))
  defp names(extra), do: extra |> violations() |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  test "base is valid" do
    assert Invariants.valid?(Org.new(@base))
  end

  test "dangling references" do
    assert names([%Seat{party: :ghost, role: :a}]) == [:references]
    assert names([%Stake{holder: :ann, in: :ann}]) == [:references]
  end

  test "unknown kinds" do
    assert names([%Party{id: :x, kind: :robot}]) == [:kinds]
    assert names([%Line{kind: :likes, from: :a, to: :b}]) == [:kinds]
  end

  test "empty intervals and non-positive stakes" do
    i = Interval.new(~D[2026-01-01], ~D[2026-01-01])
    assert :intervals in names([%Seat{party: :ann, role: :a, during: i}])
    assert names([%Stake{holder: :ann, in: :acme, units: 0}]) == [:stakes]
  end

  test "units form a forest within one entity" do
    assert names([%Unit{id: :x, of: :acme, parent: :y}, %Unit{id: :y, of: :acme, parent: :x}]) ==
             [:unit_forest]

    assert :unit_forest in names([
             %Party{id: :other, kind: :entity},
             %Unit{id: :x, of: :other, parent: :hq}
           ])
  end

  test "reporting is acyclic at every instant" do
    later = Interval.new(~D[2026-03-01])
    v = violations([%Line{from: :a, to: :b}, %Line{from: :b, to: :a, during: later}])
    assert [{:reports_acyclic, ~D[2026-03-01], {:cycle, _}}] = v
  end

  test "seat limits" do
    assert names([%Seat{party: :bot, role: :ceo}]) == [:seat_limits]
  end

  test "delegation must attenuate" do
    assert Invariants.valid?(
             Org.new(
               @base ++ [%Line{kind: :delegates, from: :ceo, to: :a, grants: [{:spend, 9}]}]
             )
           )

    assert names([%Line{kind: :delegates, from: :a, to: :b, grants: [:hire]}]) == [:attenuation]
  end

  test "circular delegation is caught even when it launders authority past attenuation" do
    launder = [
      %Line{kind: :delegates, from: :a, to: :b, grants: [:hire]},
      %Line{kind: :delegates, from: :b, to: :a, grants: [:hire]}
    ]

    assert names(launder) == [:delegation_acyclic]
  end

  test "agents must answer, transitively, to a non-agent" do
    seat = %Seat{party: :bot, role: :a}
    assert names([seat]) == [:agent_accountability]
    assert Invariants.valid?(Org.new(@base ++ [seat, %Line{from: :a, to: :ceo}]))

    agents_only = %Body{id: :bots, of: :acme, members: {:seats, [:b]}}
    chain = [seat, %Seat{party: :bot, role: :b}, agents_only, %Line{from: :a, to: :bots}]
    assert names(chain) == [:agent_accountability]
  end
end
