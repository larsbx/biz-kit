defmodule Eatsbot.Extensions.TelegramBot.Marketing do
  @moduledoc """
  Copy and parsing for the marketing flows.

  Replies are plain text (no MarkdownV2): promotion copy is written by the
  restaurant and must not be interpreted as markup.
  """
  use Gettext, backend: Eatsbot.Extensions.TelegramBot.Gettext

  def reply(chat_id, text), do: %{method: "sendMessage", chat_id: chat_id, text: text}

  def promotion(%{title: title, body: body}),
    do: Enum.join([title, body, opt_out()], "\n\n")

  def check_in(%{code: code, promotion: %{} = promotion}),
    do: Enum.join([promotion.title, promotion.body, show_code(code), opt_out()], "\n\n")

  def check_in(%{code: code}),
    do:
      Enum.join(
        [
          gettext("Thanks for checking in! We will let you know about our next promotion."),
          show_code(code),
          opt_out()
        ],
        "\n\n"
      )

  def redeemed(%{code: code, amount: amount}),
    do: gettext("Visit {code} redeemed: {amount}.", code: code, amount: Money.to_string!(amount))

  def invalid_touchpoint, do: gettext("Sorry, this sticker is not valid anymore.")
  def unsubscribed, do: gettext("Done. You will not receive promotions anymore.")
  def redeem_usage, do: gettext("Usage: /redeem CODE AMOUNT, e.g. /redeem AB12CD 12500")
  def redeem_failed, do: gettext("Code not found, expired or already redeemed.")

  defp show_code(code), do: gettext("Show this code at the counter: {code}", code: code)
  defp opt_out, do: gettext("Send /stop to stop receiving promotions.")

  @doc "Parses `CODE AMOUNT`; the amount is a positive integer or dot-decimal."
  @spec parse_redeem(String.t()) :: {:ok, String.t(), Decimal.t()} | :error
  def parse_redeem(args) do
    with [code, amount] <- String.split(args),
         true <- amount =~ ~r/\A\d+(\.\d+)?\z/,
         amount = Decimal.new(amount),
         true <- Decimal.gt?(amount, 0) do
      {:ok, String.upcase(code), amount}
    else
      _ -> :error
    end
  end
end
