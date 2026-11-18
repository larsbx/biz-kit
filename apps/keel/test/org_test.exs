defmodule Keel.OrgTest do
  use ExUnit.Case, async: true
  alias Keel.{Body, Interval, Line, Org, Party, Role, Seat, Stake, Unit}

  @t ~D[2026-06-01]

  defp org do
    Org.new([
      %Party{id: :acme, kind: :entity},
      %Party{id: :ann, kind: :person},
      %Party{id: :bob, kind: :person},
      %Unit{id: :hq, of: :acme},
      %Unit{id: :ops, of: :acme, parent: :hq},
      %Role{id: :ceo, unit: :hq, grants: [:*], seats: 1},
      %Role{id: :coo, unit: :ops},
      %Seat{party: :ann, role: :ceo},
      %Seat{party: :bob, role: :coo, during: Interval.new(~D[2026-01-01], ~D[2027-01-01])},
      %Seat{party: :bob, role: :ceo, during: Interval.new(~D[2027-01-01])},
      %Line{kind: :reports, from: :coo, to: :ceo},
      %Line{kind: :delegates, from: :ceo, to: :coo, grants: [:hire, {:spend, 1_000}]},
      %Stake{holder: :ann, in: :acme, class: :common, units: 60},
      %Stake{holder: :bob, in: :acme, class: :common, units: 40},
      %Body{id: :holders, of: :acme, members: {:stake, :common}, weight: {:units, :common}}
    ])
  end

  test "duplicate node ids are rejected at construction" do
    assert_raise ArgumentError, fn ->
      Org.new([%Party{id: :x, kind: :person}, %Unit{id: :x, of: :y}])
    end
  end

  test "seats are temporal" do
    assert Org.holders(org(), :coo, @t) == [:bob]
    assert Org.holders(org(), :coo, ~D[2027-01-01]) == []
    assert Enum.sort(Org.holders(org(), :ceo, ~D[2027-06-01])) == [:ann, :bob]
  end

  test "capabilities derive from seats plus delegation" do
    assert Org.can?(org(), :bob, {:spend, 500}, @t)
    refute Org.can?(org(), :bob, {:spend, 5_000}, @t)
    refute Org.can?(org(), :bob, :fire, @t)
    assert Org.can?(org(), :ann, :fire, @t)
  end

  test "body membership and weights" do
    assert Org.members(org(), :holders, @t) == %{ann: 60, bob: 40}
  end

  test "epochs are the sorted distinct interval bounds after the origin" do
    assert tl(Org.epochs(org())) == [~D[2026-01-01], ~D[2027-01-01]]
  end

  describe "an invalid org grants nothing (formal/quint/obligations/keel.qnt)" do
    @base [
      %Party{id: :acme, kind: :entity},
      %Party{id: :ann, kind: :person},
      %Unit{id: :hq, of: :acme},
      %Role{id: :ceo, unit: :hq, grants: [:*], seats: 1},
      %Role{id: :a, unit: :hq},
      %Role{id: :b, unit: :hq}
    ]

    test "permissions stand while the org is valid, and stop when it is not" do
      assert Keel.Invariants.valid_at?(org(), @t)
      assert Org.can?(org(), :ann, :fire, @t)

      # From 2027 the one-seat :ceo role is held by ann and bob (seat_limits).
      refute Keel.Invariants.valid_at?(org(), ~D[2027-06-01])
      refute Org.can?(org(), :ann, :fire, ~D[2027-06-01])
    end

    test "circular delegation cannot launder authority into a role" do
      org =
        Org.new(
          @base ++
            [
              %Seat{party: :ann, role: :a},
              %Line{kind: :delegates, from: :a, to: :b, grants: [:hire]},
              %Line{kind: :delegates, from: :b, to: :a, grants: [:hire]}
            ]
        )

      refute Keel.Invariants.valid?(org)
      refute Org.can?(org, :ann, :hire, @t)
    end

    test "cyclic ownership between entities grants nothing" do
      org =
        Org.new(
          @base ++
            [
              %Party{id: :beta, kind: :entity},
              %Seat{party: :ann, role: :ceo},
              %Stake{holder: :acme, in: :beta, class: :common, units: 1},
              %Stake{holder: :beta, in: :acme, class: :common, units: 1}
            ]
        )

      refute Keel.Invariants.valid?(org)
      refute Org.can?(org, :ann, :fire, @t)
    end

    test "an invalidity that begins later leaves earlier instants usable" do
      later = Interval.new(~D[2026-09-01])

      org =
        Org.new(
          @base ++
            [
              %Seat{party: :ann, role: :ceo},
              %Line{from: :a, to: :b},
              %Line{from: :b, to: :a, during: later}
            ]
        )

      assert Org.can?(org, :ann, :fire, @t)
      refute Org.can?(org, :ann, :fire, ~D[2026-10-01])
    end
  end
end
