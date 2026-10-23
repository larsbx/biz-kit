defmodule Eatsbot.Extensions.TelegramBot.CheckIn do
  @moduledoc """
  Customer-facing marketing commands; runs before `Auth` since customers are
  not staff.

    * `/start v_<code>` — deep link from a counter NFC/QR sticker: check in
    * `/stop` — opt out of all promotions
  """
  use Telegex.Chain, :message

  alias Eatsbot.Extensions.TelegramBot.Marketing, as: Texts
  alias EatsbotCore.Marketing.{Subscriber, Visit}

  @actor EatsbotCore.Deliveries.Actors.private()

  @impl true
  def match?(%{text: "/start v_" <> _, chat: %{type: "private"}}, _context), do: true
  def match?(%{text: "/stop", chat: %{type: "private"}}, _context), do: true
  def match?(_message, _context), do: false

  @impl true
  def handle(%{text: "/start v_" <> code, chat: %{id: chat_id}}, context) do
    text =
      case Visit.check_in(code, :telegram, to_string(chat_id), actor: @actor, load: [:promotion]) do
        {:ok, visit} -> Texts.check_in(visit)
        {:error, _} -> Texts.invalid_touchpoint()
      end

    {:done, %{context | payload: Texts.reply(chat_id, text)}}
  end

  def handle(%{text: "/stop", chat: %{id: chat_id}}, context) do
    Subscriber.unsubscribe_all!(:telegram, to_string(chat_id), actor: @actor)
    {:done, %{context | payload: Texts.reply(chat_id, Texts.unsubscribed())}}
  end
end
