defmodule Dispatch.Communications.Conversation do
  @moduledoc """
  Partner-visible conversation metadata. Each thread names exactly one external
  organization and load; no message body, carrier note or other party contact
  is in this projection. Provider intake and message content arrive in Slice 4.
  Only internal intake can open a thread; partner authority is read-only.
  """
  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Communications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "conversations"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :tenant_id, :uuid, allow_nil?: false
    attribute :load_id, :uuid, allow_nil?: false
    attribute :organization_id, :uuid, allow_nil?: false
    attribute :subject, :string, allow_nil?: false, constraints: [max_length: 160]
    attribute :channel, :atom, allow_nil?: false, constraints: [one_of: [:SMS, :VOICE, :PORTAL]]

    attribute :state, :atom,
      allow_nil?: false,
      default: :OPEN,
      constraints: [one_of: [:OPEN, :CLOSED]]

    attribute :source, :atom, allow_nil?: false, default: :OBSERVED
    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, allow_nil?: false, default: 0
  end

  relationships do
    belongs_to :load, Dispatch.Fleet.Load, define_attribute?: false
  end

  actions do
    defaults [:read]

    create :open do
      accept [:tenant_id, :load_id, :organization_id, :subject, :channel]
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if {Dispatch.Access.Checks.PartnerScope,
                    subject: :conversation, capability: "communications.read.scoped"}
    end
  end
end
