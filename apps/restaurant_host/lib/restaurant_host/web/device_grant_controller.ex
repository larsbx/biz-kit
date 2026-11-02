defmodule RestaurantHost.Web.DeviceGrantController do
  @moduledoc """
  The host's side of `mix restaurant.grant` (`RestaurantHost.DeviceGrants`):
  show a device's grant, hold it for a governance key, admit the signature.
  Nothing here can sign: only a governance signature on exactly the held
  grant is admitted, by the ledger.
  """
  use Phoenix.Controller, formats: [:json]

  alias RestaurantHost.{DeviceGrants, Restaurant}

  def show(conn, %{"device" => device}) do
    case DeviceGrants.details(Restaurant.current(), device) do
      {:ok, d} -> json(conn, DeviceGrants.json(d))
      error -> refuse(conn, error)
    end
  end

  def prepare(conn, %{"device" => device, "governance_key_id" => key_id})
      when is_binary(key_id) do
    case DeviceGrants.prepare(Restaurant.current(), device, key_id) do
      {:ok, held} ->
        conn
        |> put_status(201)
        |> json(%{
          id: held.id,
          type: held.type,
          signing_bytes: Base.url_encode64(held.signing_bytes, padding: false),
          expires_at: held.expires_at
        })

      error ->
        refuse(conn, error)
    end
  end

  def prepare(conn, _), do: refuse(conn, {:error, :bad_request})

  def submit(conn, %{"device" => device, "id" => id, "signature" => sig}) when is_binary(sig) do
    with {:ok, signature} <- Base.url_decode64(sig, padding: false),
         {:ok, env} <- DeviceGrants.submit(device, id, signature) do
      conn |> put_status(201) |> json(%{event_id: env.event_id, global_seq: env.global_seq})
    else
      :error -> refuse(conn, {:error, :bad_request})
      error -> refuse(conn, error)
    end
  end

  def submit(conn, _), do: refuse(conn, {:error, :bad_request})

  defp refuse(conn, {:error, :unknown_device}),
    do: conn |> put_status(404) |> json(%{error: "unknown_device"})

  defp refuse(conn, {:error, reason}),
    do: conn |> put_status(422) |> json(%{error: inspect(reason)})
end
