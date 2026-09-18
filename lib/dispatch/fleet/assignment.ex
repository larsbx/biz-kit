defmodule Dispatch.Fleet.Assignment do
  @moduledoc """
  A participant's work on one load with one vehicle (Section 22.2).

  Section 22.2 permits at most one `ACTIVE` assignment per operator participant
  **for the initial `DRIVER` role profile**, and says other profiles "may
  declare a different cardinality constraint through reviewed application policy
  and a matching database constraint".

  Both halves are load-bearing. The restriction is not bookkeeping: Section 6.1
  scopes location collection to the active assignment and Section 25.2's offline
  outbox attributes queued events to it, so two simultaneously active
  assignments would make "which trip is this sample for" unanswerable. But
  applying it to every profile would be wrong in the other direction — a
  dispatcher, or a future courier or team-driver profile, has no such limit, and
  a universal index would block work the specification permits.

  `operator_exclusive` carries the deciding profile's answer onto the row, so
  the unique index is partial on it. That is the "matching database constraint":
  the rule lives in the database rather than in application code a bulk import
  could bypass, while applying only to the profiles that declare it. It defaults
  to `true`, so a caller that says nothing gets the restrictive behaviour.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "assignments"
    repo Dispatch.Repo

    # Partial on both columns: the rule binds only while an assignment is active
    # *and* only for profiles that declare exclusivity (Section 22.2).
    identity_wheres_to_sql one_active_per_operator: "status = 'ACTIVE' AND operator_exclusive"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :load_id, :uuid, allow_nil?: false, public?: true
    attribute :operator_participant_id, :uuid, allow_nil?: false, public?: true
    attribute :vehicle_id, :uuid, public?: true
    attribute :trailer_id, :uuid, public?: true

    attribute :starts_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ends_at, :utc_datetime_usec, public?: true

    attribute :operator_exclusive, :boolean do
      description """
      Whether the operator's role profile limits them to one active assignment
      (Section 22.2). Derived from that profile, never supplied by the caller.
      """

      default true
      allow_nil? false
      public? false
    end

    attribute :status, :atom do
      constraints one_of: [:PLANNED, :ACTIVE, :COMPLETED, :CANCELLED]
      default :PLANNED
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    # Section 22.2: at most one ACTIVE assignment per operator participant, for
    # profiles that declare exclusivity. A profile permitting concurrency sets
    # `operator_exclusive` false and falls outside the index entirely.
    identity :one_active_per_operator, [:operator_participant_id],
      where: expr(status == :ACTIVE and operator_exclusive == true)
  end

  relationships do
    belongs_to :load, Dispatch.Fleet.Load do
      source_attribute :load_id
      attribute_writable? true
    end

    has_many :assignment_contacts, Dispatch.Fleet.AssignmentContact do
      destination_attribute :assignment_id
    end
  end

  actions do
    defaults [:read]

    create :plan do
      description """
      Creates a PLANNED assignment. Planning does not start a trip.

      `operator_role_assignment_id` names the role the operator is assigned
      under and decides whether Section 22.2's one-active-assignment rule
      applies. It is an argument rather than an accepted attribute because the
      answer is derived from the profile, never asserted: a caller must not be
      able to opt out of the restriction by claiming it does not apply. Omitted,
      the restrictive default stands.
      """

      argument :operator_role_assignment_id, :uuid

      accept [
        :tenant_id,
        :load_id,
        :operator_participant_id,
        :vehicle_id,
        :trailer_id,
        :starts_at,
        :ends_at
      ]

      change set_attribute(:status, :PLANNED)
      change Dispatch.Fleet.Changes.DeriveOperatorExclusivity
    end

    read :active do
      argument :at, :utc_datetime_usec, default: &DateTime.utc_now/0

      filter expr(
               status == :ACTIVE and starts_at <= ^arg(:at) and
                 (is_nil(ends_at) or ends_at > ^arg(:at))
             )
    end

    read :for_operator do
      argument :operator_participant_id, :uuid, allow_nil?: false
      filter expr(operator_participant_id == ^arg(:operator_participant_id))
    end

    update :activate do
      description "Starts the trip. The partial index refuses a second active assignment."
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :ACTIVE)
      change Dispatch.Accounts.Changes.IncrementVersion
    end

    update :complete do
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :COMPLETED)
      change set_attribute(:ends_at, &DateTime.utc_now/0)
      change Dispatch.Accounts.Changes.IncrementVersion
    end

    update :cancel do
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :CANCELLED)
      change set_attribute(:ends_at, &DateTime.utc_now/0)
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :plan
    define :active
    define :for_operator, args: [:operator_participant_id]
    define :activate
    define :complete
  end
end
