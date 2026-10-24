defmodule EatsbotWeb.TelegramWebhookTest do
  @moduledoc """
  `POST /telegram` takes updates from anyone who can reach it, so it must:

  - accept only requests carrying the secret token the bot registered with
    `setWebhook` (Telegram echoes it in `X-Telegram-Bot-Api-Secret-Token`);
    without it, a forged update impersonates any Telegram user by `from.id`
  - create no atoms from the body, whose keys are the caller's to choose
  """
  use EatsbotWeb.ConnCase, async: false

  alias Eatsbot.Extensions.TelegramBot.{Controller, Handler}

  @header "x-telegram-bot-api-secret-token"

  defp secret, do: Application.fetch_env!(:eatsbot, Handler)[:webhook_secret]

  defp post_update(conn, body), do: post(conn, "/telegram", body)

  test "the test configuration registers a webhook secret" do
    assert is_binary(secret()) and secret() != ""
  end

  test "an update without the secret token is rejected", %{conn: conn} do
    assert conn |> post_update(%{update_id: 1}) |> response(401)
  end

  test "an update with the wrong secret token is rejected", %{conn: conn} do
    conn = conn |> put_req_header(@header, secret() <> "x") |> post_update(%{update_id: 1})
    assert response(conn, 401)
  end

  test "an update with the secret token is handled", %{conn: conn} do
    conn = conn |> put_req_header(@header, secret()) |> post_update(%{update_id: 1})
    assert json_response(conn, 200)
  end

  test "invalid configured secrets fail closed even when the supplied value matches" do
    original = Application.fetch_env!(:eatsbot, Handler)
    on_exit(fn -> Application.put_env(:eatsbot, Handler, original) end)

    for invalid <- [
          nil,
          "",
          " ",
          "abc def",
          "abc!",
          "abc\n",
          "café",
          String.duplicate("a", 257),
          123
        ] do
      Application.put_env(:eatsbot, Handler, Keyword.put(original, :webhook_secret, invalid))

      # A malformed body must never reach update decoding or the handler.
      headers = if is_binary(invalid), do: [[], [{@header, invalid}]], else: [[]]

      for request_headers <- headers do
        conn =
          Plug.Test.conn(:post, "/telegram", %{"message" => "forged"})
          |> Map.put(:req_headers, request_headers)
          |> Controller.call(Controller.init(:update))

        assert conn.status == 401, inspect(invalid)
        assert conn.halted
      end
    end
  end

  test "empty, malformed and duplicate request tokens fail closed" do
    for headers <- [
          [{@header, ""}],
          [{@header, "bad token"}],
          [{@header, String.duplicate("a", 257)}],
          [{@header, secret()}, {@header, "forged"}],
          [{@header, "forged"}, {@header, secret()}]
        ] do
      conn =
        Plug.Test.conn(:post, "/telegram", %{"message" => "forged"})
        |> Map.put(:req_headers, headers)
        |> Controller.call(Controller.init(:update))

      assert conn.status == 401
      assert conn.halted
    end
  end

  test "both valid configured secret length boundaries authenticate", %{conn: conn} do
    original = Application.fetch_env!(:eatsbot, Handler)
    on_exit(fn -> Application.put_env(:eatsbot, Handler, original) end)

    for value <- ["a", String.duplicate("Az09_-", 42) <> "Az09"] do
      Application.put_env(:eatsbot, Handler, Keyword.put(original, :webhook_secret, value))
      response = conn |> put_req_header(@header, value) |> post_update(%{update_id: 1})
      assert json_response(response, 200)
    end
  end

  test "keys Telegram does not define create no atoms", %{conn: conn} do
    key = "eatsbot_unknown_key_#{System.unique_integer([:positive])}"

    conn
    |> put_req_header(@header, secret())
    |> post_update(%{"update_id" => 1, key => %{(key <> "_nested") => 1}})
    |> json_response(200)

    for k <- [key, key <> "_nested"] do
      assert_raise ArgumentError, fn -> String.to_existing_atom(k) end
    end
  end

  # Dropping unknown keys must lose nothing Telegram sends: every field of every
  # Telegram type survives atomization, so the typed update is unchanged.
  test "every field of every Telegram type keeps its atom" do
    Application.load(:telegex)

    types =
      for mod <- Application.spec(:telegex, :modules),
          Code.ensure_loaded?(mod) and function_exported?(mod, :__keys__, 0),
          do: mod

    assert length(types) > 100

    for type <- types, keys = type.__keys__() do
      atomized = keys |> Map.new(&{Atom.to_string(&1), true}) |> Controller.atomize_keys()
      assert Map.keys(atomized) |> Enum.sort() == Enum.sort(keys), inspect(type)
    end
  end

  test "a courier's message atomizes to the update the chains match on" do
    update = %{
      update_id: 7,
      message: %{
        message_id: 3,
        date: 1_700_000_000,
        text: "/start",
        from: %{id: 42, is_bot: false, first_name: "Ada"},
        chat: %{id: 42, type: "private"},
        location: %{latitude: 40.7, longitude: -74.0}
      }
    }

    assert update |> Jason.encode!() |> Jason.decode!() |> Controller.atomize_keys() == update
  end
end
