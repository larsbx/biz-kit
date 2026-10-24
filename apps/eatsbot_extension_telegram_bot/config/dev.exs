# This file contains the configuration for Telegram Bot
import Config

# The token, webhook URL and webhook secret are read at boot: config/runtime.exs.
config :telegex, token: ""
config :telegex, caller_adapter: Finch
config :telegex, hook_adapter: Bandit

config :eatsbot, Eatsbot.Extensions.TelegramBot.Handler, webhook_url: ""
