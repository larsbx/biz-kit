defmodule RestaurantHost.Web.GovernanceApi do
  @moduledoc """
  What the governance-signed JSON routes share (`mix restaurant.grant`,
  `mix restaurant.menu`): authenticating a request to prepare a hold, so that
  knowing a public key ID is not enough to evict an operator's live holds, and
  mapping refusals to statuses.
  """
  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias CoopSubstrate.Governance.{Authorization, Read}

  @doc "`:ok` when the request is signed by `key_id`, which governs `chapter`."
  def authorize(conn, key_id, chapter) do
    with [header] <- get_req_header(conn, "authorization"),
         {:ok, %{key_id: ^key_id} = request, signature} <-
           Authorization.parse(header, conn.method, conn.request_path),
         {:ok, chapters} <- Read.authorize(request, signature),
         true <- chapter in chapters do
      :ok
    else
      _ -> {:error, :forbidden}
    end
  end

  @doc "A hold, as the operator's client reads it."
  def held(conn, held),
    do:
      conn
      |> put_status(201)
      |> json(%{
        id: held.id,
        type: held.type,
        signing_bytes: Base.url_encode64(held.signing_bytes, padding: false),
        expires_at: held.expires_at
      })

  @doc "A submitted signature's body, decoded, or `:error`."
  def signature(%{"signature" => sig} = body) when map_size(body) == 1 and is_binary(sig) do
    case Base.url_decode64(sig, padding: false) do
      {:ok, <<_::512>> = signature} -> {:ok, signature}
      _ -> :error
    end
  end

  def signature(_), do: :error

  def appended(conn, env),
    do: conn |> put_status(201) |> json(%{event_id: env.event_id, global_seq: env.global_seq})

  def refuse(conn, {:error, :forbidden}),
    do: conn |> put_status(403) |> json(%{error: "forbidden"})

  def refuse(conn, {:error, :unknown_device}),
    do: conn |> put_status(404) |> json(%{error: "unknown_device"})

  def refuse(conn, {:error, reason}),
    do:
      conn
      |> put_status(422)
      |> json(%{error: if(is_atom(reason), do: Atom.to_string(reason), else: "not_admitted")})
end
