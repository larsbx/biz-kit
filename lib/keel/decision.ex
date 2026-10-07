defmodule Keel.Decision do
  @moduledoc """
  Collective decisions by a `Keel.Body` at instant `t`, in exact rational arithmetic.

  `votes :: %{party => :yes | :no | :abstain}`; votes by non-members are ignored.
  Returns `{:carried | :failed | :inquorate, tally}`.
  """
  alias Keel.{Body, Org}

  def decide(org, body_id, votes, t) do
    %Body{quorum: {qn, qd}, pass: {op, {n, d}}} = body = Org.get(org, body_id)
    weights = Org.members(org, body, t)
    sum = fn pred -> Enum.sum(for {p, w} <- weights, pred.(Map.get(votes, p)), do: w) end

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
  end

  defp meets?(:gt, a, b), do: a > b
  defp meets?(:ge, a, b), do: a >= b
end
