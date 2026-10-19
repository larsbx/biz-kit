defmodule SpruceGoose.Web.Requests do
  @moduledoc """
  JSON in and errors out for the endpoints people and administrators call:
  commands, device enrolment and its approval. Bodies must be
  `application/json` (a cross-site form cannot send it), every field is
  type-checked, and each refusal maps to one status and a short code. Why a
  request was refused goes to the log, not the response.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  require Logger

  # The endpoint's parsers have usually read the body already; the router
  # alone (as in tests) leaves it unread.
  def json_body(conn) do
    with ["application/json" <> _] <- get_req_header(conn, "content-type"),
         {:ok, %{} = body} <- body_params(conn) do
      {:ok, body}
    else
      _ -> {:error, :bad_request}
    end
  end

  defp body_params(%{body_params: %Plug.Conn.Unfetched{}} = conn) do
    with {:ok, raw, _conn} <- read_body(conn), do: Jason.decode(raw)
  end

  defp body_params(%{body_params: params}), do: {:ok, params}

  @doc "Arbitrary JSON may put anything where a string belongs."
  def string(value) when is_binary(value), do: {:ok, value}
  def string(_value), do: {:error, :bad_request}

  @doc "Unpadded base64url bytes, as the web view and the approval tool send them."
  def bytes(value) do
    with {:ok, text} <- string(value),
         {:ok, bytes} <- Base.url_decode64(text, padding: false) do
      {:ok, bytes}
    else
      _ -> {:error, :bad_request}
    end
  end

  def encode(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "The JSON of a held command (`CoopSubstrate.Commands.pending/0`)."
  def held(conn, pending) do
    conn
    |> put_status(201)
    |> json(%{
      id: pending.id,
      type: pending.type,
      payload: json_safe(pending.payload),
      signing_bytes: encode(pending.signing_bytes),
      expires_at: pending.expires_at
    })
  end

  def appended(conn, env),
    do: conn |> put_status(201) |> json(%{event_id: env.event_id, global_seq: env.global_seq})

  defp json_safe({:bytes, bytes}), do: encode(bytes)
  defp json_safe(%{} = map), do: Map.new(map, fn {k, v} -> {k, json_safe(v)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value

  @unauthorized [:no_credentials, :unknown_session, :expired, :unbound]
  @bad_request [:bad_request, :bad_decision, :invalid_pubkey, :key_id_mismatch, :invalid_label]
  @not_found [:unknown_command, :unknown_challenge, :unknown_code]
  @unprocessable [:bad_proof, :unknown_governance_key]
  @conflict [:unknown_suggestion, :suggestion_not_pending, :unknown_task, :already_enrolled]

  def refuse(conn, {:error, reason}) do
    {status, code} =
      case reason do
        r when r in @unauthorized -> {401, "unauthorized"}
        :no_operator_grant -> {403, "no_operator_grant"}
        r when r in @bad_request -> {400, Atom.to_string(r)}
        r when r in @not_found -> {404, Atom.to_string(r)}
        {:invalid_signature, _} -> {422, "invalid_signature"}
        r when r in @unprocessable -> {422, Atom.to_string(r)}
        r when r in @conflict -> {409, Atom.to_string(r)}
        _ -> {409, "refused_by_ledger"}
      end

    Logger.info("request refused: #{inspect(reason)}")
    conn |> put_status(status) |> json(%{error: code})
  end
end
