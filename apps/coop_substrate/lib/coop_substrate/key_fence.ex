defmodule CoopSubstrate.KeyFence do
  @moduledoc """
  The chapter key fence: within a chapter, each public key has one holder. An
  event that binds a key is a claim for its holder (`holder/1`), refused while
  a holding of that key in its chapter breaks a rule against it
  (`conflicts/2`).

  Holders:

    * `:restaurant_core` — `RoleKeyDeclared` and both restaurant grant types.
      Within the holder, RestaurantCore's one relation decides
      (`RestaurantCore.Admission.key_conflicts/2` for a grant,
      `role_key_conflicts/3` for a role key): no grant holds a declared role
      key, a Dispatch key is none of the chapter's device keys and serves one
      tenant, and a merchant grants each key once.
    * `{:dispatcher, tenant, key_id}` — each `DispatchDispatcherGrantedV1`,
      so a dispatcher key is granted once in its chapter.
    * `{:procurement_route, cooperative}` — a cooperative's active
      `ProcurementDispatchRouteV1`: the route never conflicts with its own
      earlier versions, and serves no other cooperative.
    * `:procurement_operator` — every active `ProcurementOperatorGrantedV1`:
      one operator key may serve several cooperatives and operator slots.

  A holding of another holder is always a conflict (`:holder_key_reuse`).
  Grants count revoked or not, and dispatchers forever (they are never
  revoked); a role key only while it is declared; a procurement version only
  if it was active, and then forever, even once its slot rotates away or
  deactivates. A version with `active` false claims nothing, so the fence
  never refuses deactivating a slot, even where history already holds a
  collision.
  Another chapter's keys never count.

  `CoopSubstrate.Protocol.Validity.check/2` applies it last, so the append
  gate and Commands preflight refuse a claim, and a domain refusal comes first.
  No fold applies it: history admitted before the fence, or by an appender
  without it, boots and replays unchanged, and only the next claim is refused.
  `CoopSubstrate.RestaurantKeyAudit` replays it over a ledger's history to
  find such claims.
  """

  alias CoopSubstrate.{Procurement, ProcurementDispatch}
  alias DispatchCore.Admission, as: Dispatch
  alias RestaurantCore.Admission, as: Restaurant

  @grants ~w(RestaurantDeviceGrantedV1 RestaurantDispatchGrantedV1)
  @dispatcher "DispatchDispatcherGrantedV1"
  @route "ProcurementDispatchRouteV1"
  @operator "ProcurementOperatorGrantedV1"

  @doc "The holder an event claims its key for, or nil when it claims none."
  def holder(%{type: type}) when type in ["RoleKeyDeclared" | @grants], do: :restaurant_core
  def holder(%{type: @dispatcher, payload: p}), do: {:dispatcher, p["tenant_id"], p["key_id"]}

  def holder(%{type: @route, payload: %{"active" => true} = p}),
    do: {:procurement_route, p["cooperative_id"]}

  def holder(%{type: @operator, payload: %{"active" => true}}), do: :procurement_operator
  def holder(_), do: nil

  @doc "The holding a key event's binding is listed as in `holdings/3`."
  def witness(%{type: "RoleKeyDeclared", payload: p}), do: {:role, p["role"], p["key_id"]}

  def witness(%{type: type, payload: p}) when type in @grants,
    do: {:grant, p["merchant_id"], p["key_id"]}

  def witness(%{type: @dispatcher} = env), do: holder(env)
  def witness(%{type: @route, payload: p}), do: {:route, p["cooperative_id"]}

  def witness(%{type: @operator, payload: p}),
    do: {:operator, p["cooperative_id"], p["operator_id"]}

  @doc "The chapter's holdings of `pubkey`, as `{holder, holding}`."
  def holdings(gate, chapter, pubkey) do
    restaurant =
      for held <- Restaurant.key_holdings(gate, chapter, pubkey), do: {:restaurant_core, held}

    dispatchers =
      for {tenant, key_id} <- Dispatch.grants(gate.dispatch, chapter, pubkey),
          held = {:dispatcher, tenant, key_id},
          do: {held, held}

    procurement =
      for env <- Procurement.key_events(Procurement.state(gate), chapter, pubkey),
          holder = holder(env),
          uniq: true,
          do: {holder, witness(env)}

    restaurant ++ dispatchers ++ procurement
  end

  @doc """
  Whether the holding `held` still binds `pubkey` in `chapter` at `gate`: a
  grant until it is revoked, a role key while it is declared on that key, a
  dispatcher always (it is never revoked), and a route or operator slot while
  its current version is active on that key. The key audit asks; no claim
  depends on it.
  """
  def live?(gate, chapter, pubkey, {:grant, merchant, key_id}) do
    case gate.restaurant.grants[{chapter, merchant, key_id}] do
      %{pubkey: ^pubkey} = grant -> not Map.get(grant, :revoked, false)
      _ -> false
    end
  end

  def live?(gate, chapter, pubkey, {:role, role, key_id}),
    do: get_in(gate.role_keys, [{chapter, role}, key_id]) == pubkey

  def live?(_gate, _chapter, _pubkey, {:dispatcher, _tenant, _key_id}), do: true

  def live?(gate, chapter, pubkey, {:route, coop}),
    do: active?(ProcurementDispatch.route(Procurement.state(gate), chapter, coop), pubkey)

  def live?(gate, chapter, pubkey, {:operator, coop, operator}),
    do: active?(Procurement.state(gate).grants[{chapter, coop, operator}], pubkey)

  defp active?(version, pubkey), do: match?(%{active: true, pubkey: ^pubkey}, version)

  @doc """
  The rules a claim breaks in its chapter, each with the holding it breaks it
  against: its holder's own, most decisive first, then every holding of
  another holder. `[]` for an event that claims no key.
  """
  def conflicts(env, gate) do
    case holder(env) do
      nil ->
        []

      holder ->
        own(env, gate) ++
          for {other, held} <- holdings(gate, env.chapter_id, env.payload["pubkey"]),
              other != holder,
              do: {:holder_key_reuse, held}
    end
  end

  defp own(%{type: "RoleKeyDeclared", chapter_id: ch, payload: p}, gate),
    do: Restaurant.role_key_conflicts(gate, ch, p["pubkey"])

  defp own(env, gate), do: Restaurant.key_conflicts(env, gate)

  @doc "`:ok`, or the refusal of the claim's most decisive conflict."
  def check(env, gate) do
    case conflicts(env, gate) do
      [] -> :ok
      [{rule, _} | _] -> {:error, refusal(rule)}
    end
  end

  @doc "The fence's rules."
  def rules, do: Restaurant.key_rules() ++ [:holder_key_reuse]

  @doc "The refusal a broken rule causes."
  def refusal(:holder_key_reuse), do: :key_not_separate
  def refusal(rule), do: Restaurant.refusal(rule)
end
