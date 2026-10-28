defmodule Eatsbot.Extensions.TelegramBot.Controller do
  # TODO: Implement proper docs
  @moduledoc false

  require Logger

  use Phoenix.Controller, formats: [:json]

  alias Eatsbot.Extensions.TelegramBot.Handler

  plug :verify_secret_token

  # Every field name of every Telegram type, as atoms held by this module. Bodies
  # are atomized against it: a key the caller invents is dropped, never interned.
  Application.load(:telegex)

  @fields for mod <- Application.spec(:telegex, :modules),
              Code.ensure_compiled!(mod) && function_exported?(mod, :__keys__, 0),
              field <- mod.__keys__(),
              into: %{},
              do: {Atom.to_string(field), field}

  def update(conn, params) do
    params = atomize_keys(params)
    Logger.debug(params)

    update = Telegex.Helper.typedmap(params, Telegex.Type.Update)

    Logger.debug(update)

    try do
      Handler.on_update(update)
    rescue
      e ->
        Handler.on_failure(update, {e, __STACKTRACE__})
    end
    |> case do
      {:done, %{payload: payload}} ->
        json(conn, payload)

      _ ->
        json(conn, %{})
    end
  end

  # Telegram sends back the secret the webhook was registered with; anything else
  # could be anyone, posing as any Telegram user.
  defp verify_secret_token(conn, _opts) do
    expected = Application.get_env(:eatsbot, Handler, [])[:webhook_secret]
    given = get_req_header(conn, "x-telegram-bot-api-secret-token")

    case given do
      [token] when is_binary(expected) and is_binary(token) ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{1,256}\z/, expected) and
             Plug.Crypto.secure_compare(token, expected),
           do: conn,
           else: conn |> send_resp(401, "") |> halt()

      _ ->
        conn |> send_resp(401, "") |> halt()
    end
  end

  @doc false
  def atomize_keys(nil), do: nil

  def atomize_keys(%{__struct__: _} = struct) do
    struct
  end

  def atomize_keys(%{} = map) do
    for {k, v} <- map, field = @fields[k], into: %{}, do: {field, atomize_keys(v)}
  end

  def atomize_keys([head | rest]) do
    [atomize_keys(head) | atomize_keys(rest)]
  end

  def atomize_keys(not_a_map) do
    not_a_map
  end
end
