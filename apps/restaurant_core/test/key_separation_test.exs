defmodule RestaurantCore.KeySeparationTest do
  @moduledoc """
  The fence on new restaurant grants. Within a chapter, a Dispatch key shares
  nothing with the restaurant side (its device keys and declared role keys) and
  serves one tenant. Within a merchant, a key is granted at most once, so a
  revoked seed is never granted there again.

  `apart?/2` and `once?/1` below state the invariant independently of the
  implementation. For every grant, `check/2` admits exactly when `admit/3` does
  and the invariant still holds afterwards. Revoked grants stay in the state,
  so they keep counting. `fold/2` stays as permissive as `admit/3`, so a ledger
  that already holds a collision still replays.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias RestaurantCore.Admission

  @t1 "11111111-1111-1111-1111-111111111111"
  @t2 "22222222-2222-2222-2222-222222222222"

  defp pk(name), do: :crypto.hash(:sha256, name)

  defp gov(ch), do: %{role: "governance", key_id: "gov", pubkey: pk("gov:" <> ch)}

  defp env(type, ch, payload, signer \\ nil),
    do: %{type: type, chapter_id: ch, signers: [signer || gov(ch)], payload: payload}

  defp device(ch, merchant, key_id, pubkey, signer \\ nil),
    do:
      env(
        "RestaurantDeviceGrantedV1",
        ch,
        %{
          "merchant_id" => merchant,
          "device_id" => "device-" <> key_id,
          "key_id" => key_id,
          "pubkey" => {:bytes, pubkey},
          "actor" => "staff",
          "actions" => ["accept"]
        },
        signer
      )

  defp dispatch(ch, merchant, key_id, pubkey, tenant, signer \\ nil),
    do:
      env(
        "RestaurantDispatchGrantedV1",
        ch,
        %{
          "merchant_id" => merchant,
          "tenant_id" => tenant,
          "key_id" => key_id,
          "pubkey" => {:bytes, pubkey}
        },
        signer
      )

  defp revoke(ch, merchant, key_id),
    do: env("RestaurantDeviceRevokedV1", ch, %{"merchant_id" => merchant, "key_id" => key_id})

  # "ch" declares governance and a steward; "far" governance and a checkpoint.
  @keys %{
    {"ch", "governance"} => %{"gov" => :crypto.hash(:sha256, "gov:ch")},
    {"ch", "steward"} => %{"stw" => :crypto.hash(:sha256, "steward")},
    {"far", "governance"} => %{"gov" => :crypto.hash(:sha256, "gov:far")},
    {"far", "checkpoint"} => %{"cp" => :crypto.hash(:sha256, "checkpoint")}
  }

  defp admit_all(events) do
    Enum.reduce(events, Admission.init(), fn e, state ->
      g = %{role_keys: @keys, restaurant: state}
      assert Admission.check(e, g) == :ok, inspect({e.payload, Admission.check(e, g)})
      Admission.fold(e, g)
    end)
  end

  # In "ch" at "shop": device pos, Dispatch courier for T1, and device old,
  # since revoked. In "far" at "shop": device far.
  defp base,
    do: %{
      role_keys: @keys,
      restaurant:
        admit_all([
          device("ch", "shop", "pos", pk("pos")),
          dispatch("ch", "shop", "courier", pk("courier"), @t1),
          device("ch", "shop", "old", pk("old")),
          revoke("ch", "shop", "old"),
          device("far", "shop", "far", pk("far"))
        ])
    }

  # {why, event, :ok | {:fence, reason} | {:admit, reason}}. A :fence refusal
  # comes from check/2 alone; an :admit refusal is admit/3's own, which wins.
  defp cases,
    do: [
      {"Dispatch: a device key at its merchant", dispatch("ch", "shop", "d", pk("pos"), @t1),
       {:fence, :key_not_separate}},
      {"Dispatch: a device key at another merchant", dispatch("ch", "deli", "d", pk("pos"), @t1),
       {:fence, :key_not_separate}},
      {"Dispatch: a revoked device key", dispatch("ch", "deli", "d", pk("old"), @t1),
       {:fence, :key_not_separate}},
      {"Dispatch: the chapter's governance key", dispatch("ch", "deli", "d", pk("gov:ch"), @t1),
       {:fence, :key_not_separate}},
      {"Dispatch: the chapter's steward key", dispatch("ch", "deli", "d", pk("steward"), @t1),
       {:fence, :key_not_separate}},
      {"Dispatch: its key for another tenant", dispatch("ch", "deli", "d", pk("courier"), @t2),
       {:fence, :key_not_separate}},
      {"Dispatch: its key, its tenant, another merchant",
       dispatch("ch", "deli", "d", pk("courier"), @t1), :ok},
      {"Dispatch: its key under a new key id at its merchant",
       dispatch("ch", "shop", "d", pk("courier"), @t1),
       {:fence, :restaurant_key_already_granted}},
      {"Dispatch: another chapter's role key", dispatch("ch", "deli", "d", pk("checkpoint"), @t1),
       :ok},
      {"Dispatch: another chapter's device key", dispatch("ch", "deli", "d", pk("far"), @t1),
       :ok},
      {"device: the Dispatch key", device("ch", "deli", "k", pk("courier")),
       {:fence, :key_not_separate}},
      {"device: the Dispatch key at its merchant (sides before once)",
       device("ch", "shop", "k", pk("courier")), {:fence, :key_not_separate}},
      {"device: its key at another merchant", device("ch", "deli", "k", pk("pos")), :ok},
      {"device: its key under a new key id", device("ch", "shop", "k", pk("pos")),
       {:fence, :restaurant_key_already_granted}},
      {"device: a revoked key under a new key id", device("ch", "shop", "k", pk("old")),
       {:fence, :restaurant_key_already_granted}},
      {"device: a revoked key at another merchant", device("ch", "deli", "k", pk("old")), :ok},
      {"device: another chapter's Dispatch key", device("far", "shop", "k", pk("courier")), :ok},
      {"admission first: a reused key id", dispatch("ch", "shop", "courier", pk("pos"), @t1),
       {:admit, :restaurant_key_already_granted}},
      {"admission first: an undeclared signer",
       dispatch("ch", "deli", "d", pk("pos"), @t1, %{gov("ch") | pubkey: pk("rogue")}),
       {:admit, :restaurant_governance_not_declared}},
      {"revocation is untouched", revoke("ch", "shop", "pos"), :ok}
    ]

  test "each grant against a chapter's keys: who may reuse what, and which refusal wins" do
    g = base()

    for {why, e, expected} <- cases() do
      case expected do
        :ok ->
          assert Admission.check(e, g) == :ok, why

        {:admit, reason} ->
          assert Admission.check(e, g) == {:error, reason}, why
          assert Admission.admit(e, g.role_keys, g.restaurant) == {:error, reason}, why

        {:fence, reason} ->
          assert Admission.check(e, g) == {:error, reason}, why
          # The fence is check's alone: fold still admits it, so history that
          # holds such a grant replays.
          assert %{grants: grants} = Admission.fold(e, g), why
          assert map_size(grants) == map_size(g.restaurant.grants) + 1, why
      end
    end
  end

  test "a Dispatch key is one of the chapter's Dispatch keys, revoked or not" do
    g = base()
    assert Admission.dispatch_pubkey?(g.restaurant, "ch", pk("courier"))
    assert Admission.dispatch_pubkey?(g.restaurant, "ch", {:bytes, pk("courier")})
    refute Admission.dispatch_pubkey?(g.restaurant, "far", pk("courier"))
    refute Admission.dispatch_pubkey?(g.restaurant, "ch", pk("pos"))

    revoked = Admission.fold(revoke("ch", "shop", "courier"), g)
    assert Admission.dispatch_pubkey?(revoked, "ch", pk("courier"))
  end

  # -- The invariant, stated without the implementation ---------------------

  defp side(%{actor: :dispatch}), do: :dispatch
  defp side(_), do: :device

  defp role_keys(keys, ch),
    do: for({{^ch, _role}, ids} <- keys, key <- Map.values(ids), do: key)

  # Within a chapter: one key, one side; a Dispatch key is no role key and
  # serves one tenant.
  defp apart?(state, keys) do
    grants = Map.to_list(state.grants)

    shared =
      for {{ch, _, _} = i, g} <- grants,
          {{^ch, _, _} = j, h} <- grants,
          i < j and g.pubkey == h.pubkey,
          do: {g, h}

    Enum.all?(shared, fn {g, h} ->
      side(g) == side(h) and (side(g) == :device or g.tenant == h.tenant)
    end) and
      Enum.all?(grants, fn {{ch, _, _}, g} ->
        side(g) == :device or g.pubkey not in role_keys(keys, ch)
      end)
  end

  # Within a merchant: each key granted once, revoked or not.
  defp once?(state),
    do:
      state.grants
      |> Enum.frequencies_by(fn {{ch, merchant, _}, g} -> {ch, merchant, g.pubkey} end)
      |> Enum.all?(fn {_, n} -> n == 1 end)

  @domain %{
    chapters: ~w(a b),
    merchants: ~w(m1 m2),
    key_ids: ~w(k1 k2 k3),
    pubkeys: Enum.map(~w(p1 p2 p3 p4), &:crypto.hash(:sha256, &1)),
    tenants: [
      "11111111-1111-1111-1111-111111111111",
      "22222222-2222-2222-2222-222222222222"
    ]
  }

  # p4 is a steward key of "a", p3 a checkpoint key of "b".
  @small_keys %{
    {"a", "governance"} => %{"gov" => :crypto.hash(:sha256, "gov:a")},
    {"b", "governance"} => %{"gov" => :crypto.hash(:sha256, "gov:b")},
    {"a", "steward"} => %{"s" => :crypto.hash(:sha256, "p4")},
    {"b", "checkpoint"} => %{"c" => :crypto.hash(:sha256, "p3")}
  }

  defp event do
    d = @domain
    at = tuple({member_of(d.chapters), member_of(d.merchants), member_of(d.key_ids)})
    key = member_of(d.pubkeys)

    one_of([
      map(tuple({at, key}), fn {{c, m, k}, p} -> device(c, m, k, p) end),
      map(tuple({at, key, member_of(d.tenants)}), fn {{c, m, k}, p, t} ->
        dispatch(c, m, k, p, t)
      end),
      map(at, fn {c, m, k} -> revoke(c, m, k) end)
    ])
  end

  property "check/2 admits a grant exactly when admit/3 does and the chapter's keys stay apart, once each" do
    check all(events <- list_of(event(), max_length: 30), max_runs: 400) do
      Enum.reduce(events, Admission.init(), fn e, state ->
        g = %{role_keys: @small_keys, restaurant: state}

        expected =
          case Admission.admit(e, @small_keys, state) do
            {:error, _} = refused ->
              refused

            {:ok, next} ->
              cond do
                not apart?(next, @small_keys) -> {:error, :key_not_separate}
                not once?(next) -> {:error, :restaurant_key_already_granted}
                true -> :ok
              end
          end

        assert Admission.check(e, g) == expected

        case expected do
          :ok ->
            next = Admission.fold(e, g)
            assert apart?(next, @small_keys) and once?(next)
            next

          _ ->
            state
        end
      end)
    end
  end
end
