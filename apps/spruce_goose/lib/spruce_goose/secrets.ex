defmodule SpruceGoose.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        SpruceGoose.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:spruce_goose, :token_signing_secret)
  end

end
