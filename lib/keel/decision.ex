defmodule Keel.Decision do
  @moduledoc """
  Collective decisions by a `Keel.Body` on a `matter` (a capability) at instant
  `t`, in exact rational arithmetic.

  `votes :: %{party => :yes | :no | :abstain}`; votes by non-members are ignored.
  A member entity with bodies voicing the matter votes by look-through, never
  directly: its most specific voicing body (`Keel.Org.voices/3`) decides on the
  same matter and votes (`:carried → :yes`, `:failed → :no`, otherwise absent);
  there is no fallback to a more general voice. An entity with no voicing body
  (outside the model) votes directly.

  Alienation (`Keel.Capability.alienation/0`) carries only with the consent of
  every owner: an absent or abstaining owner is a refusal — unless that owner has
  mandated this body for the matter (`Line` of kind `:mandates`, revocable), in
  which case they are bound by its ordinary rule, which must then also carry.

  Dissolution of an entity whose voting class is revocable (`Keel.Class`
  `tenure: :revocable`) carries on any one holder's yes.

  Returns `{:ultra_vires, nil}` when the body is not competent for the matter
  (`Keel.Org.competent?/4`), else `{:carried | :failed | :inquorate, tally}`.
  """
  alias Keel.{Body, Capability, Line, Org, Ownership, Party}

  def decide(org, body_id, matter, votes, t),
    do: decide(org, body_id, matter, votes, t, MapSet.new([Org.get(org, body_id).of]))

  defp decide(org, body_id, matter, votes, t, seen) do
    %Body{quorum: {qn, qd}, pass: {op, {n, d}}} = body = Org.get(org, body_id)

    if Org.competent?(org, body, matter, t) do
      cast =
        for {p, w} <- Org.members(org, body, t), do: {p, vote(org, p, matter, votes, t, seen), w}

      sum = fn pred -> Enum.sum(for {_, v, w} <- cast, pred.(v), do: w) end

      tally = %{
        eligible: sum.(fn _ -> true end),
        present: sum.(&(&1 != nil)),
        yes: sum.(&(&1 == :yes)),
        no: sum.(&(&1 == :no))
      }

      ordinary =
        cond do
          tally.present * qd < qn * tally.eligible ->
            :inquorate

          tally.yes + tally.no > 0 and meets?(op, tally.yes * d, n * (tally.yes + tally.no)) ->
            :carried

          true ->
            :failed
        end

      outcome =
        cond do
          Capability.alienating?(matter) ->
            consent(cast, mandators(org, body, matter, t), ordinary)

          unilateral?(org, body, matter) ->
            if tally.yes > 0, do: :carried, else: :failed

          true ->
            ordinary
        end

      {outcome, tally}
    else
      {:ultra_vires, nil}
    end
  end

  defp vote(org, p, matter, votes, t, seen) do
    case {Org.get(org, p), Org.voices(org, p, matter)} do
      {%Party{kind: :entity}, [b | _]} ->
        if not MapSet.member?(seen, p),
          do: verdict(decide(org, b, matter, votes, t, MapSet.put(seen, p)))

      _ ->
        Map.get(votes, p)
    end
  end

  # Alienation: every owner who has not mandated the body consents, and — if any
  # owner is bound by mandate — the body's ordinary rule carries.
  defp consent([], _, _), do: :failed

  defp consent(cast, bound, ordinary) do
    cond do
      Enum.any?(cast, fn {p, v, _} -> p not in bound and v != :yes end) -> :failed
      Enum.any?(cast, fn {p, _, _} -> p in bound end) -> ordinary
      true -> :carried
    end
  end

  defp mandators(org, %Body{id: b}, matter, t) do
    for %Line{kind: :mandates, to: ^b, from: p, grants: gs} <- Org.edges(org, Line, t),
        Capability.covered?(gs, matter),
        into: MapSet.new(),
        do: p
  end

  # Dissolution of a revocable contract is any one holder's right.
  defp unilateral?(org, %Body{of: e, members: {:stake, c}}, matter),
    do: Capability.covers?(:dissolve, matter) and Ownership.revocable?(org, e, c)

  defp unilateral?(_, _, _), do: false

  defp verdict({:carried, _}), do: :yes
  defp verdict({:failed, _}), do: :no
  defp verdict(_), do: nil

  defp meets?(:gt, a, b), do: a > b
  defp meets?(:ge, a, b), do: a >= b
end
