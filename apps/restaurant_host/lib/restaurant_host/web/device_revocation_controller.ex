defmodule RestaurantHost.Web.DeviceRevocationController do
  @moduledoc """
  The host's side of `mix restaurant.revoke` (`RestaurantHost.DeviceRevocations`):
  list granted devices to governance, hold a revocation, admit the signature.
  Every route is governance's: the listing is a signed read.
  """
  use Phoenix.Controller, formats: [:json]

  import RestaurantHost.Web.GovernanceApi
  alias RestaurantHost.{DeviceGrants, DeviceRevocations, Restaurant}

  def index(conn, _params) do
    r = Restaurant.current()

    case authorize(conn, r.chapter) do
      :ok -> json(conn, %{"devices" => DeviceRevocations.granted(r)})
      error -> refuse(conn, error)
    end
  end

  def prepare(conn, _params) do
    r = Restaurant.current()

    with %{"key" => key} <- conn.path_params,
         %{"governance_key_id" => key_id, "chapter_id" => chapter, "merchant_id" => merchant} =
           body <- conn.body_params,
         true <- map_size(body) == 3 and DeviceGrants.identifier?(key_id),
         true <- chapter == r.chapter and merchant == r.merchant,
         :ok <- authorize(conn, key_id, chapter),
         {:ok, h} <- DeviceRevocations.prepare(r, key, key_id) do
      held(conn, h)
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  def submit(conn, _params) do
    with %{"key" => key, "id" => id} <- conn.path_params,
         {:ok, signature} <- signature(conn.body_params),
         {:ok, env} <- DeviceRevocations.submit(Restaurant.current(), key, id, signature) do
      appended(conn, env)
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end
end
