defmodule BarterCoreTest do
  use ExUnit.Case, async: true

  alias BarterCore
  alias BarterCore.Agreement

  @now 1_800_000_000

  defp intent(key, provides, needs, revision \\ 1) do
    %{
      id: "https://#{key}.example/barter/1",
      owner: "https://#{key}.example/actors/shop",
      revision: revision,
      valid_until: @now + 1_000,
      provides: asset(provides),
      needs: asset(needs)
    }
  end

  defp asset({code, unit, quantity}),
    do: %{code: code, unit: unit, quantity: quantity}

  defp pair do
    [
      intent("alpha", {"grain", "kg", 10}, {"milk", "l", 4}),
      intent("beta", {"milk", "l", 6}, {"grain", "kg", 8})
    ]
  end

  test "exact bilateral route: both owners deliver directly and unused stock stays with owner" do
    assert {:ok, [route]} = BarterCore.routes(Enum.reverse(pair()), @now)

    assert route.participants == [
             "https://alpha.example/actors/shop",
             "https://beta.example/actors/shop"
           ]

    assert Enum.map(route.legs, & &1.asset.quantity) == [8, 4]

    assert Enum.map(route.legs, &{&1.from, &1.to}) == [
             {"https://alpha.example/actors/shop", "https://beta.example/actors/shop"},
             {"https://beta.example/actors/shop", "https://alpha.example/actors/shop"}
           ]

    assert {:ok, ^route} = BarterCore.verify_route(route, @now)
    assert route.terms_hash =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "three-party cycles require no broker or transfer through an intermediary" do
    intents = [
      intent("a", {"wood", "m3", 3}, {"labor", "hour", 5}),
      intent("b", {"transport", "hour", 2}, {"wood", "m3", 2}),
      intent("c", {"labor", "hour", 8}, {"transport", "hour", 1})
    ]

    assert {:ok, [route]} = BarterCore.routes(intents, @now)
    assert length(route.legs) == 3

    assert Enum.map(route.legs, &{&1.from, &1.to}) == [
             {"https://a.example/actors/shop", "https://b.example/actors/shop"},
             {"https://b.example/actors/shop", "https://c.example/actors/shop"},
             {"https://c.example/actors/shop", "https://a.example/actors/shop"}
           ]

    assert Enum.map(route.legs, & &1.asset.quantity) == [2, 1, 5]
  end

  test "four-party cycles are bounded by max_parties" do
    intents = [
      intent("a", {"a", "piece", 1}, {"d", "piece", 1}),
      intent("b", {"b", "piece", 1}, {"a", "piece", 1}),
      intent("c", {"c", "piece", 1}, {"b", "piece", 1}),
      intent("d", {"d", "piece", 1}, {"c", "piece", 1})
    ]

    assert {:ok, []} = BarterCore.routes(intents, @now, 3)
    assert {:ok, [route]} = BarterCore.routes(intents, @now, 4)
    assert length(route.participants) == 4
  end

  test "strict exact units, quantities, expiry and same-owner guard" do
    [a, b] = pair()
    assert {:ok, []} = BarterCore.routes([a, put_in(b.needs.unit, "g")], @now)
    assert {:ok, []} = BarterCore.routes([a, put_in(b.needs.quantity, 11)], @now)
    assert {:ok, []} = BarterCore.routes([a, %{b | valid_until: @now}], @now)

    assert {:ok, []} =
             BarterCore.routes(
               [a, %{b | owner: a.owner, id: "https://alpha.example/barter/2"}],
               @now
             )
  end

  test "spoofed origins, duplicate IDs, extra private fields and non-integers refuse" do
    [a, b] = pair()
    assert {:error, :duplicate_intent} = BarterCore.routes([a, a], @now)

    assert {:error, :invalid_intents} =
             BarterCore.routes([a, %{b | owner: "https://evil.example/actors/forged"}], @now)

    assert {:error, :invalid_intents} = BarterCore.routes([a, Map.put(b, :email, "secret")], @now)

    assert {:error, :invalid_intents} =
             BarterCore.routes([a, put_in(b.provides.quantity, 2.5)], @now)

    assert {:error, :too_many_intents} = BarterCore.routes(List.duplicate(a, 17), @now)
    assert {:error, :invalid_intents} = BarterCore.routes([a, b], @now, 5)
  end

  test "terms pin all revisions and leg quantities; route tampering cannot enter preview" do
    assert {:ok, [route]} = BarterCore.routes(pair(), @now)
    [a, b] = pair()

    assert {:ok, [changed]} = BarterCore.routes([%{a | revision: 2}, b], @now)
    refute changed.terms_hash == route.terms_hash

    assert {:error, :invalid_route} =
             BarterCore.verify_route(
               put_in(route, [:legs, Access.at(0), :asset, :quantity], 9),
               @now
             )
  end

  test "conditional accounting is only a preview, never posted delivery or settlement" do
    assert {:ok, [route]} = BarterCore.routes(pair(), @now)

    consents =
      Enum.map(route.participants, fn participant ->
        %{
          actor: participant,
          terms_hash: route.terms_hash,
          evidence_ref: "host-verification-required-" <> participant
        }
      end)

    assert {:ok, preview} = Agreement.pre_delivery_preview(route, consents, @now)
    assert preview.status == :requires_independent_local_admission
    assert Enum.all?(preview.entries, &(&1.state == :not_admitted))
    assert Enum.all?(preview.entries, &(&1.kind == :conditional_barter_delivery))

    assert {:error, :invalid_consents} =
             Agreement.pre_delivery_preview(route, tl(consents), @now)

    assert {:error, :invalid_consents} =
             Agreement.pre_delivery_preview(route, [hd(consents), hd(consents)], @now)

    assert {:error, :invalid_consents} =
             Agreement.pre_delivery_preview(
               route,
               [hd(consents), %{List.last(consents) | terms_hash: String.duplicate("0", 64)}],
               @now
             )

    assert {:error, :invalid_route} =
             Agreement.pre_delivery_preview(route, consents, @now + 1_000)
  end
end
