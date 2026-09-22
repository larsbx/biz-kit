defmodule Eatsbot.Extensions.TelegramBot.Redeem do
  @moduledoc """
  Staff command `/redeem CODE AMOUNT`: the cashier records the bill of a
  customer who checked in, booking the service's commission. Runs after
  `Auth`, so only approved staff reach it.
  """
  use Telegex.Chain, {:command, :redeem}

  alias Eatsbot.Extensions.TelegramBot.Marketing, as: Texts
  alias EatsbotCore.Marketing
  alias EatsbotCore.Marketing.Visit

  @command "/redeem"
  @actor EatsbotCore.Deliveries.Actors.private()

  @impl true
  def match?(%{text: @command, chat: %{type: "private"}}, _context), do: true
  def match?(%{text: @command <> " " <> _, chat: %{type: "private"}}, _context), do: true
  def match?(_message, _context), do: false

  @impl true
  def handle(%{text: @command <> args, chat: %{id: chat_id}}, context) do
    text =
      with {:ok, code, amount} <- Texts.parse_redeem(args) do
        case Visit.redeem(code, Money.new!(Marketing.config(:currency), amount), actor: @actor) do
          {:ok, visit} -> Texts.redeemed(visit)
          {:error, _} -> Texts.redeem_failed()
        end
      else
        :error -> Texts.redeem_usage()
      end

    {:done, %{context | payload: Texts.reply(chat_id, text)}}
  end
end
