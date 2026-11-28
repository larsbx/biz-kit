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

  A holding of another holder is always a conflict (`:holder_key_reuse`).
  Grants count revoked or not; a role key only while it is declared. Another
  chapter's keys never count.

  `CoopSubstrate.Protocol.Validity.check/2` applies it last, so the append
  gate and Commands preflight refuse a claim, and a domain refusal comes first.
  No fold applies it: history admitted before the fence, or by an appender
  without it, boots and replays unchanged, and only the next claim is refused.
  """

  alias RestaurantCore.Admission, as: Restaurant

  @restaurant ~w(RoleKeyDeclared RestaurantDeviceGrantedV1 RestaurantDispatchGrantedV1)

  @doc "The holder an event claims its key for, or nil when it claims none."
  def holder(%{type: type}) when type in @restaurant, do: :restaurant_core
  def holder(_), do: nil

  @doc "The chapter's holdings of `pubkey`, as `{holder, holding}`."
  def holdings(gate, chapter, pubkey),
    do: for(held <- Restaurant.key_holdings(gate, chapter, pubkey), do: {:restaurant_core, held})

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
