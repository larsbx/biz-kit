defmodule RestaurantHost.MenuItems do
  @moduledoc """
  Editing the menu on the ledger, behind `mix restaurant.menu`, in the shape
  of `RestaurantHost.DeviceGrants` (decommission D6):

    1. the administrator's machine reads the menu (`json/1`, public) and asks
       the host to hold one item at the version it was shown;
    2. the host builds `RestaurantMenuItemPutV1` and holds it for a declared
       governance key (`CoopSubstrate.Commands.hold/5`), after the Log has
       checked it would admit it now;
    3. the administrator signs only if the held envelope is exactly that item
       at that version (`matches?/5`), and the Log admits or refuses it, so a
       review that another edit made stale is refused, not applied.

  The governance seed never leaves the administrator's machine.
  """

  alias CoopSubstrate.{Commands, Log}
  alias RestaurantCore.{Admission, Menu}
  alias RestaurantHost.Restaurant

  @type_name "RestaurantMenuItemPutV1"

  @doc "The menu as the Log holds it: its version and items in wire form, by id."
  def json(%Restaurant{} = r) do
    %{version: version, items: items} =
      Admission.menu(Log.gate().restaurant, r.chapter, r.merchant)

    %{
      "version" => version,
      "items" => items |> Map.values() |> Enum.sort_by(& &1.id) |> Enum.map(&Menu.encode_item/1)
    }
  end

  @doc "Hold one item at `expected_version` for this declared governance key to sign."
  def prepare(%Restaurant{} = r, item_id, item, expected_version, governance_key_id) do
    with {:ok, payload} <- payload(r, item_id, item, expected_version),
         {:ok, signer} <- Commands.governance_signer(r.chapter, governance_key_id) do
      Commands.hold(owner(r, item_id), r.chapter, @type_name, payload, signer)
    end
  end

  @doc "Submit the governance signature on a held item; the ledger admits or refuses."
  def submit(%Restaurant{} = r, item_id, held_id, <<_::512>> = signature)
      when is_binary(held_id) and byte_size(held_id) in 1..128,
      do: Commands.submit(owner(r, item_id), held_id, signature)

  def submit(_, _, _, _), do: {:error, :bad_request}

  @doc """
  Whether a decoded envelope core is exactly `item` for this chapter and
  merchant at `expected_version`: type, chapter and every payload field.
  """
  def matches?(core, chapter, merchant, item, expected_version) when is_map(core) do
    core["type"] == @type_name and core["chapter_id"] == chapter and
      core["payload"] ==
        Map.merge(item, %{"merchant_id" => merchant, "expected_version" => expected_version})
  end

  def matches?(_, _, _, _, _), do: false

  defp payload(r, item_id, item, version) do
    with true <- is_map(item) and item["item_id"] == item_id and is_integer(version),
         {:ok, _} <- Menu.decode_item(item) do
      {:ok, Map.merge(item, %{"merchant_id" => r.merchant, "expected_version" => version})}
    else
      _ -> {:error, :invalid_menu_item}
    end
  end

  # Bound to chapter, merchant and item, so a hold cannot be submitted through
  # another restaurant or for another item.
  defp owner(r, item_id), do: {:restaurant_menu_item, r.chapter, r.merchant, item_id}
end
