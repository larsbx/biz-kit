defmodule BarterCore do
  @moduledoc """
  Exact, pure barter clearing primitives. The optimized matcher treats each
  published intent as one indivisible supply/need slot; a business may post
  multiple slots. A matching is not a signed contract, a business ledger write,
  stock reservation, legal company formation or delivery.
  """

  @max_number 9_007_199_254_740_991
  @intent_keys ~w(id owner revision valid_until provides needs)a
  @asset_keys ~w(code unit quantity)a

  @doc """
  Globally optimize the number of fulfilled active intents for the declared
  indivisible-slot model using a polynomial-time assignment solver.

  There is no cycle-length or participant-count limit. Work is controlled by
  an explicit computation budget, not a four-party topology restriction.
  Units and different goods are never silently converted or valued.
  """
  def optimize(intents, now, opts \\ []) do
    BarterCore.Optimizer.optimize(intents, now, opts)
  end

  @doc "Get every selected disjoint cycle in the optimized clearing plan."
  def routes(intents, now, opts \\ []) do
    with {:ok, plan} <- optimize(intents, now, opts), do: {:ok, plan.cycles}
  end

  @doc "Validate a route independently of a possibly different market snapshot."
  def verify_route(%{intents: intents} = candidate, now)
      when is_list(intents) and is_integer(now) and now >= 0 do
    with :ok <- validate_feed(intents),
         true <- length(intents) >= 2,
         true <- Enum.all?(intents, &(&1.valid_until > now)),
         true <- hd(intents).id == Enum.min(Enum.map(intents, & &1.id)),
         true <- compatible_cycle?(intents),
         ^candidate <- cycle(intents) do
      {:ok, candidate}
    else
      _ -> {:error, :invalid_route}
    end
  end

  def verify_route(_, _), do: {:error, :invalid_route}

  @doc "Recompute an optimal plan from its bound discovery snapshot."
  def verify_plan(%{intents: intents} = candidate, now, opts \\ []) do
    with {:ok, ^candidate} <- optimize(intents, now, opts) do
      {:ok, candidate}
    else
      _ -> {:error, :invalid_plan}
    end
  end

  @doc false
  def validate_feed(intents) when is_list(intents) do
    cond do
      not Enum.all?(intents, &valid_intent?/1) ->
        {:error, :invalid_intents}

      length(Enum.uniq_by(intents, & &1.id)) != length(intents) ->
        {:error, :duplicate_intent}

      true ->
        :ok
    end
  end

  def validate_feed(_), do: {:error, :invalid_intents}

  @doc false
  def valid_public_id?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        path: path,
        query: nil,
        fragment: nil,
        userinfo: nil,
        port: port
      }
      when is_binary(host) and is_binary(path) and path != "" and port in [nil, 443] ->
        name = String.downcase(host)

        String.contains?(name, ".") and
          Regex.match?(~r/\A[a-z0-9.-]+\z/, name) and
          not String.contains?(name, "..") and
          not String.ends_with?(name, ".local") and
          not String.ends_with?(name, ".internal") and
          match?({:error, _}, :inet.parse_address(String.to_charlist(name)))

      _ ->
        false
    end
  end

  def valid_public_id?(_), do: false

  @doc false
  def compatible?(from, to) do
    from.owner != to.owner and
      from.provides.code == to.needs.code and
      from.provides.unit == to.needs.unit and
      from.provides.quantity >= to.needs.quantity
  end

  @doc false
  def compatible_cycle?(intents) when length(intents) >= 2 do
    Enum.zip(intents, tl(intents) ++ [hd(intents)])
    |> Enum.all?(fn {from, to} -> compatible?(from, to) end)
  end

  def compatible_cycle?(_), do: false

  @doc false
  def cycle(intents) when length(intents) >= 2 do
    legs =
      Enum.zip(intents, tl(intents) ++ [hd(intents)])
      |> Enum.map(fn {from, to} ->
        %{
          from: from.owner,
          to: to.owner,
          from_intent: from.id,
          to_intent: to.id,
          asset: %{
            code: from.provides.code,
            unit: from.provides.unit,
            quantity: to.needs.quantity
          }
        }
      end)

    %{
      schema: "bizkit.barter.route.v2",
      intents: intents,
      participants: Enum.uniq(Enum.map(intents, & &1.owner)),
      legs: legs,
      valid_until: Enum.min(Enum.map(intents, & &1.valid_until)),
      terms_hash: digest(
        ["bizkit.barter.route.v2", Integer.to_string(length(intents))] ++
          Enum.flat_map(intents, &intent_fields/1) ++ Enum.flat_map(legs, &leg_fields/1)
      )
    }
  end

  @doc false
  def intent_fields(i) do
    [
      i.id,
      i.owner,
      Integer.to_string(i.revision),
      Integer.to_string(i.valid_until),
      i.provides.code,
      i.provides.unit,
      Integer.to_string(i.provides.quantity),
      i.needs.code,
      i.needs.unit,
      Integer.to_string(i.needs.quantity)
    ]
  end

  @doc false
  def leg_fields(l) do
    [
      l.from,
      l.to,
      l.from_intent,
      l.to_intent,
      l.asset.code,
      l.asset.unit,
      Integer.to_string(l.asset.quantity)
    ]
  end

  @doc false
  def digest(fields) do
    payload = Enum.map_join(fields, "", fn value -> "#{byte_size(value)}:#{value}" end)
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  defp valid_intent?(%{} = intent) do
    with true <- exact_keys?(intent, @intent_keys),
         %{
           id: id,
           owner: owner,
           revision: revision,
           valid_until: expires,
           provides: provides,
           needs: needs
         } <- intent,
         true <- valid_public_id?(id) and valid_public_id?(owner),
         true <- String.downcase(URI.parse(id).host) == String.downcase(URI.parse(owner).host),
         true <- bounded?(revision, 0) and bounded?(expires, 1),
         true <- valid_asset?(provides) and valid_asset?(needs) do
      true
    else
      _ -> false
    end
  end

  defp valid_intent?(_), do: false

  defp valid_asset?(%{code: code, unit: unit, quantity: quantity} = asset) do
    exact_keys?(asset, @asset_keys) and
      token?(code) and token?(unit) and bounded?(quantity, 1)
  end

  defp valid_asset?(_), do: false

  defp token?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: String.match?(value, ~r/\A[a-z0-9][a-z0-9._:-]*\z/)

  defp token?(_), do: false

  defp bounded?(value, min),
    do: is_integer(value) and value >= min and value <= @max_number

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
end
