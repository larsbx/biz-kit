defmodule Keel.Ownership do
  @moduledoc """
  Rights that flow from ownership rather than office: each owner disposes of
  their own share, may leave a revocable (*jāʾiz*) partnership, and — where the
  class grants it — co-owners may pre-empt a sale to an outsider (*shufʿa*).

  Every operation is a pure function `Org → Org` effective from instant `t`:
  current stakes are closed at `t` and successors opened, so history before
  `t` is unchanged. Stakes opened here are open-ended.
  """
  alias Keel.{Asset, Body, Class, Decision, Interval, Invariants, Org, Stake}

  defmodule Transfer do
    @moduledoc "A completed transfer of `units` of `class` in `in` at `at`; `claimants` may pre-empt it."
    defstruct [:from, :to, :in, :class, :units, :at, price: nil, claimants: []]
  end

  defmodule Partition do
    @moduledoc """
    A division plan: `allot` in kind (`party => [{asset, n}]`), `sell` what cannot
    be divided exactly (`[{asset, n}]`), and each party's exact `proceeds` share
    of the sale as a reduced fraction `{num, den}`.
    """
    defstruct allot: %{}, sell: [], proceeds: %{}
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
      classes == [] ->
        {:error, :not_owner}

      not Enum.all?(classes, &revocable?(org, e, &1)) ->
        {:error, :binding}

      true ->
        {:ok,
         Enum.reduce(classes, org, &move(&2, p, nil, e, &1, Org.holding(&2, p, e, &1, t), t))}
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
        moved = move(org, from, to, e, class, units, t)

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

  @doc """
  Division of `e`'s assets among holders of `class` at `t`, pro rata to holdings
  (*qisma*). Each holder receives the floor of their exact share of every
  divisible asset in kind; indivisible assets and remainders are sold (compelled
  sale), with proceeds shared exactly. Conserves every asset.
  """
  def partition(org, e, class, t) do
    shares = for p <- holders(org, e, class, t), do: {p, Org.holding(org, p, e, class, t)}
    total = Enum.sum(for {_, h} <- shares, do: h)
    assets = org |> Org.nodes(Asset) |> Enum.filter(&(&1.of == e)) |> Enum.sort_by(& &1.id)

    in_kind =
      for %Asset{id: a, quantity: q, divisible: true} <- assets,
          total > 0,
          {p, h} <- shares,
          n <- [div(q * h, total)],
          n > 0,
          do: {p, a, n}

    given = Enum.group_by(in_kind, fn {_, a, _} -> a end, fn {_, _, n} -> n end)

    %Partition{
      allot: Enum.group_by(in_kind, fn {p, _, _} -> p end, fn {_, a, n} -> {a, n} end),
      sell:
        for(
          %Asset{id: a, quantity: q} <- assets,
          r <- [q - Enum.sum(Map.get(given, a, []))],
          r > 0,
          do: {a, r}
        ),
      proceeds: Map.new(shares, fn {p, h} -> {p, reduce(h, total)} end)
    }
  end

  defp reduce(a, b), do: {div(a, Integer.gcd(a, b)), div(b, Integer.gcd(a, b))}

  @doc """
  Dissolve the entity of `body_id` at `t` if the body carries `:dissolve` on
  `votes` (any one holder suffices in a revocable entity): every stake in it is
  closed at `t`, and the `class` partition at `t` is returned.
  """
  def dissolve(org, body_id, votes, class, t) do
    %Body{of: e} = Org.get(org, body_id)

    case Decision.decide(org, body_id, :dissolve, votes, t) do
      {:carried, _} ->
        held =
          for %Stake{in: ^e, holder: h, class: c} <- Org.edges(org, Stake, t),
              uniq: true,
              do: {h, c}

        closed =
          Enum.reduce(held, org, fn {h, c}, acc ->
            move(acc, h, nil, e, c, Org.holding(acc, h, e, c, t), t)
          end)

        {:ok, closed, partition(org, e, class, t)}

      _ ->
        {:error, :not_carried}
    end
  end

  # Move `n` units of `class` in `e` from `from` to `to` (`nil` relinquishes) at `t`.
  # `from`'s current stakes are consumed soonest-expiring first; each is closed at
  # `t`, and its remainder and moved units continue to that stake's own end.
  defp move(org, from, to, e, class, n, t) do
    {current, rest} =
      Enum.split_with(org.edges, fn s ->
        match?(%Stake{holder: ^from, in: ^e, class: ^class}, s) and
          Interval.contains?(s.during, t)
      end)

    {pieces, 0} =
      current
      |> Enum.sort(&expires_first?(&1.during.to, &2.during.to))
      |> Enum.flat_map_reduce(n, fn %Stake{units: u, during: i} = s, left ->
        take = min(left, u)
        later = %{i | from: t}

        {for(
           piece <- [
             (i.from == nil or Date.compare(i.from, t) == :lt) and %{s | during: %{i | to: t}},
             u > take and %{s | units: u - take, during: later},
             to != nil and take > 0 and %{s | holder: to, units: take, during: later}
           ],
           piece,
           do: piece
         ), left - take}
      end)

    %{org | edges: pieces ++ rest}
  end

  defp expires_first?(_, nil), do: true
  defp expires_first?(nil, _), do: false
  defp expires_first?(a, b), do: Date.compare(a, b) != :gt
end
