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

  alias CoopSubstrate.Governance.Read

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
  def bytes(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case bytes(value) do
        {:ok, b} -> {:cont, {:ok, acc ++ [b]}}
        error -> {:halt, error}
      end
    end)
  end

  def bytes(value) do
    with {:ok, text} <- string(value),
         {:ok, bytes} <- Base.url_decode64(text, padding: false) do
      {:ok, bytes}
    else
      _ -> {:error, :bad_request}
    end
  end

  def encode(bytes), do: Base.url_encode64(bytes, padding: false)

  @doc "A query parameter, whether or not the endpoint's parsers have run."
  def query(conn, name), do: fetch_query_params(conn).query_params[name]

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

  @doc "A batch held as one (`Commands.hold_batch/4`): each command to sign, in order."
  def held_batch(conn, batch) do
    conn
    |> put_status(201)
    |> json(%{
      id: batch.id,
      expires_at: batch.expires_at,
      commands:
        Enum.map(
          batch.commands,
          &%{
            type: &1.type,
            payload: json_safe(&1.payload),
            signing_bytes: encode(&1.signing_bytes)
          }
        )
    })
  end

  def appended(conn, [_ | _] = envs),
    do:
      conn
      |> put_status(201)
      |> json(%{events: Enum.map(envs, &%{event_id: &1.event_id, global_seq: &1.global_seq})})

  def appended(conn, env),
    do: conn |> put_status(201) |> json(%{event_id: env.event_id, global_seq: env.global_seq})

  defp json_safe({:bytes, bytes}), do: encode(bytes)
  defp json_safe(%{} = map), do: Map.new(map, fn {k, v} -> {k, json_safe(v)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value

  @unauthorized [:no_credentials, :unknown_session, :expired, :unbound]
  @bad_request [
    :bad_request,
    :bad_decision,
    :bad_amendment,
    :bad_action,
    :invalid_pubkey,
    :key_id_mismatch,
    :invalid_label,
    :invalid_role,
    :signature_count
  ]
  @not_found [
    :unknown_command,
    :unknown_challenge,
    :unknown_code,
    :unknown_device,
    :unknown_grant,
    :unknown_receipt
  ]
  @unprocessable [:bad_proof, :unknown_governance_key, :digest_mismatch, :not_named]
  @conflict [
    :unknown_suggestion,
    :suggestion_not_pending,
    :unknown_task,
    :unknown_delegation,
    :already_enrolled,
    :grant_already_revoked,
    :nothing_to_offboard,
    :unknown_role_key,
    :no_submission
  ]

  @fields ~w(key ts nonce sig)

  @doc """
  The chapters a request signed by a governance key (`Governance.Read`, an
  `Authorization: CoopGovernance …` header) may act on, or
  `{:unauthorized, reason}`.
  """
  def governance_read(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         "CoopGovernance " <> params <- header,
         fields = Map.new(Regex.scan(~r/(\w+)="([^"]*)"/, params), fn [_, k, v] -> {k, v} end),
         true <- Enum.all?(@fields, &Map.has_key?(fields, &1)),
         {ts, ""} <- Integer.parse(fields["ts"]),
         {:ok, signature} <- Base.url_decode64(fields["sig"], padding: false) do
      Read.authorize(
        %{
          method: conn.method,
          path: conn.request_path,
          timestamp_ms: ts,
          nonce: fields["nonce"],
          key_id: fields["key"]
        },
        signature
      )
      |> case do
        {:ok, chapters} -> {:ok, chapters}
        {:error, reason} -> {:unauthorized, reason}
      end
    else
      _ -> {:unauthorized, :malformed_authorization}
    end
  end

  @doc "401 for a governance request, its reason logged."
  def unauthorized(conn, reason) do
    Logger.info("governance read refused: #{inspect(reason)}")

    conn
    |> put_resp_header("www-authenticate", "CoopGovernance")
    |> put_status(401)
    |> json(%{error: "unauthorized"})
  end

  defp ledger_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp ledger_reason(reason) when is_tuple(reason), do: ledger_reason(elem(reason, 0))
  defp ledger_reason(_reason), do: "refused_by_ledger"

  def refuse(conn, {:error, reason}) do
    {status, code} =
      case reason do
        r when r in @unauthorized ->
          {401, "unauthorized"}

        r
        when r in [
               :no_operator_grant,
               :no_reviewer_grant,
               :no_grant,
               :no_device,
               :needs_administrator
             ] ->
          {403, Atom.to_string(r)}

        r when r in [:too_large, :quota_exceeded] ->
          {413, Atom.to_string(r)}

        r when r in @bad_request ->
          {400, Atom.to_string(r)}

        r when r in @not_found ->
          {404, Atom.to_string(r)}

        {:invalid_signature, _} ->
          {422, "invalid_signature"}

        # An edited value the ledger would refuse, said before anyone signs.
        {:invalid, {:invalid_task_timing, _}} ->
          {400, "invalid_timing"}

        {:invalid, :empty_task_field} ->
          {400, "empty_field"}

        # What the ledger would refuse, named, so the page can say why.
        {:invalid, reason} ->
          {409, ledger_reason(reason)}

        r when r in @unprocessable ->
          {422, Atom.to_string(r)}

        r when r in @conflict ->
          {409, Atom.to_string(r)}

        _ ->
          {409, "refused_by_ledger"}
      end

    Logger.info("request refused: #{inspect(reason)}")
    conn |> put_status(status) |> json(%{error: code})
  end
end
