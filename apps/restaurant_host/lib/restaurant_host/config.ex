defmodule RestaurantHost.Config do
  @moduledoc """
  A restaurant's production configuration. The restaurant file (JSON) names
  the Log chapter, merchant, currency, tax jurisdiction, menu and devices; each
  device's 32-byte signing seed comes only from the environment, as base64 in
  `RESTAURANT_DEVICE_SEED_<DEVICE_ID>` (upper-cased, non-alphanumerics as `_`),
  so the file can be reviewed and versioned without holding a secret. A board's
  pairing secret is stored only as its SHA-256 (hex).

  `RestaurantHost.Application` loads it at boot and refuses to start on any
  error, so a bad configuration fails the deploy, not a guest's order.

      {
        "chapter": "chapter-genesis", "merchant": "shop",
        "currency": "USD", "jurisdiction": "US-MI",
        "menu": [{"id": "margherita", "name": "Margherita", "sku": "MARG", "price_minor": 1250}],
        "storefront": {"device_id": "storefront", "key_id": "k-store"},
        "boards": {"board-1": {"device_id": "board-1", "key_id": "k-board", "pairing_sha256": "…"}}
      }
  """

  @top ~w(chapter merchant currency jurisdiction menu storefront boards delivery_enabled delivery_site)
  @device ~w(device_id key_id)

  @doc "Read the restaurant file at `path` with seeds from `env`."
  def load(path, env \\ System.get_env()) do
    case File.read(path) do
      {:ok, json} -> parse(json, env)
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  @doc "The configuration `RestaurantHost.Restaurant.build/1` takes, or why not."
  def parse(json, env) when is_binary(json) and is_map(env) do
    with {:ok, doc} <- decode(json),
         :ok <- only(doc, @top, "restaurant"),
         {:ok, chapter} <- segment(doc, "chapter"),
         {:ok, merchant} <- segment(doc, "merchant"),
         {:ok, currency} <- currency(doc["currency"]),
         {:ok, jurisdiction} <- jurisdiction(doc["jurisdiction"]),
         {:ok, menu} <- menu(doc["menu"]),
         delivery_enabled = Map.get(doc, "delivery_enabled", false),
         true <- is_boolean(delivery_enabled) or invalid("delivery_enabled"),
         site = doc["delivery_site"],
         true <- valid_site?(delivery_enabled, site) or invalid("delivery_site"),
         {:ok, storefront} <- device("storefront", doc["storefront"], env, false),
         {:ok, boards} <- boards(doc["boards"], env),
         :ok <- distinct_devices(storefront, boards) do
      {:ok,
       %{
         chapter: chapter,
         merchant: merchant,
         currency: currency,
         jurisdiction: jurisdiction,
         menu: menu,
         delivery_enabled: delivery_enabled,
         delivery_site: site,
         storefront: storefront,
         boards: boards
       }}
    end
  end

  defp valid_site?(false, nil), do: true

  defp valid_site?(_, site),
    do: is_binary(site) and byte_size(site) in 1..120 and String.trim(site) != ""

  defp decode(json) do
    case :json.decode(json) do
      %{} = doc -> {:ok, doc}
      _ -> {:error, :invalid_json}
    end
  rescue
    _ -> {:error, :invalid_json}
  end

  defp only(map, allowed, name) do
    case Map.keys(map) -- allowed do
      [] -> :ok
      [extra | _] -> {:error, {:unexpected_field, name, extra}}
    end
  end

  defp segment(doc, field) do
    case doc[field] do
      v when is_binary(v) ->
        if RestaurantHost.DeviceGrants.identifier?(v), do: {:ok, v}, else: invalid(field)

      _ ->
        {:error, {:invalid, field}}
    end
  end

  defp currency(code) when is_binary(code) do
    with true <- Regex.match?(~r/\A[A-Z]{3}\z/, code),
         {:ok, currency} <- Money.validate_currency(code) do
      {:ok, currency}
    else
      _ -> {:error, {:invalid, "currency"}}
    end
  end

  defp currency(_), do: {:error, {:invalid, "currency"}}

  # A jurisdiction with a known tax profile (`CommerceCore.Tax.Jurisdictions`),
  # never a free-form rate: the rules behind a rate are part of the profile.
  defp jurisdiction(code) when is_binary(code) do
    case CommerceCore.Tax.Jurisdictions.profile(code) do
      {:ok, _} -> {:ok, code}
      {:error, _} -> invalid("jurisdiction")
    end
  end

  defp jurisdiction(_), do: invalid("jurisdiction")

  defp menu([_ | _] = items) do
    if Enum.all?(items, &item?/1),
      do:
        {:ok,
         for(
           i <- items,
           do: %{id: i["id"], name: i["name"], sku: i["sku"], price_minor: i["price_minor"]}
         )},
      else: invalid("menu")
  end

  defp menu(_), do: invalid("menu")

  defp item?(%{"id" => id, "name" => name, "sku" => sku, "price_minor" => p} = i)
       when is_binary(id) and is_binary(name) and is_binary(sku) and is_integer(p) and p >= 0,
       do: map_size(i) == 4 and id != "" and name != "" and sku != ""

  defp item?(_), do: false

  defp boards(%{} = boards, env) do
    Enum.reduce_while(boards, {:ok, %{}}, fn {id, spec}, {:ok, acc} ->
      case device(id, spec, env, true) do
        {:ok, device} -> {:cont, {:ok, Map.put(acc, id, device)}}
        error -> {:halt, error}
      end
    end)
  end

  defp boards(nil, _), do: {:ok, %{}}
  defp boards(_, _), do: invalid("boards")

  defp device(name, %{} = spec, env, board?) do
    allowed = if board?, do: ["pairing_sha256" | @device], else: @device

    with :ok <- only(spec, allowed, name),
         true <-
           Enum.all?(
             [name | Enum.map(@device, &spec[&1])],
             &RestaurantHost.DeviceGrants.identifier?/1
           ) or
             invalid(field(board?, name)),
         {:ok, pairing} <- pairing(spec, board?, name),
         {:ok, seed} <- seed(spec["device_id"], env) do
      device = %{device_id: spec["device_id"], key_id: spec["key_id"], seed: seed}
      {:ok, if(board?, do: Map.put(device, :pairing_sha256, pairing), else: device)}
    end
  end

  defp device(name, _, _, board?), do: invalid(field(board?, name))

  defp field(true, _), do: "boards"
  defp field(false, name), do: name

  defp pairing(_spec, false, _), do: {:ok, nil}

  defp pairing(%{"pairing_sha256" => hex}, true, _) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::256>> = hash} -> {:ok, hash}
      _ -> invalid("boards")
    end
  end

  defp pairing(_, true, _), do: invalid("boards")

  @doc "The environment variable holding a device's seed."
  def seed_var(device_id),
    do:
      "RESTAURANT_DEVICE_SEED_" <>
        (device_id |> String.upcase() |> String.replace(~r/[^A-Z0-9]/, "_"))

  defp seed(device_id, env) do
    var = seed_var(device_id)

    case Map.fetch(env, var) do
      :error ->
        {:error, {:missing_seed, var}}

      {:ok, b64} ->
        with {:ok, <<_::256>> = seed} <- Base.decode64(b64),
             do: {:ok, seed},
             else: (_ -> {:error, {:invalid_seed, var}})
    end
  end

  defp distinct_devices(storefront, boards) do
    devices = [storefront | Map.values(boards)]
    unique? = fn values -> length(values) == length(Enum.uniq(values)) end

    if unique?.(Enum.map(devices, & &1.device_id)) and
         unique?.(Enum.map(devices, & &1.key_id)) and
         unique?.(Enum.map(devices, &seed_var(&1.device_id))) and
         unique?.(Enum.map(devices, & &1.seed)),
       do: :ok,
       else: {:error, :ambiguous_devices}
  end

  defp invalid(field), do: {:error, {:invalid, field}}
end
