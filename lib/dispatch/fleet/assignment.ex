defmodule Dispatch.Fleet.Assignment do
  @moduledoc """
  A participant's work on one load with one vehicle (Section 22.2).

  Section 22.2 permits at most one `ACTIVE` assignment per operator participant
  under the initial `DRIVER` profile, enforced by a partial unique index. The
  constraint is not bookkeeping: Section 6.1 scopes location collection to the
  active assignment, and Section 25.2's offline outbox attributes queued events
  to it, so two simultaneously active assignments would make "which trip is this
  sample for" unanswerable.

  Section 22.2 also notes that other role profiles may declare a different
  cardinality through reviewed application policy *and a matching database
  constraint* — the index is scoped to the profiles that need it rather than
  assumed universal.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "assignments"
    repo Dispatch.Repo

    identity_wheres_to_sql one_active_per_operator: "status = 'ACTIVE'"
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
    # Section 22.2: at most one ACTIVE assignment per operator participant.
    identity :one_active_per_operator, [:operator_participant_id], where: expr(status == :ACTIVE)
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
      description "Creates a PLANNED assignment. Planning does not start a trip."

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
