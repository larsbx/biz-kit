defmodule Keel.Ownership do
  @moduledoc """
  Rights that flow from ownership rather than office: each owner disposes of
  their own share, may leave a revocable (*jāʾiz*) partnership, and — where the
  class grants it — co-owners may pre-empt a sale to an outsider (*shufʿa*).

  Every operation is a pure function `Org → Org` effective from instant `t`:
  current stakes are closed at `t` and successors opened, so history before
  `t` is unchanged. Stakes opened here are open-ended.
  """
  alias Keel.{Class, Interval, Invariants, Org, Stake}

  defmodule Transfer do
    @moduledoc "A completed transfer of `units` of `class` in `in` at `at`; `claimants` may pre-empt it."
    defstruct [:from, :to, :in, :class, :units, :at, price: nil, claimants: []]
  end

  def revocable?(org, e, class), do: match?(%Class{tenure: :revocable}, Org.class(org, e, class))
  def preemptive?(org, e, class), do: match?(%Class{preemption: true}, Org.class(org, e, class))

  @doc "Holders of `class` in `e` at `t`."
  def holders(org, e, class, t),
    do:
      for(%Stake{in: ^e, class: ^class, holder: h} <- Org.edges(org, Stake, t), uniq: true, do: h)

  @doc "`p` leaves `e` at `t`, relinquishing all stakes; every class held must be revocable."
  def withdraw(org, p, e, t) do
    classes =
      for %Stake{holder: ^p, in: ^e, class: c} <- Org.edges(org, Stake, t), uniq: true, do: c

    cond do
      classes == [] -> {:error, :not_owner}
      not Enum.all?(classes, &revocable?(org, e, &1)) -> {:error, :binding}
      true -> {:ok, Enum.reduce(classes, org, &rebalance(&2, p, e, &1, t, 0))}
    end
  end

  @doc """
  `from` transfers `units` of their own `class` holding in `e` to `to` at `t`; no
  other owner's consent is needed. Refused if it would seat an ineligible holder.
  With `price:` (a sale, not a gift) to a non-holder of a pre-emptive class, the
  other holders become `claimants`.
  """
  def transfer(org, from, to, e, class, units, t, opts \\ []) do
    held = Org.holding(org, from, e, class, t)

    cond do
      not (is_integer(units) and units > 0) ->
        {:error, :units}

      held < units ->
        {:error, {:insufficient, held}}

      true ->
        moved =
          org
          |> rebalance(from, e, class, t, held - units)
          |> rebalance(to, e, class, t, Org.holding(org, to, e, class, t) + units)

        if {:ineligible, to, e, class} in Invariants.eligibility(moved, t) do
          {:error, :ineligible}
        else
          price = opts[:price]

          {:ok, moved,
           %Transfer{
             from: from,
             to: to,
             in: e,
             class: class,
             units: units,
             at: t,
             price: price,
             claimants: claimants(org, from, to, e, class, t, price)
           }}
        end
    end
  end

  defp claimants(_, _, _, _, _, _, nil), do: []

  defp claimants(org, from, to, e, class, t, _price) do
    co = holders(org, e, class, t) -- [from]
    if preemptive?(org, e, class) and to not in co, do: co, else: []
  end

  @doc """
  `takers` (entitled claimants of `sale`) take the sold units from the buyer at
  the sale instant, in exact proportion to their own holdings.
  """
  def preempt(org, %Transfer{to: buyer, in: e, class: c, units: n, at: t, claimants: cl}, takers) do
    takers = Enum.uniq(takers)
    shares = for p <- takers, do: {p, Org.holding(org, p, e, c, t)}
    total = Enum.sum(for {_, h} <- shares, do: h)

    cond do
      takers == [] or not Enum.all?(takers, &(&1 in cl)) ->
        {:error, :not_entitled}

      Enum.any?(shares, fn {_, h} -> rem(n * h, total) != 0 end) ->
        {:error, :indivisible}

      true ->
        {:ok,
         Enum.reduce(shares, org, fn {p, h}, acc ->
           {:ok, acc, _} = transfer(acc, buyer, p, e, c, div(n * h, total), t)
           acc
         end)}
    end
  end

  # Close `p`'s current `class` stakes in `e` at `t` and open one of `units` (if any).
  defp rebalance(org, p, e, class, t, units) do
    edges =
      Enum.flat_map(org.edges, fn
        %Stake{holder: ^p, in: ^e, class: ^class, during: i} = s ->
          cond do
            not Interval.contains?(i, t) -> [s]
            i.from != nil and Date.compare(i.from, t) == :eq -> []
            true -> [%{s | during: %{i | to: t}}]
          end

        x ->
          [x]
      end)

    successor =
      for u <- [units],
          u > 0,
          do: %Stake{holder: p, in: e, class: class, units: u, during: Interval.new(t)}

    %{org | edges: successor ++ edges}
  end
end
