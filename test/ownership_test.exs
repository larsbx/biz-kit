defmodule Keel.OwnershipTest do
  @moduledoc """
  Rights that flow from ownership rather than office (Hanbali *sharika*):
  dissolution of revocable contracts, withdrawal, disposal of one's own share,
  pre-emption (*shufʿa*), and majority authority only by revocable mandate.
  """
  use ExUnit.Case, async: true

  alias Keel.{
    Capability,
    Class,
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

  @t ~D[2026-06-01]
  @later ~D[2026-09-01]

  defp people(ids), do: for(id <- ids, do: %Party{id: id, kind: :person})

  defp llc(extra \\ [], opts \\ []),
    do:
      Org.new([
        people([:ann, :bob, :cat, :out]),
        Forms.partnership(:llc, [{:ann, 50}, {:bob, 30}, {:cat, 20}], opts),
        extra
      ])

  defp units(org, p, t), do: Map.get(Org.members(org, {:llc, :owners}, t), p, 0)

  test "dissolution is not alienation" do
    assert Capability.alienation() == [:sell, :merge]
  end

  describe "dissolution (faskh)" do
    test "a revocable partnership is dissolved by any one partner" do
      assert Invariants.check(llc()) == []

      assert {:carried, _} =
               Decision.decide(
                 llc(),
                 {:llc, :owners},
                 :dissolve,
                 %{cat: :yes, ann: :no, bob: :no},
                 @t
               )

      assert {:failed, _} = Decision.decide(llc(), {:llc, :owners}, :dissolve, %{ann: :no}, @t)
    end

    test "a binding entity dissolves by its ordinary rule" do
      corp =
        Org.new([
          people([:ann, :bob]),
          Forms.corporation(:co, [{:ann, 900}, {:bob, 100}], [:ann], :ann)
        ])

      assert {:failed, _} =
               Decision.decide(corp, {:co, :owners}, :dissolve, %{bob: :yes, ann: :no}, @t)

      assert {:carried, _} =
               Decision.decide(corp, {:co, :owners}, :dissolve, %{ann: :yes, bob: :no}, @t)
    end
  end

  describe "withdrawal" do
    test "a partner may leave a revocable partnership unilaterally; history is kept" do
      {:ok, org} = Ownership.withdraw(llc(), :cat, :llc, @later)
      assert units(org, :cat, @t) == 20
      assert units(org, :cat, @later) == 0
      assert Invariants.check(org) == []
    end

    test "no unilateral exit from a binding class" do
      corp =
        Org.new([
          people([:ann, :bob]),
          Forms.corporation(:co, [{:ann, 1}, {:bob, 1}], [:ann], :ann)
        ])

      assert {:error, :binding} = Ownership.withdraw(corp, :bob, :co, @later)
    end
  end

  describe "disposal of one's own share" do
    test "an owner may transfer part of their own share without the others' consent" do
      {:ok, org, %{claimants: []}} =
        Ownership.transfer(llc(), :ann, :out, :llc, :equity, 10, @later)

      assert units(org, :ann, @t) == 50 and units(org, :out, @t) == 0
      assert units(org, :ann, @later) == 40 and units(org, :out, @later) == 10
      assert Invariants.check(org) == []
    end

    test "no one transfers more than they hold" do
      assert {:error, {:insufficient, 30}} =
               Ownership.transfer(llc(), :bob, :out, :llc, :equity, 31, @later)

      assert {:error, :units} = Ownership.transfer(llc(), :bob, :out, :llc, :equity, 0, @later)
    end

    test "a transfer that would put an ineligible holder in an employee-only class is refused" do
      org =
        Org.new([people([:ann, :bob, :out]), Forms.worker_cooperative(:wc, [:ann, :bob], :ann)])

      assert {:error, :ineligible} =
               Ownership.transfer(org, :bob, :out, :wc, :membership, 1, @later)

      assert {:ok, _, %{claimants: []}} =
               Ownership.transfer(org, :bob, :ann, :wc, :membership, 1, @later)
    end
  end

  describe "terms travel with units" do
    @term ~D[2027-01-01]

    defp termed(stakes) do
      Org.new([people([:ann, :out]), Forms.entity(:co), stakes])
    end

    defp held(org, p, t), do: Org.holding(org, p, :co, :equity, t)

    test "a transferred unit keeps the end date of the stake it came from" do
      org = termed([%Stake{holder: :ann, in: :co, units: 50, during: Interval.new(nil, @term)}])
      {:ok, moved, _} = Ownership.transfer(org, :ann, :out, :co, :equity, 10, @later)
      assert {held(moved, :ann, @later), held(moved, :out, @later)} == {40, 10}
      assert {held(moved, :ann, @term), held(moved, :out, @term)} == {0, 0}
      assert held(moved, :ann, @t) == 50
    end

    test "mixed terms are consumed soonest-expiring first" do
      org =
        termed([
          %Stake{holder: :ann, in: :co, units: 30},
          %Stake{holder: :ann, in: :co, units: 20, during: Interval.new(nil, @term)}
        ])

      {:ok, moved, _} = Ownership.transfer(org, :ann, :out, :co, :equity, 25, @later)
      assert {held(moved, :ann, @later), held(moved, :out, @later)} == {25, 25}
      assert {held(moved, :ann, ~D[2027-06-01]), held(moved, :out, ~D[2027-06-01])} == {25, 5}
    end
  end

  describe "pre-emption (shufʿa)" do
    defp pre, do: llc([], preemption: true)

    test "a sale to an outsider gives co-owners the right to pre-empt" do
      assert {:ok, _, %{claimants: claimants}} =
               Ownership.transfer(pre(), :ann, :out, :llc, :equity, 10, @later, price: 1_000)

      assert Enum.sort(claimants) == [:bob, :cat]
    end

    test "no pre-emption on a gift, a sale to a co-owner, or a class without it" do
      assert {:ok, _, %{claimants: []}} =
               Ownership.transfer(pre(), :ann, :out, :llc, :equity, 10, @later)

      assert {:ok, _, %{claimants: []}} =
               Ownership.transfer(pre(), :ann, :bob, :llc, :equity, 10, @later, price: 1)

      assert {:ok, _, %{claimants: []}} =
               Ownership.transfer(llc(), :ann, :out, :llc, :equity, 10, @later, price: 1)
    end

    test "pre-emptors take the sold share in proportion to their holdings, exactly" do
      {:ok, sold, sale} =
        Ownership.transfer(pre(), :ann, :out, :llc, :equity, 10, @later, price: 1_000)

      {:ok, org} = Ownership.preempt(sold, sale, [:bob, :cat])

      assert {units(org, :bob, @later), units(org, :cat, @later), units(org, :out, @later)} ==
               {36, 24, 0}

      assert {units(org, :bob, @t), units(org, :ann, @t)} == {30, 50}
      assert {:ok, solo} = Ownership.preempt(sold, sale, [:cat])
      assert {units(solo, :cat, @later), units(solo, :out, @later)} == {30, 0}

      {:ok, sold7, sale7} =
        Ownership.transfer(pre(), :ann, :out, :llc, :equity, 7, @later, price: 700)

      assert {:error, :indivisible} = Ownership.preempt(sold7, sale7, [:bob, :cat])
      assert {:error, :not_entitled} = Ownership.preempt(sold, sale, [:ann])
      assert {:error, :not_entitled} = Ownership.preempt(sold, sale, [])
    end
  end

  describe "majority by revocable mandate (wakāla)" do
    defp mandate(p, during \\ Interval.always()),
      do: %Line{kind: :mandates, from: p, to: {:llc, :owners}, grants: [:sell], during: during}

    test "without mandates, a sale needs everyone" do
      assert {:failed, _} =
               Decision.decide(
                 llc(),
                 {:llc, :owners},
                 :sell,
                 %{ann: :yes, bob: :yes, cat: :no},
                 @t
               )
    end

    test "owners who mandated the body are bound by its ordinary rule" do
      org = llc(for p <- [:ann, :bob, :cat], do: mandate(p))
      assert Invariants.check(org) == []

      assert {:carried, _} =
               Decision.decide(org, {:llc, :owners}, :sell, %{ann: :yes, bob: :yes, cat: :no}, @t)

      assert {:failed, _} =
               Decision.decide(org, {:llc, :owners}, :sell, %{ann: :yes, bob: :no, cat: :no}, @t)
    end

    test "an owner who did not mandate must still consent" do
      org = llc([mandate(:ann), mandate(:bob)])

      assert {:failed, _} =
               Decision.decide(org, {:llc, :owners}, :sell, %{ann: :yes, bob: :yes, cat: :no}, @t)

      assert {:carried, _} =
               Decision.decide(org, {:llc, :owners}, :sell, %{ann: :yes, bob: :no, cat: :yes}, @t)
    end

    test "a mandate is revocable: once revoked, the owner's consent is required again" do
      org = llc([mandate(:ann), mandate(:bob), mandate(:cat, Interval.new(nil, @later))])
      votes = %{ann: :yes, bob: :yes, cat: :no}
      assert {:carried, _} = Decision.decide(org, {:llc, :owners}, :sell, votes, @t)
      assert {:failed, _} = Decision.decide(org, {:llc, :owners}, :sell, votes, @later)
    end

    test "only owners can mandate, and only an owners body" do
      stray = %Line{kind: :mandates, from: :out, to: {:llc, :owners}, grants: [:sell]}
      assert Enum.any?(Invariants.check(llc([stray])), &match?({:mandates, _, _}, &1))
    end
  end

  test "Class carries tenure and pre-emption" do
    assert %Class{tenure: :binding, preemption: false} = %Class{}
    assert %Stake{} = %Stake{}
  end
end
