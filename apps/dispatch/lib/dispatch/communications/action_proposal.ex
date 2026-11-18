defmodule Dispatch.Communications.ActionProposal do
  @moduledoc "Append-only partner proposal; never a confirmed operational commitment."
  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Communications,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "action_proposals"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :tenant_id, :uuid, allow_nil?: false
    attribute :stop_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false
    attribute :participant_id, :uuid, allow_nil?: false
    attribute :role_assignment_id, :uuid, allow_nil?: false
    attribute :source, :atom, default: :PARTICIPANT, allow_nil?: false
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :recorded_at, :utc_datetime_usec, default: &DateTime.utc_now/0, allow_nil?: false
    attribute :correlation_id, :uuid, allow_nil?: false, public?: true
    attribute :basis_version, :integer, allow_nil?: false
    create_timestamp :created_at

    attribute :kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:APPOINTMENT, :INSTRUCTION]]

    attribute :window_start, :utc_datetime_usec, public?: true
    attribute :window_end, :utc_datetime_usec, public?: true
    attribute :instructions, :string, public?: true, constraints: [max_length: 2000]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :canonical_payload, :string, allow_nil?: false
    attribute :payload_sha256, :string, allow_nil?: false, public?: true

    attribute :state, :atom,
      allow_nil?: false,
      default: :PROPOSED,
      constraints: [one_of: [:PROPOSED]]
  end

  relationships do
    belongs_to :stop, Dispatch.Fleet.Stop, define_attribute?: false
  end

  identities do
    identity :unique_contribution, [:stop_id, :role_assignment_id, :correlation_id]
  end

  actions do
    defaults [:read]

    create :submit do
      accept [
        :stop_id,
        :kind,
        :window_start,
        :window_end,
        :instructions,
        :expires_at,
        :correlation_id
      ]

      argument :expected_version, :integer, allow_nil?: false, constraints: [min: 0]
      change {Dispatch.Fleet.Changes.RecordPartnerContribution, kind: :proposal}
    end
  end

  policies do
    policy action(:submit) do
      authorize_if {Dispatch.Access.Checks.PartnerMutation, kind: :proposal}
    end

    policy action_type(:read) do
      authorize_if {Dispatch.Access.Checks.PartnerScope,
                    subject: :record, capability: "proposal.create"}
    end
  end
end
