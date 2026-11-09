defmodule RestaurantCore.Menu do
  @moduledoc """
  A merchant's menu as signed facts, money-free (Eatsbot decommission D6).

  Each `RestaurantMenuItemPutV1` adds or replaces one item at the menu's
  expected version, so concurrent editors cannot overwrite each other unseen.
  Amounts are integer minor units and a discount rate is a decimal string, so
  this layer, like the substrate that admits it, never loads the money stack.

  It refuses exactly what the host's catalog would refuse
  (`CommerceCore.Catalog.put/4` with `CommerceCore.Discounts.normalize/1`):
  identifiers, a positive price, unique SKUs and rule ids, and the rule
  grammar. An admitted edit therefore always applies to the storefront.

  Rule wire format, shared with the restaurant file: `id`, `method` and its
  fields — `percent_off` `rate` (`"0.15"`, at most six decimals, in (0, 1]),
  `unit_price` `price_minor` (≥ 0), `buy_x_pay_y` `x` > `y` ≥ 1,
  `x_for_amount` `x` ≥ 2 and `amount_minor` > 0 — and optional `enabled`,
  `weekdays` (ISO, 1 = Monday), `hours` (`[from, to]`, 0–23) and
  `min_quantity` (≥ 1).
  """

  @item ~w(item_id name sku price_minor currency visibility discounts)
  @visibility %{"published" => :published, "hidden" => :hidden}
  @conditions ~w(id method enabled weekdays hours min_quantity)
  @methods %{
    "percent_off" => {:percent_off, ~w(rate)},
    "unit_price" => {:unit_price, ~w(price_minor)},
    "buy_x_pay_y" => {:buy_x_pay_y, ~w(x y)},
    "x_for_amount" => {:x_for_amount, ~w(x amount_minor)}
  }

  @doc "An empty menu."
  def new, do: %{version: 0, items: %{}}

  @doc "Add or replace one item at the expected menu version."
  def put(%{version: version, items: items}, expected, item) do
    others = items |> Map.delete(item.id) |> Map.values()

    cond do
      expected != version -> {:error, :stale_menu_version}
      Enum.any?(others, &(&1.sku == item.sku)) -> {:error, :duplicate_sku}
      true -> {:ok, %{version: version + 1, items: Map.put(items, item.id, item)}}
    end
  end

  @doc "A menu item from its signed payload fields."
  def decode_item(%{"discounts" => rules} = p) when is_list(rules) do
    with true <- Enum.sort(Map.keys(p)) == Enum.sort(@item),
         true <- id?(p["item_id"]) and text?(p["name"]) and text?(p["sku"]),
         true <- is_integer(p["price_minor"]) and p["price_minor"] > 0,
         true <- is_binary(p["currency"]) and Regex.match?(~r/\A[A-Z]{3}\z/, p["currency"]),
         {:ok, visibility} <- Map.fetch(@visibility, p["visibility"]),
         {:ok, discounts} <- decode_rules(rules) do
      {:ok,
       %{
         id: p["item_id"],
         name: p["name"],
         sku: p["sku"],
         price_minor: p["price_minor"],
         currency: p["currency"],
         visibility: visibility,
         discounts: discounts
       }}
    else
      _ -> {:error, :invalid_menu_item}
    end
  end

  def decode_item(_), do: {:error, :invalid_menu_item}

  @doc "An item back in its wire form: `decode_item(encode_item(i)) == {:ok, i}`."
  def encode_item(item),
    do: %{
      "item_id" => item.id,
      "name" => item.name,
      "sku" => item.sku,
      "price_minor" => item.price_minor,
      "currency" => item.currency,
      "visibility" => Atom.to_string(item.visibility),
      "discounts" => Enum.map(item.discounts, &encode_rule/1)
    }

  defp encode_rule(rule) do
    Map.new(rule, fn
      {:method, m} -> {"method", Atom.to_string(m)}
      {:hours, {from, to}} -> {"hours", [from, to]}
      {k, v} -> {Atom.to_string(k), v}
    end)
    |> Map.reject(fn {k, v} -> k in ~w(weekdays hours) and v == :any end)
  end

  @doc "A list of discount rules with distinct ids."
  def decode_rules(rules) when is_list(rules) do
    decoded = Enum.map(rules, &decode_rule/1)

    if Enum.all?(decoded, &match?({:ok, _}, &1)) and distinct?(Enum.map(rules, & &1["id"])),
      do: {:ok, Enum.map(decoded, &elem(&1, 1))},
      else: {:error, :invalid_discount}
  end

  def decode_rules(_), do: {:error, :invalid_discount}

  @doc "One discount rule from its wire form."
  def decode_rule(%{"id" => id, "method" => name} = r) when is_map_key(@methods, name) do
    {method, fields} = @methods[name]

    with true <- id?(id),
         true <- Enum.all?(Map.keys(r), &(&1 in @conditions or &1 in fields)),
         true <- Enum.all?(fields, &Map.has_key?(r, &1)),
         {:ok, conditions} <- conditions(r),
         true <- method?(method, r) do
      {:ok, Map.merge(conditions, %{id: id, method: method}) |> Map.merge(fields(r, fields))}
    else
      _ -> {:error, :invalid_discount}
    end
  end

  def decode_rule(_), do: {:error, :invalid_discount}

  @atoms %{
    "rate" => :rate,
    "price_minor" => :price_minor,
    "x" => :x,
    "y" => :y,
    "amount_minor" => :amount_minor
  }
  defp fields(r, fields), do: Map.new(fields, &{@atoms[&1], r[&1]})

  defp method?(:percent_off, %{"rate" => rate}),
    do:
      is_binary(rate) and Regex.match?(~r/\A(0\.\d{1,6}|1(\.0{1,6})?)\z/, rate) and
        Regex.match?(~r/[1-9]/, rate)

  defp method?(:unit_price, %{"price_minor" => p}), do: is_integer(p) and p >= 0

  defp method?(:buy_x_pay_y, %{"x" => x, "y" => y}),
    do: is_integer(x) and is_integer(y) and 1 <= y and y < x

  defp method?(:x_for_amount, %{"x" => x, "amount_minor" => a}),
    do: is_integer(x) and x >= 2 and is_integer(a) and a > 0

  defp conditions(r) do
    enabled = Map.get(r, "enabled", true)
    weekdays = Map.get(r, "weekdays", :any)
    hours = Map.get(r, "hours", :any)
    min_quantity = Map.get(r, "min_quantity", 1)

    with true <- is_boolean(enabled),
         true <- weekdays == :any or weekdays?(weekdays),
         {:ok, hours} <- hours(hours),
         true <- is_integer(min_quantity) and min_quantity >= 1 do
      {:ok, %{enabled: enabled, weekdays: weekdays, hours: hours, min_quantity: min_quantity}}
    else
      _ -> :error
    end
  end

  defp weekdays?(days),
    do: is_list(days) and days != [] and Enum.all?(days, &(&1 in 1..7)) and distinct?(days)

  defp hours(:any), do: {:ok, :any}
  defp hours([from, to]) when from in 0..23 and to in 0..23, do: {:ok, {from, to}}
  defp hours(_), do: :error

  defp id?(v),
    do:
      is_binary(v) and byte_size(v) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, v)

  defp text?(v), do: is_binary(v) and byte_size(v) in 1..128 and String.trim(v) != ""
  defp distinct?(list), do: Enum.uniq(list) == list
end
