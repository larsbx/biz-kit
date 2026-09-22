defmodule EatsbotCore.Marketing do
  @moduledoc """
  Restaurant marketing agent: notify subscribed customers of promotions and
  attribute in-store visits to the app via an NFC/QR sticker at the counter,
  so the service earns a revenue share on the bills it brought in.

  See `EatsbotCore.Marketing.Attribution` for the rules.

  ## Configuration

      config :eatsbot, EatsbotCore.Marketing,
        public_url: "https://eats.example.com",
        telegram_bot_username: "EatsbotBot",
        attribution_window_hours: 168,
        redemption_window_hours: 12,
        default_commission_rate: "0.05",
        currency: :CLP
  """
  use Ash.Domain,
    otp_app: :eatsbot,
    extensions: [AshAdmin.Domain],
    validate_config_inclusion?: false

  admin do
    show?(true)
  end

  resources do
    resource EatsbotCore.Marketing.Touchpoint
    resource EatsbotCore.Marketing.Promotion
    resource EatsbotCore.Marketing.Subscriber
    resource EatsbotCore.Marketing.Visit
  end

  @defaults [
    public_url: "http://localhost:4000",
    telegram_bot_username: nil,
    attribution_window_hours: 7 * 24,
    redemption_window_hours: 12,
    default_commission_rate: "0.05",
    currency: :CLP
  ]

  def config(key),
    do: :eatsbot |> Application.get_env(__MODULE__, []) |> Keyword.get(key, @defaults[key])

  def attribution_window, do: config(:attribution_window_hours) * 3600
  def redemption_window, do: config(:redemption_window_hours) * 3600
  def default_commission_rate, do: Decimal.new(config(:default_commission_rate))
end
