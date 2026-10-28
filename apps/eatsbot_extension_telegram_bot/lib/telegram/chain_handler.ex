defmodule Eatsbot.Extensions.TelegramBot.ChainHandler do
  @moduledoc false
  alias Eatsbot.Extensions.TelegramBot
  use Telegex.Chain.Handler

  pipeline([
    TelegramBot.CheckIn,
    TelegramBot.Auth,
    TelegramBot.ReceiveLocation,
    TelegramBot.SetToken,
    TelegramBot.SetTokenCallback,
    TelegramBot.Redeem,
    Eatsbot.Extensions.TelegramBot.Done
  ])
end
