defmodule SpruceGoose.Accounts do
  use Ash.Domain,
    otp_app: :spruce_goose

  resources do
    resource SpruceGoose.Accounts.Token
    resource SpruceGoose.Accounts.User
  end
end
