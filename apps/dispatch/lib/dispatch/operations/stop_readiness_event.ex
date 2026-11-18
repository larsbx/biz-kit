defmodule Dispatch.Operations.StopReadinessEvent do
  @moduledoc "Append-only partner readiness; never a confirmed operational commitment."
  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "stop_readiness_events"
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

    attribute :state, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:NOT_READY, :READY, :CHECKED_IN, :BLOCKED]]

    attribute :note, :string, public?: true, constraints: [max_length: 2000]
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
      allow_nil_input [:occurred_at]
      accept [:stop_id, :state, :note, :occurred_at, :correlation_id]
      argument :expected_version, :integer, allow_nil?: false, constraints: [min: 0]
      argument :expected_latest_id, :uuid
      change {Dispatch.Fleet.Changes.RecordPartnerContribution, kind: :readiness}
    end
  end

  policies do
    policy action(:submit) do
      authorize_if {Dispatch.Access.Checks.PartnerMutation, kind: :readiness}
    end

    policy action_type(:read) do
      authorize_if {Dispatch.Access.Checks.PartnerScope,
                    subject: :record, capability: "stop.read"}
    end
  end
end
