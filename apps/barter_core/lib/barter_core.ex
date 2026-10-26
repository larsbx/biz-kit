defmodule BarterCore do
  @moduledoc """
  Pure, bounded barter route *candidates*. Never reserves stock, accepts
  contracts, posts accounting entries, delivers assets or spends balances.

  Intents come from a trusted host's authenticated, consented projections;
  a caller-supplied owner URL is NOT proof of that ownership. Quantities and
  units are exact; no price, currency conversion or market value is inferred.
  """

  @max_intents 16
  @max_routes 100
  @max_number 9_007_199_254_740_991
  @intent_keys ~w(id owner revision valid_until provides needs)a
  @asset_keys ~w(code unit quantity)a

  @doc """
  Find two-to-four-party closed exchange routes, deterministically.

  Each leg moves an asset **directly** from its original provider to the
  next party. A route has no network-owned inventory or intermediary title.
  Search is bounded and returns at most 100 sorted candidates; it does not
  promise globally optimal, exclusive, fair, or complete allocations.
  Expired (but structurally valid) advertisements are ignored.
  """
  def routes(intents, now, max_parties \\ 4)

  def routes(intents, now, max_parties)
      when is_list(intents) and is_integer(now) and now >= 0 and
             is_integer(max_parties) and max_parties in 2..4 do
    with :ok <- validate_feed(intents) do
      active =
        intents
        |> Enum.filter(&(&1.valid_until > now))
        |> Enum.sort_by(& &1.id)

      plans =
        active
        |> Enum.flat_map(fn first -> extend([first], active, max_parties) end)
        |> Enum.sort_by(fn route ->
          {length(route.participants), Enum.map(route.intents, & &1.id)}
        end)
        |> Enum.take(@max_routes)

      {:ok, plans}
    end
  end

  def routes(_, _, _), do: {:error, :invalid_intents}

  @doc """
  Reconstruct a candidate, including its canonical digest, before using it
  to preview conditional accounting. This is NOT cryptographic consent
  verification or a local ledger admission.
  """
  def verify_route(%{intents: intents} = candidate, now)
      when is_list(intents) and length(intents) in 2..4 do
    case routes(intents, now, length(intents)) do
      {:ok, routes} ->
        if Enum.member?(routes, candidate),
          do: {:ok, candidate},
          else: {:error, :invalid_route}

      _ ->
        {:error, :invalid_route}
    end
  end

  def verify_route(_, _), do: {:error, :invalid_route}

  defp validate_feed(intents) do
    cond do
      length(intents) > @max_intents ->
        {:error, :too_many_intents}

      not Enum.all?(intents, &valid_intent?/1) ->
        {:error, :invalid_intents}

      length(Enum.uniq_by(intents, & &1.id)) != length(intents) ->
        {:error, :duplicate_intent}

      true ->
        :ok
    end
  end

  defp valid_intent?(%{} = intent) do
    with true <- exact_keys?(intent, @intent_keys),
         %{id: id, owner: owner, revision: revision, valid_until: expires,
           provides: provides, needs: needs} <- intent,
         true <- valid_url?(id) and valid_url?(owner),
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

  # Canonical codes and units are opaque identifiers, not mutable display
  # labels or implicit equivalences ("kg" is NOT silently converted to "g").
  defp token?(value) when is_binary(value) and byte_size(value) in 1..64,
    do: String.match?(value, ~r/\A[a-z0-9][a-z0-9._:-]*\z/)

  defp token?(_), do: false

  defp bounded?(value, min),
    do: is_integer(value) and value >= min and value <= @max_number

  defp exact_keys?(map, keys), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)

  # Shape validation only. A federation service must separately authenticate,
  # authorize publication, enforce SSRF-safe fetches and bind actor/key origin.
  defp valid_url?(value) when is_binary(value) and byte_size(value) <= 2048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path, query: nil,
           fragment: nil, userinfo: nil, port: port}
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

  defp valid_url?(_), do: false

  defp compatible?(from, to) do
    from.provides.code == to.needs.code and
      from.provides.unit == to.needs.unit and
      from.provides.quantity >= to.needs.quantity
  end

  # Only the lexicographically smallest intent may start its cycle. Distinct
  # owners are required even if the owner posts multiple different intents.
  defp extend(path, sorted, max_parties) do
    first = hd(path)
    last = List.last(path)

    closed =
      if length(path) >= 2 and compatible?(last, first),
        do: [build_route(path)],
        else: []

    next =
      if length(path) < max_parties do
        sorted
        |> Enum.filter(fn intent ->
          intent.id > first.id and
            not Enum.any?(path, fn present ->
              present.id == intent.id or present.owner == intent.owner
            end) and
            compatible?(last, intent)
        end)
        |> Enum.flat_map(fn intent -> extend(path ++ [intent], sorted, max_parties) end)
      else
        []
      end

    closed ++ next
  end

  defp build_route(intents) do
    legs =
      Enum.zip(intents, tl(intents) ++ [hd(intents)])
      |> Enum.map(fn {from, to} ->
        %{
          from: from.owner,
          to: to.owner,
          from_intent: from.id,
          to_intent: to.id,
          asset: %{code: from.provides.code, unit: from.provides.unit,
                   quantity: to.needs.quantity}
        }
      end)

    %{
      schema: "bizkit.barter.route.v1",
      intents: intents,
      participants: Enum.map(intents, & &1.owner),
      legs: legs,
      valid_until: Enum.min(Enum.map(intents, & &1.valid_until)),
      terms_hash: digest(intents, legs)
    }
  end

  # Length-prefix each UTF-8 field; there are no ambiguous separators.
  # This is stable across Elixir processes, unlike term_to_binary/1.
  # Wire adapters MUST preserve these exact identifiers and field ordering.
  defp digest(intents, legs) do
    fields =
      ["bizkit.barter.route.v1", Integer.to_string(length(intents))] ++
        Enum.flat_map(intents, fn i ->
          [i.id, i.owner, Integer.to_string(i.revision),
           Integer.to_string(i.valid_until), i.provides.code, i.provides.unit,
           Integer.to_string(i.provides.quantity), i.needs.code, i.needs.unit,
           Integer.to_string(i.needs.quantity)]
        end) ++
        Enum.flat_map(legs, fn l ->
          [l.from, l.to, l.from_intent, l.to_intent, l.asset.code,
           l.asset.unit, Integer.to_string(l.asset.quantity)]
        end)

    encoded = Enum.map_join(fields, "", fn field -> "#{byte_size(field)}:#{field}" end)
    :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
  end
end
