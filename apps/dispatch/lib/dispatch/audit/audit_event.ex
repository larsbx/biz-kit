defmodule Dispatch.Audit.AuditEvent do
  @moduledoc """
  The append-only audit stream (Sections 12 and 22.3).

  Every row carries `previous_event_hash` and `event_hash`, so the stream is a
  chain per tenant: altering or removing an entry breaks every hash after it.
  Section 22.3 makes `event_hash` unique, which also makes the chain's integrity
  checkable without trusting the application that wrote it.

  Section 22.3 gives application roles no `UPDATE` or `DELETE` on this table. A
  correction is a new compensating event (Section 12), never an edit — the
  point of an audit trail is that it records what was believed at the time, not
  what turned out to be true.

  `payload_json` carries the facts of the event. Section 32 forbids logging
  access tokens, message bodies, transcripts, precise coordinates, face data,
  or provider credentials, and that applies here with more force than to a log:
  this row is retained for the audit period and is readable by anyone holding
  `audit.read`.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Audit,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "audit_events"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true

    attribute :event_type, :string do
      description "Stable dotted key, e.g. `status.declared`."
      allow_nil? false
      public? true
    end

    attribute :actor_type, :atom do
      constraints one_of: [:PARTICIPANT, :SERVICE, :SYSTEM]
      allow_nil? false
      public? true
    end

    attribute :actor_id, :uuid, public?: true

    attribute :role_assignment_id, :uuid do
      description """
      The single assignment the actor selected (Section 23.3). Recorded because
      "under which authority" is the question an audit answers, and a user with
      several roles makes it ambiguous otherwise.
      """

      public? true
    end

    attribute :subject_type, :string, allow_nil?: false, public?: true
    attribute :subject_id, :uuid, public?: true

    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :correlation_id, :string, public?: true

    attribute :payload_json, :map do
      default %{}
      allow_nil? false
      public? true
    end

    attribute :previous_event_hash, :string do
      description "The prior entry's hash for this tenant; null for the first."
      public? true
    end

    attribute :event_hash, :string, allow_nil?: false, public?: true

    create_timestamp :created_at
  end

  identities do
    # Section 22.3 states `audit_events.event_hash` unique, unqualified — the
    # same distinction it draws elsewhere between a global constraint and one
    # "within a tenant". Global costs nothing here, since the hash covers
    # `tenant_id` in its preimage, and it means a chain cannot be confused with
    # another tenant's even by a bug in tenant context.
    identity :unique_event_hash, [:event_hash], all_tenants?: true
  end

  actions do
    defaults [:read]

    create :record do
      description """
      Appends one entry, linking it to the tenant's previous entry.

      There is deliberately no update or destroy action. Section 22.3 gives
      application roles no UPDATE or DELETE on this table, and an action that
      existed but was policy-denied would still be one refactor from being
      allowed.
      """

      accept [
        :tenant_id,
        :event_type,
        :actor_type,
        :actor_id,
        :role_assignment_id,
        :subject_type,
        :subject_id,
        :occurred_at,
        :correlation_id,
        :payload_json
      ]

      change Dispatch.Audit.Changes.ChainHash
    end

    read :for_subject do
      argument :subject_type, :string, allow_nil?: false
      argument :subject_id, :uuid, allow_nil?: false

      filter expr(subject_type == ^arg(:subject_type) and subject_id == ^arg(:subject_id))
      prepare build(sort: [occurred_at: :asc])
    end

    read :chain do
      description "The tenant's entries in write order, for verification."
      prepare build(sort: [created_at: :asc, id: :asc])
    end
  end

  code_interface do
    define :record
    define :for_subject, args: [:subject_type, :subject_id]
    define :chain
  end
end
