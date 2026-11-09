defmodule RestaurantHost.Web.DeviceGrantController do
  @moduledoc """
  The host's side of `mix restaurant.grant` (`RestaurantHost.DeviceGrants`):
  show a device's grant, hold it for a governance key, admit the signature.
  Nothing here can sign: only a governance signature on exactly the held
  grant is admitted, by the ledger.
  """
  use Phoenix.Controller, formats: [:json]

  import RestaurantHost.Web.GovernanceApi
  alias RestaurantHost.{DeviceGrants, Restaurant}

  def show(conn, %{"device" => device}) do
    case DeviceGrants.details(Restaurant.current(), device) do
      {:ok, d} -> json(conn, DeviceGrants.json(d))
      error -> refuse(conn, error)
    end
  end

  def prepare(conn, _params) do
    r = Restaurant.current()

    with %{"device" => device} <- conn.path_params,
         %{"governance_key_id" => key_id, "chapter_id" => chapter, "merchant_id" => merchant} =
           body <- conn.body_params,
         true <- map_size(body) == 3 and DeviceGrants.identifier?(key_id),
         true <- chapter == r.chapter and merchant == r.merchant,
         :ok <- authorize(conn, key_id, chapter),
         {:ok, h} <- DeviceGrants.prepare(r, device, key_id) do
      held(conn, h)
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  def submit(conn, _params) do
    with %{"device" => device, "id" => id} <- conn.path_params,
         {:ok, signature} <- signature(conn.body_params),
         {:ok, env} <- DeviceGrants.submit(Restaurant.current(), device, id, signature) do
      appended(conn, env)
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end
end
