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

  def prepare(conn, _params) do
    r = Restaurant.current()

    with %{"device" => device} <- conn.path_params,
         %{"governance_key_id" => key_id, "chapter_id" => chapter, "merchant_id" => merchant} =
           body <- conn.body_params,
         true <- map_size(body) == 3 and DeviceGrants.identifier?(key_id),
         true <- chapter == r.chapter and merchant == r.merchant,
         :ok <- authorize(conn, key_id, chapter),
         {:ok, held} <- DeviceGrants.prepare(r, device, key_id) do
      conn
      |> put_status(201)
      |> json(%{
        id: held.id,
        type: held.type,
        signing_bytes: Base.url_encode64(held.signing_bytes, padding: false),
        expires_at: held.expires_at
      })
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  def submit(conn, _params) do
    with %{"device" => device, "id" => id} <- conn.path_params,
         %{"signature" => sig} = body <- conn.body_params,
         true <- map_size(body) == 1 and is_binary(sig),
         {:ok, <<_::512>> = signature} <- Base.url_decode64(sig, padding: false),
         {:ok, env} <- DeviceGrants.submit(Restaurant.current(), device, id, signature) do
      conn |> put_status(201) |> json(%{event_id: env.event_id, global_seq: env.global_seq})
    else
      {:error, _} = error -> refuse(conn, error)
      _ -> refuse(conn, {:error, :bad_request})
    end
  end

  # Authenticate preparation as well as the final event. Otherwise anyone
  # knowing the public governance key ID could evict an operator's live holds.
  defp authorize(conn, key_id, chapter) do
    with [header] <- get_req_header(conn, "authorization"),
         [_, ^key_id, ts, nonce, encoded] <-
           Regex.run(
             ~r/\ACoopGovernance key="([^"]+)", ts="([0-9]+)", nonce="([^"]+)", sig="([^"]+)"\z/,
             header
           ),
         {timestamp, ""} <- Integer.parse(ts),
         {:ok, <<_::512>> = signature} <- Base.url_decode64(encoded, padding: false),
         {:ok, chapters} <-
           CoopSubstrate.Governance.Read.authorize(
             %{
               method: conn.method,
               path: conn.request_path,
               timestamp_ms: timestamp,
               nonce: nonce,
               key_id: key_id
             },
             signature
           ),
         true <- chapter in chapters do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  defp refuse(conn, {:error, :forbidden}),
    do: conn |> put_status(403) |> json(%{error: "forbidden"})

  defp refuse(conn, {:error, :unknown_device}),
    do: conn |> put_status(404) |> json(%{error: "unknown_device"})

  defp refuse(conn, {:error, reason}),
    do:
      conn
      |> put_status(422)
      |> json(%{error: if(is_atom(reason), do: Atom.to_string(reason), else: "not_admitted")})
end
