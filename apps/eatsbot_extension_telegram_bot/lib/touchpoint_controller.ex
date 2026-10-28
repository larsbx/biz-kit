defmodule Eatsbot.Extensions.TelegramBot.TouchpointController do
  @moduledoc """
  `GET /t/:code` — the URL written to counter NFC tags / QR stickers.
  Redirects into the bot, where Telegram identifies the customer.
  """
  use Phoenix.Controller, formats: [:html]
  import Plug.Conn

  alias EatsbotCore.Marketing
  alias EatsbotCore.Marketing.Touchpoint

  @actor EatsbotCore.Deliveries.Actors.private()

  def show(conn, %{"code" => code}) do
    with username when is_binary(username) <- Marketing.config(:telegram_bot_username),
         {:ok, touchpoint} <- Touchpoint.by_code(code, actor: @actor) do
      redirect(conn, external: "https://t.me/#{username}?start=v_#{touchpoint.code}")
    else
      _ -> conn |> put_status(:not_found) |> text("Not found")
    end
  end
end
