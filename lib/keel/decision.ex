defmodule Keel.Decision do
  @moduledoc """
  Collective decisions by a `Keel.Body` on a `matter` (a capability) at instant
  `t`, in exact rational arithmetic.

  `votes :: %{party => :yes | :no | :abstain}`; votes by non-members are ignored.
  A member entity without an explicit vote votes by look-through: the outcome of
  its own voicing body (`Keel.Org.voice/3`) on the same matter and votes —
  `:carried → :yes`, `:failed → :no`, otherwise absent.

  Returns `{:ultra_vires, nil}` when the body's effective grants do not cover the
  matter, else `{:carried | :failed | :inquorate, tally}`.
  """
  alias Keel.{Body, Capability, Org, Party}

  def decide(org, body_id, matter, votes, t),
    do: decide(org, body_id, matter, votes, t, MapSet.new([Org.get(org, body_id).of]))

  defp decide(org, body_id, matter, votes, t, seen) do
    %Body{quorum: {qn, qd}, pass: {op, {n, d}}} = body = Org.get(org, body_id)

    if Capability.covered?(Org.effective(org, body_id, t), matter) do
      cast =
        for {p, w} <- Org.members(org, body, t), do: {vote(org, p, matter, votes, t, seen), w}

      sum = fn pred -> Enum.sum(for {v, w} <- cast, pred.(v), do: w) end

      tally = %{
        eligible: sum.(fn _ -> true end),
        present: sum.(&(&1 != nil)),
        yes: sum.(&(&1 == :yes)),
        no: sum.(&(&1 == :no))
      }

      outcome =
        cond do
          tally.present * qd < qn * tally.eligible ->
            :inquorate

          tally.yes + tally.no > 0 and meets?(op, tally.yes * d, n * (tally.yes + tally.no)) ->
            :carried

          true ->
            :failed
        end

      {outcome, tally}
    else
      {:ultra_vires, nil}
    end
  end

  defp vote(org, p, matter, votes, t, seen) do
    with :error <- Map.fetch(votes, p),
         %Party{kind: :entity} <- Org.get(org, p),
         false <- MapSet.member?(seen, p),
         b when b != nil <- Org.voice(org, p, matter) do
      case decide(org, b, matter, votes, t, MapSet.put(seen, p)) do
        {:carried, _} -> :yes
        {:failed, _} -> :no
        _ -> nil
      end
    else
      {:ok, v} -> v
      _ -> nil
    end
  end

  defp meets?(:gt, a, b), do: a > b
  defp meets?(:ge, a, b), do: a >= b
end
