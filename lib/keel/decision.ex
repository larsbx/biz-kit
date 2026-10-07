defmodule Keel.Decision do
  @moduledoc """
  Collective decisions by a `Keel.Body` on a `matter` (a capability) at instant
  `t`, in exact rational arithmetic.

  `votes :: %{party => :yes | :no | :abstain}`; votes by non-members are ignored.
  A member entity with bodies voicing the matter votes by look-through, never
  directly: its voicing bodies (`Keel.Org.voices/3`) decide on the same matter
  and votes, most specific first, and the first to reach a decision gives the
  entity's vote (`:carried → :yes`, `:failed → :no`); if none does, the entity is
  absent. An entity with no voicing body (outside the model) votes directly.

  Returns `{:ultra_vires, nil}` when the body is not competent for the matter
  (`Keel.Org.competent?/4`), else `{:carried | :failed | :inquorate, tally}`.
  """
  alias Keel.{Body, Org, Party}

  def decide(org, body_id, matter, votes, t),
    do: decide(org, body_id, matter, votes, t, MapSet.new([Org.get(org, body_id).of]))

  defp decide(org, body_id, matter, votes, t, seen) do
    %Body{quorum: {qn, qd}, pass: {op, {n, d}}} = body = Org.get(org, body_id)

    if Org.competent?(org, body, matter, t) do
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
    case {Org.get(org, p), Org.voices(org, p, matter)} do
      {%Party{kind: :entity}, [_ | _] = bodies} ->
        if not MapSet.member?(seen, p) do
          seen = MapSet.put(seen, p)
          Enum.find_value(bodies, &verdict(decide(org, &1, matter, votes, t, seen)))
        end

      _ ->
        Map.get(votes, p)
    end
  end

  defp verdict({:carried, _}), do: :yes
  defp verdict({:failed, _}), do: :no
  defp verdict(_), do: nil

  defp meets?(:gt, a, b), do: a > b
  defp meets?(:ge, a, b), do: a >= b
end
