defmodule CoopSubstrate.Projections.ChapterStats do
  @moduledoc """
  The trivial 1A projection (acceptance §6 item 6): per-chapter event counts,
  the key registry folded from `KeyRotated` events, and the last event id per
  chapter (which makes replay-order violations visible in tests).
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.Protocol.Envelope

  @impl true
  def init do
    %{counts: %{}, keys: %{}, last_event_id: %{}}
  end

  @impl true
  def handle_event(%Envelope{} = env, state) do
    state
    |> update_in([:counts, Access.key(env.chapter_id, 0)], &(&1 + 1))
    |> put_in([:last_event_id, Access.key(env.chapter_id)], env.event_id)
    |> apply_key_rotation(env)
  end

  defp apply_key_rotation(state, %Envelope{type: "KeyRotated", payload: payload}) do
    {:bytes, pubkey} = payload["new_pubkey"]

    put_in(
      state,
      [:keys, Access.key(payload["member_id"])],
      %{key_id: payload["new_key_id"], pubkey: pubkey}
    )
  end

  defp apply_key_rotation(state, _env), do: state
end
