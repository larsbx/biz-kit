defmodule BarterCore.PooledClearing do
  @moduledoc """
  Exact integer multi-party *routing*, with splittable quantities, multiple
  goods and many-to-many direct handoffs. For each distinct (code, unit), an
  integer max-flow maximizes transferred units of THAT resource only.

  This does not value or compare unlike goods, optimize welfare, create a
  legally effective barter bargain, transfer title or create accounting
  authority. The brokerage must negotiate consideration and reconcile every
  member's actual in-kind obligations before execution.

  A member's projected stock is not validated here: trusted hosts must check
  source authentication, ownership, capacity and reservations separately.
  """

  alias BarterCore, as: B

  @max_number 9_007_199_254_740_991
  @default_budget 30_000_000
  @keys ~w(actor revision valid_until supplies needs)a
  @asset_keys ~w(code unit quantity)a
  @schema "bizkit.barter.pooled-clearing.v1"

  @doc """
  Globally maximize each exact resource's shipped integer quantity under
  supply/demand and no-self-delivery constraints. An actor can simultaneously
  provide and request several commodities and split each asset across peers.

  Costs/limits govern computation only, never an arbitrary party count.
  """
  def optimize(members, now, opts \\ [])

  def optimize(members, now, opts)
      when is_list(members) and is_integer(now) and now >= 0 and is_list(opts) do
    with :ok <- valid_options(opts),
         :ok <- validate(members) do
      active =
        members
        |> Enum.filter(&(&1.valid_until > now))
        |> Enum.sort_by(& &1.actor)

      resources =
        active
        |> Enum.flat_map(fn m -> m.supplies ++ m.needs end)
        |> Enum.map(&{&1.code, &1.unit})
        |> Enum.uniq()
        |> Enum.sort()

      groups = Enum.map(resources, &group(active, &1))

      budget =
        Enum.reduce(groups, 0, fn {_key, supplies, needs}, used ->
          s = length(supplies)
          d = length(needs)
          e = s * d + s + d + 1
          used + (s + d + 2) * e * e
        end)

      if budget > Keyword.get(opts, :work_budget, @default_budget) do
        {:error, :work_budget_exceeded}
      else
        with :ok <- validate_totals(groups) do
          {:ok, plan(active, groups, budget)}
        end
      end
    end
  end

  def optimize(_, _, _), do: {:error, :invalid_members}

  @doc "Recompute a proposed clearing plan from its immutable input snapshot."
  def verify_plan(%{snapshot: snapshot} = candidate, now, opts \\ []) do
    with {:ok, ^candidate} <- optimize(snapshot, now, opts) do
      {:ok, candidate}
    else
      _ -> {:error, :invalid_pooled_plan}
    end
  end

  def verify_plan(_, _, _), do: {:error, :invalid_pooled_plan}

  defp valid_options([]), do: :ok

  defp valid_options([{:work_budget, value}]) when is_integer(value) and value > 0,
    do: :ok

  defp valid_options(_), do: {:error, :invalid_options}

  defp validate(members) do
    cond do
      not Enum.all?(members, &valid_member?/1) ->
        {:error, :invalid_members}

      length(Enum.uniq_by(members, & &1.actor)) != length(members) ->
        {:error, :duplicate_member}

      true ->
        :ok
    end
  end

  defp valid_member?(%{} = m) do
    with true <- Enum.sort(Map.keys(m)) == Enum.sort(@keys),
         true <- B.valid_public_id?(m.actor),
         true <- bounded?(m.revision, 0) and bounded?(m.valid_until, 1),
         true <- is_list(m.supplies) and is_list(m.needs),
         true <- m.supplies != [] or m.needs != [],
         true <- Enum.all?(m.supplies ++ m.needs, &valid_asset?/1),
         true <- unique_assets?(m.supplies) and unique_assets?(m.needs) do
      true
    else
      _ -> false
    end
  end

  defp valid_member?(_), do: false

  defp unique_assets?(assets) do
    keys = Enum.map(assets, &{&1.code, &1.unit})
    length(keys) == length(Enum.uniq(keys))
  end

  defp valid_asset?(%{code: code, unit: unit, quantity: quantity} = a) do
    Enum.sort(Map.keys(a)) == Enum.sort(@asset_keys) and
      token?(code) and token?(unit) and bounded?(quantity, 1)
  end

  defp valid_asset?(_), do: false

  defp token?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: String.match?(value, ~r/\A[a-z0-9][a-z0-9._:-]*\z/)

  defp token?(_), do: false

  defp bounded?(value, minimum),
    do: is_integer(value) and value >= minimum and value <= @max_number

  defp group(members, {code, unit} = key) do
    providers =
      Enum.flat_map(members, fn m ->
        Enum.filter(m.supplies, &({&1.code, &1.unit} == key))
        |> Enum.map(fn a -> {m.actor, a.quantity} end)
      end)

    recipients =
      Enum.flat_map(members, fn m ->
        Enum.filter(m.needs, &({&1.code, &1.unit} == key))
        |> Enum.map(fn a -> {m.actor, a.quantity} end)
      end)

    {{code, unit}, providers, recipients}
  end

  defp validate_totals(groups) do
    if Enum.all?(groups, fn {_, providers, recipients} ->
         Enum.sum(Enum.map(providers, &elem(&1, 1))) <= @max_number and
           Enum.sum(Enum.map(recipients, &elem(&1, 1))) <= @max_number
       end) do
      :ok
    else
      {:error, :quantity_overflow}
    end
  end

  defp plan(snapshot, groups, budget) do
    results = Enum.map(groups, &clear_resource/1)

    transfers =
      results
      |> Enum.flat_map(& &1.transfers)
      |> Enum.sort_by(&{&1.asset.code, &1.asset.unit, &1.from, &1.to})

    unmet =
      results
      |> Enum.flat_map(& &1.unmet)
      |> Enum.sort_by(&{&1.asset.code, &1.asset.unit, &1.actor})

    unallocated =
      results
      |> Enum.flat_map(& &1.unallocated)
      |> Enum.sort_by(&{&1.asset.code, &1.asset.unit, &1.actor})

    fulfilled =
      Enum.map(results, fn result ->
        %{code: result.code, unit: result.unit, quantity: result.fulfilled}
      end)

    participants =
      transfers
      |> Enum.flat_map(&[&1.from, &1.to])
      |> Enum.uniq()
      |> Enum.sort()

    digest_fields =
      [@schema, Integer.to_string(length(snapshot))] ++
        Enum.flat_map(snapshot, &member_fields/1) ++
        [Integer.to_string(length(transfers))] ++
        Enum.flat_map(transfers, fn t ->
          [t.from, t.to, t.asset.code, t.asset.unit, Integer.to_string(t.asset.quantity)]
        end)

    %{
      schema: @schema,
      snapshot: snapshot,
      participants: participants,
      transfers: transfers,
      unmatched_needs: unmet,
      unallocated_supplies: unallocated,
      fulfilled_by_asset: fulfilled,
      optimization: :max_units_independently_per_exact_resource,
      optimality: :exact_integer_max_flow_per_resource,
      estimated_work: budget,
      terms_hash: B.digest(digest_fields)
    }
  end

  defp member_fields(member) do
    supplies = Enum.sort_by(member.supplies, &{&1.code, &1.unit})
    needs = Enum.sort_by(member.needs, &{&1.code, &1.unit})

    [
      member.actor,
      Integer.to_string(member.revision),
      Integer.to_string(member.valid_until),
      Integer.to_string(length(supplies))
    ] ++
      Enum.flat_map(supplies, &asset_fields/1) ++
      [Integer.to_string(length(needs))] ++
      Enum.flat_map(needs, &asset_fields/1)
  end

  defp asset_fields(a), do: [a.code, a.unit, Integer.to_string(a.quantity)]

  defp clear_resource({{code, unit}, providers, recipients}) do
    graph =
      Enum.reduce(providers, new_graph(), fn {actor, qty}, g ->
        add_edge(g, :source, {:supply, actor}, qty)
      end)

    graph =
      Enum.reduce(recipients, graph, fn {actor, qty}, g ->
        add_edge(g, {:need, actor}, :sink, qty)
      end)

    graph =
      Enum.reduce(providers, graph, fn {source, stock}, graph ->
        Enum.reduce(recipients, graph, fn {destination, demand}, g ->
          if source == destination do
            g
          else
            add_edge(g, {:supply, source}, {:need, destination}, min(stock, demand))
          end
        end)
      end)

    cleared = augment_all(graph)

    transfers =
      for {source, _stock} <- providers,
          {destination, demand} <- recipients,
          source != destination,
          used = demand_used(graph, cleared, source, destination),
          used > 0 do
        %{
          from: source,
          to: destination,
          asset: %{code: code, unit: unit, quantity: used}
        }
      end

    supplied = Enum.group_by(transfers, & &1.from)
    received = Enum.group_by(transfers, & &1.to)

    unallocated =
      for {actor, quantity} <- providers,
          left = quantity - Enum.sum(Enum.map(Map.get(supplied, actor, []), & &1.asset.quantity)),
          left > 0 do
        %{actor: actor, asset: %{code: code, unit: unit, quantity: left}}
      end

    unmet =
      for {actor, quantity} <- recipients,
          left = quantity - Enum.sum(Enum.map(Map.get(received, actor, []), & &1.asset.quantity)),
          left > 0 do
        %{actor: actor, asset: %{code: code, unit: unit, quantity: left}}
      end

    %{
      code: code,
      unit: unit,
      fulfilled: Enum.sum(Enum.map(transfers, & &1.asset.quantity)),
      transfers: transfers,
      unmet: unmet,
      unallocated: unallocated
    }
  end

  defp demand_used(_original, cleared, source, destination) do
    backward = {{:need, destination}, {:supply, source}}
    Map.get(cleared.residual, backward, 0)
  end

  defp new_graph, do: %{residual: %{}, adjacent: %{}}

  defp add_edge(g, source, target, capacity) do
    residual =
      g.residual
      |> Map.put({source, target}, capacity)
      |> Map.put({target, source}, 0)

    neighbors =
      g.adjacent
      |> Map.update(source, MapSet.new([target]), &MapSet.put(&1, target))
      |> Map.update(target, MapSet.new([source]), &MapSet.put(&1, source))

    %{residual: residual, adjacent: neighbors}
  end

  defp augment_all(graph) do
    case path(graph) do
      nil ->
        graph

      edges ->
        delta =
          edges
          |> Enum.map(&Map.fetch!(graph.residual, &1))
          |> Enum.min()

        residual =
          Enum.reduce(edges, graph.residual, fn {a, b}, r ->
            r
            |> Map.update!({a, b}, &(&1 - delta))
            |> Map.update!({b, a}, &(&1 + delta))
          end)

        augment_all(%{graph | residual: residual})
    end
  end

  defp path(graph) do
    breadth_first(:queue.in(:source, :queue.new()), MapSet.new([:source]), %{}, graph)
  end

  defp breadth_first(queue, seen, parent, graph) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, :sink}, _} ->
        traceback(parent, :sink, [])

      {{:value, node}, remaining} ->
        {queue, seen, parent} =
          graph.adjacent
          |> Map.get(node, MapSet.new())
          |> Enum.sort()
          |> Enum.reduce({remaining, seen, parent}, fn neighbor, {q, visited, previous} ->
            capacity = Map.get(graph.residual, {node, neighbor}, 0)

            if capacity > 0 and not MapSet.member?(visited, neighbor) do
              {
                :queue.in(neighbor, q),
                MapSet.put(visited, neighbor),
                Map.put(previous, neighbor, node)
              }
            else
              {q, visited, previous}
            end
          end)

        breadth_first(queue, seen, parent, graph)
    end
  end

  defp traceback(_parent, :source, acc), do: acc

  defp traceback(parent, current, acc) do
    previous = Map.fetch!(parent, current)
    traceback(parent, previous, [{previous, current} | acc])
  end
end
