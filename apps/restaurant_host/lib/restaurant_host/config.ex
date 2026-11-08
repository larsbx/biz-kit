defmodule RestaurantHost.Config do
  @moduledoc """
  A restaurant's production configuration. The restaurant file (JSON) names
  the Log chapter, merchant, currency, tax rate, menu and devices; each
  device's 32-byte signing seed comes only from the environment, as base64 in
  `RESTAURANT_DEVICE_SEED_<DEVICE_ID>` (upper-cased, non-alphanumerics as `_`),
  so the file can be reviewed and versioned without holding a secret. A board's
  pairing secret is stored only as its SHA-256 (hex).

  `RestaurantHost.Application` loads it at boot and refuses to start on any
  error, so a bad configuration fails the deploy, not a guest's order.

  A menu item may list `discounts` (`CommerceCore.Discounts`), each with an
  `id`, a `method` and its fields — `percent_off` `rate` (a decimal string),
  `unit_price` `price_minor`, `buy_x_pay_y` `x` and `y`, `x_for_amount` `x`
  and `amount_minor` — and optional `enabled`, `weekdays` (ISO, 1 = Monday),
  `hours` (`[from, to]`, inclusive, wrapping past midnight) and
  `min_quantity`. `timezone` (IANA, default `Etc/UTC`) is the local time those
  conditions read.

      {
        "chapter": "chapter-genesis", "merchant": "shop",
        "currency": "USD", "tax_rate": "0.0825",
        "menu": [{"id": "margherita", "name": "Margherita", "sku": "MARG", "price_minor": 1250}],
        "storefront": {"device_id": "storefront", "key_id": "k-store"},
        "boards": {"board-1": {"device_id": "board-1", "key_id": "k-board", "pairing_sha256": "…"}}
      }
  """

  @top ~w(chapter merchant currency tax_rate timezone menu storefront boards)
  @item ~w(id name sku price_minor)
  @rule_conditions ~w(id method enabled weekdays hours min_quantity)
  @rule_fields %{
    "percent_off" => ~w(rate),
    "unit_price" => ~w(price_minor),
    "buy_x_pay_y" => ~w(x y),
    "x_for_amount" => ~w(x amount_minor)
  }
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
         {:ok, tax_rate} <- tax_rate(doc["tax_rate"]),
         {:ok, timezone} <- timezone(Map.get(doc, "timezone", "Etc/UTC")),
         {:ok, menu} <- menu(doc["menu"], currency),
         {:ok, storefront} <- device("storefront", doc["storefront"], env, false),
         {:ok, boards} <- boards(doc["boards"], env),
         :ok <- distinct_devices(storefront, boards) do
      {:ok,
       %{
         chapter: chapter,
         merchant: merchant,
         currency: currency,
         tax_rate: tax_rate,
         timezone: timezone,
         menu: menu,
         storefront: storefront,
         boards: boards
       }}
    end
  end

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

  defp tax_rate(rate) when is_binary(rate) do
    case Decimal.parse(rate) do
      {d, ""} ->
        if Decimal.compare(d, 0) != :lt and Decimal.compare(d, 1) == :lt,
          do: {:ok, rate},
          else: invalid("tax_rate")

      _ ->
        invalid("tax_rate")
    end
  end

  defp tax_rate(_), do: invalid("tax_rate")

  defp timezone(tz) when is_binary(tz) do
    case DateTime.now(tz, Tz.TimeZoneDatabase) do
      {:ok, _} -> {:ok, tz}
      _ -> invalid("timezone")
    end
  end

  defp timezone(_), do: invalid("timezone")

  defp menu([_ | _] = items, currency) do
    parsed = Enum.map(items, &item(&1, currency))

    if Enum.all?(parsed, &match?({:ok, _}, &1)),
      do: {:ok, Enum.map(parsed, &elem(&1, 1))},
      else: invalid("menu")
  end

  defp menu(_, _), do: invalid("menu")

  defp item(%{"id" => id, "name" => name, "sku" => sku, "price_minor" => p} = i, currency)
       when is_binary(id) and is_binary(name) and is_binary(sku) and is_integer(p) and p >= 0 do
    with :ok <- only(i, ["discounts" | @item], "menu"),
         true <- id != "" and name != "" and sku != "",
         {:ok, discounts} <- discounts(Map.get(i, "discounts", []), currency) do
      {:ok, %{id: id, name: name, sku: sku, price_minor: p, discounts: discounts}}
    else
      _ -> :error
    end
  end

  defp item(_, _), do: :error

  # Each rule as `CommerceCore.Discounts` takes it, amounts in the menu's
  # currency; the catalog validates the whole list again when it is put.
  defp discounts(rules, currency) when is_list(rules) do
    parsed = Enum.map(rules, &rule(&1, currency))
    ids = Enum.map(rules, &(is_map(&1) && &1["id"]))

    with true <- Enum.all?(parsed, &match?({:ok, _}, &1)),
         true <- Enum.uniq(ids) == ids do
      {:ok, Enum.map(parsed, &elem(&1, 1))}
    else
      _ -> :error
    end
  end

  defp discounts(_, _), do: :error

  defp rule(%{"method" => method} = r, currency) when is_map_key(@rule_fields, method) do
    with :ok <- only(r, @rule_conditions ++ @rule_fields[method], "discount"),
         {:ok, attrs} <- rule_attrs(r, currency) do
      CommerceCore.Discounts.normalize(attrs)
    else
      _ -> :error
    end
  end

  defp rule(_, _), do: :error

  defp rule_attrs(r, currency) do
    money = &Money.from_integer(&1, currency)

    fields =
      Enum.flat_map(r, fn
        {"id", v} -> [id: v]
        {"method", v} -> [method: String.to_existing_atom(v)]
        {"enabled", v} -> [enabled: v]
        {"weekdays", v} -> [weekdays: v]
        {"hours", [from, to]} -> [hours: {from, to}]
        {"hours", _} -> [hours: :invalid]
        {"min_quantity", v} -> [min_quantity: v]
        {"rate", v} when is_binary(v) -> [rate: decimal(v)]
        {"rate", _} -> [rate: :invalid]
        {"price_minor", v} when is_integer(v) -> [price: money.(v)]
        {"amount_minor", v} when is_integer(v) -> [amount: money.(v)]
        {k, v} when k in ~w(x y) -> [{String.to_existing_atom(k), v}]
        _ -> [invalid: true]
      end)

    if Keyword.has_key?(fields, :invalid), do: :error, else: {:ok, Map.new(fields)}
  end

  defp decimal(v) do
    case Decimal.parse(v) do
      {d, ""} -> d
      _ -> :invalid
    end
  end

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
