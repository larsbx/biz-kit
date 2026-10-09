defmodule Dispatch.Accounts.User do
  @moduledoc """
  An authenticated person (Section 22.1).

  Global, not tenant-scoped: `oidc_subject` identifies one person at one
  identity provider regardless of how many carriers they work with (ADR-0005).

  A user is not an operational identity. Section 23.3 requires every request to
  select a single active role assignment and forbids unioning capabilities
  merely because assignments share a user, so the `Participant` — one per user
  per tenant — is what operational authorization is expressed over.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "users"
    repo Dispatch.Repo
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :oidc_subject, :string, allow_nil?: false, public?: true
    attribute :display_name, :string, allow_nil?: false, public?: true
    attribute :email, :ci_string, public?: true

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :SUSPENDED, :CLOSED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    # Section 22.1. Global, because an OIDC subject is global.
    identity :unique_oidc_subject, [:oidc_subject]
  end

  relationships do
    has_many :participants, Dispatch.Accounts.Participant do
      destination_attribute :user_id
    end
  end

  actions do
    defaults [:read]

    create :register do
      description "Records a user after interactive login. Confers no capability."
      accept [:oidc_subject, :display_name, :email, :status]
      upsert? true
      upsert_identity :unique_oidc_subject
      upsert_fields [:display_name, :email]
    end

    read :by_oidc_subject do
      argument :oidc_subject, :string, allow_nil?: false
      get? true
      filter expr(oidc_subject == ^arg(:oidc_subject))
    end

    update :set_status do
      accept [:status]
      require_atomic? false
    end
  end

  code_interface do
    define :register
    define :by_oidc_subject, args: [:oidc_subject]
  end
end
