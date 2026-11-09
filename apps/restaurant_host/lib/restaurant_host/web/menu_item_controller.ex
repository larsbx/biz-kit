defmodule RestaurantHost.Web.MenuItemController do
  @moduledoc """
  The host's side of `mix restaurant.menu` (`RestaurantHost.MenuItems`): show
  the menu, hold one item for a governance key, admit the signature. Nothing
  here can sign: only a governance signature on exactly the held item, at the
  version the operator reviewed, is admitted, by the ledger.
  """
  use Phoenix.Controller, formats: [:json]

  import RestaurantHost.Web.GovernanceApi
  alias RestaurantHost.{DeviceGrants, MenuItems, Restaurant}

  def index(conn, _params), do: json(conn, MenuItems.json(Restaurant.current()))

  def prepare(conn, _params) do
    r = Restaurant.current()

    with %{"item" => item_id} <- conn.path_params,
         %{
           "governance_key_id" => key_id,
           "chapter_id" => chapter,
           "merchant_id" => merchant,
           "expected_version" => version,
           "item" => item
         } = body <- conn.body_params,
         true <- map_size(body) == 5 and DeviceGrants.identifier?(key_id),
         true <- chapter == r.chapter and merchant == r.merchant,
         :ok <- authorize(conn, key_id, chapter),
         {:ok, h} <- MenuItems.prepare(r, item_id, item, version, key_id) do
      held(conn, h)
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  def submit(conn, _params) do
    with %{"item" => item_id, "id" => id} <- conn.path_params,
         {:ok, signature} <- signature(conn.body_params),
         {:ok, env} <- MenuItems.submit(Restaurant.current(), item_id, id, signature) do
      appended(conn, env)
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end
end
