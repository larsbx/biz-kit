defmodule Eatsbot.Accounts.Token do
  @moduledoc """
  Temporary token for user accounts.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: Eatsbot.Accounts,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication.TokenResource],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "tokens"
    repo Eatsbot.Repo
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      description "AshAuthentication can interact with the token resource"
      authorize_if always()
    end

    policy always() do
      description "No one aside from AshAuthentication can interact with the tokens resource."
      forbid_if always()
    end
  end

  attributes do
    attribute :jti, :string do
      primary_key? true
      public? true
      allow_nil? false
      sensitive? true
    end

    attribute :subject, :string do
      allow_nil? false
    end

    attribute :expires_at, :utc_datetime do
      allow_nil? false
    end

    attribute :purpose, :string do
      allow_nil? false
      public? true
    end

    attribute :extra_data, :map do
      public? true
    end

    timestamps()
  end
end
