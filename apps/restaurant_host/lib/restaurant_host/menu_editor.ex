defmodule RestaurantHost.MenuEditor do
  @moduledoc """
  Operator-side menu editing (decommission D6), shared by Mix and the
  production release: `put ITEM.json` reads the host's menu, shows the item it
  adds or replaces next to the current one, and signs with the governance key
  in HARNESS_KEYS_DIR only an envelope that is exactly that item at the menu
  version shown. It starts only the HTTP client, never a ledger writer or the
  host. The item file is the wire form `RestaurantCore.Menu` admits (no
  `merchant_id` or `expected_version`: the tool adds those).
  """
  alias CoopSubstrate.Governance.Client
  alias RestaurantCore.Menu
  alias RestaurantHost.{DeviceGrants, Enrollment, MenuItems}

  @usage "restaurant.menu put ITEM.json --chapter CHAPTER --merchant MERCHANT [--server URL] [--yes]"

  def run(args, io \\ %{info: &IO.puts/1, confirm: &confirm/1}) do
    with {:ok, path, chapter, merchant, base, yes?} <- options(args),
         {:ok, item} <- read_item(path),
         {:ok, %{"version" => version, "items" => items}} <- Client.get(base <> "/api/menu"),
         {:ok, signer} <- Enrollment.load_signer() do
      current = Enum.find(items, &(&1["item_id"] == item["item_id"]))

      io.info.("""
      Restaurant menu, chapter #{chapter}, merchant #{merchant}, menu version #{version}
      #{change(current, item)}
      Sign it with governance key #{signer.key_id}?
      """)

      if yes? or io.confirm.("Update?") do
        url = base <> "/api/menu-items/" <> Client.segment(item["item_id"])

        params = %{
          "chapter_id" => chapter,
          "merchant_id" => merchant,
          "expected_version" => version,
          "item" => item
        }

        expected = &MenuItems.matches?(&1, chapter, merchant, item, version)

        case Client.sign_held(url, signer, expected, params) do
          {:ok, %{"event_id" => id}} ->
            io.info.("menu updated: event #{id}")
            :ok

          _ ->
            {:error, :not_updated}
        end
      else
        io.info.("not updated; nothing was signed")
        :ok
      end
    else
      {:ok, _unexpected} -> {:error, :unexpected_menu}
      {:error, _} = error -> error
      _ -> {:error, :unexpected_menu}
    end
  rescue
    _ -> {:error, :unexpected_menu}
  end

  @doc "Release entry point; returns a failing exit status on refusal."
  def main(args) do
    case run(args) do
      :ok ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Menu update refused: #{reason}. Usage: #{@usage}")
        System.halt(1)
    end
  end

  defp change(nil, item), do: "new item #{item["item_id"]}: " <> describe(item)

  defp change(current, item),
    do: """
    item #{item["item_id"]}
      replaces #{describe(current)}
      with     #{describe(item)}\
    """

  defp describe(i) do
    rules =
      for r <- i["discounts"] do
        fields =
          r
          |> Map.drop(~w(id method))
          |> Enum.sort()
          |> Enum.map_join(" ", fn {k, v} -> "#{k} #{inspect_value(v)}" end)

        "\n      #{r["id"]}: #{r["method"]} #{fields}"
      end

    "#{i["name"]} (#{i["sku"]}) #{i["price_minor"]} #{i["currency"]}, #{i["visibility"]}#{rules}"
  end

  defp inspect_value(v) when is_binary(v), do: v
  defp inspect_value(v), do: inspect(v)

  # Refuse before review what the ledger would refuse anyway.
  defp read_item(path) do
    with {:ok, json} <- File.read(path),
         {:ok, %{} = item} <- Jason.decode(json),
         {:ok, _} <- Menu.decode_item(item) do
      {:ok, item}
    else
      _ -> {:error, :invalid_menu_item}
    end
  end

  defp options(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          server: [:string, :keep],
          chapter: [:string, :keep],
          merchant: [:string, :keep],
          yes: [:boolean, :keep]
        ]
      )

    with ["put", path] <- positional,
         [] <- invalid,
         true <- length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
         true <- Enum.all?([opts[:chapter], opts[:merchant]], &DeviceGrants.identifier?/1),
         {:ok, base} <- Enrollment.server(opts[:server]) do
      {:ok, path, opts[:chapter], opts[:merchant], base, opts[:yes] == true}
    else
      _ -> {:error, :invalid_options}
    end
  end

  defp confirm(prompt), do: IO.gets(prompt <> " [y/N] ") in ["y\n", "Y\n", "yes\n"]
end
