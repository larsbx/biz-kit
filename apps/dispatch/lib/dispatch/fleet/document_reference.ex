defmodule Dispatch.Fleet.DocumentReference do
  @moduledoc "Append-only partner document; never a confirmed operational commitment."
  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "document_references"
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

    attribute :category, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:PICKUP_DOCUMENT, :PROOF_OF_DELIVERY]]

    attribute :label, :string, allow_nil?: false, public?: true, constraints: [max_length: 200]
    attribute :object_reference_ciphertext, :binary, allow_nil?: false, sensitive?: true
    attribute :scan_state, :atom, allow_nil?: false, default: :REFERENCE_ONLY
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
      accept [:stop_id, :category, :label, :correlation_id]
      argument :expected_version, :integer, allow_nil?: false, constraints: [min: 0]
      argument :reference, :string, allow_nil?: false, constraints: [max_length: 500]
      change {Dispatch.Fleet.Changes.RecordPartnerContribution, kind: :document}
    end
  end

  policies do
    policy action(:submit) do
      authorize_if {Dispatch.Access.Checks.PartnerMutation, kind: :document}
    end

    policy action_type(:read) do
      authorize_if {Dispatch.Access.Checks.PartnerScope,
                    subject: :record, capability: "document_reference.read"}
    end
  end
end
