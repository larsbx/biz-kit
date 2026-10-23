defmodule EatsbotCore.Orders do
  @moduledoc """
  Domain that is the single authority for what was ordered, at what price, and where
  it is in the kitchen. See `EatsbotCore.Orders.Transitions` for the lifecycle.
  """
  use Ash.Domain,
    otp_app: :eatsbot,
    extensions: [AshAdmin.Domain],
    validate_config_inclusion?: false

  admin do
    show?(true)
  end

  resources do
    resource EatsbotCore.Orders.Order
    resource EatsbotCore.Orders.OrderLine
    resource EatsbotCore.Orders.OrderStateChange
  end
end
