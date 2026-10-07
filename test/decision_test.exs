defmodule Keel.DecisionTest do
  use ExUnit.Case, async: true
  alias Keel.{Body, Decision, Org, Party, Stake}

  @t ~D[2026-06-01]

  defp org(body_opts) do
    Org.new([
      %Party{id: :co, kind: :entity},
      for(p <- [:a, :b, :c], do: %Party{id: p, kind: :person}),
      %Stake{holder: :a, in: :co, class: :x, units: 70},
      %Stake{holder: :b, in: :co, class: :x, units: 20},
      %Stake{holder: :c, in: :co, class: :x, units: 10},
      struct!(Body, [id: :g, of: :co, members: {:stake, :x}] ++ body_opts)
    ])
  end

  test "same votes, different weighting: capital vs one-member-one-vote" do
    votes = %{a: :yes, b: :no, c: :no}

    assert {:carried, %{yes: 70, no: 30}} =
             Decision.decide(org(weight: {:units, :x}), :g, votes, @t)

    assert {:failed, %{yes: 1, no: 2}} = Decision.decide(org(weight: :per_capita), :g, votes, @t)
  end

  test "quorum counts presence, including abstentions" do
    b = [weight: :per_capita, quorum: {2, 3}]
    assert {:inquorate, _} = Decision.decide(org(b), :g, %{a: :yes}, @t)
    assert {:carried, _} = Decision.decide(org(b), :g, %{a: :yes, b: :abstain}, @t)
  end

  test "thresholds are exact rationals; :gt vs :ge at the boundary" do
    votes = %{a: :yes, b: :no}
    half = [weight: :per_capita, quorum: {0, 1}]
    assert {:failed, _} = Decision.decide(org(half ++ [pass: {:gt, {1, 2}}]), :g, votes, @t)
    assert {:carried, _} = Decision.decide(org(half ++ [pass: {:ge, {1, 2}}]), :g, votes, @t)
    assert {:failed, _} = Decision.decide(org(half ++ [pass: {:ge, {1, 1}}]), :g, votes, @t)
  end

  test "non-members' votes are ignored" do
    assert {:failed, %{yes: 0}} =
             Decision.decide(org(weight: :per_capita), :g, %{zed: :yes, a: :no, b: :no}, @t)
  end
end
