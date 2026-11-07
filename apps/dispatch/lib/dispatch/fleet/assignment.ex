defmodule Dispatch.Fleet.Assignment do
  @moduledoc """
  A participant's work on one load with one vehicle (Section 22.2).

  E3 applies across tenants sharing this Dispatch database: one global User
  may have several ACTIVE assignments only when every one is explicitly
  concurrent. An exclusive assignment excludes every other active assignment
  for that User. PLANNED work does not reserve occupancy; only a committed
  completion or cancellation releases it. Recorded timestamps do not release it.

  The server derives and freezes `operator_user_id`, the selected role and
  definition, and `operator_exclusive` when planning. PostgreSQL enforces the
  User binding and both halves of E3 (exclusive/exclusive and mixed modes).
  Authorization remains local to the participant, tenant and carrier.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "assignments"
    repo Dispatch.Repo

    # Keep the historical E1 identity during rollout. The global E3 constraints
    # are explicitly named because an Ash tenant identity would add tenant_id.
    identity_wheres_to_sql one_active_per_operator: "status = 'ACTIVE' AND operator_exclusive"

    unique_index_names [
      {[:operator_user_id], "assignments_active_exclusive_user_uniq",
       "the driver is unavailable for this assignment"}
    ]

    exclusion_constraint_names [
      {:operator_user_id, "assignments_active_mixed_user_modes_excl",
       "the driver is unavailable for this assignment"}
    ]
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
    attribute :operator_user_id, :uuid, allow_nil?: false, public?: false
    attribute :operator_role_assignment_id, :uuid, public?: false
    attribute :operator_role_definition_id, :uuid, public?: false
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
    # Historical E1 index retained. E3 additionally rejects mixed-mode and
    # shared-User conflicts across tenant and participant identities.
    identity :one_active_per_operator, [:operator_participant_id],
      where: expr(status == :ACTIVE and operator_exclusive == true),
      message: "the driver is unavailable for this assignment"
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
      under. It must be current and bound to this operator, tenant, carrier and
      trip scope. Its definition and mode are recorded privately and revalidated
      at activation. Callers cannot assert the User or mode. An omitted source
      keeps the exclusive default; an explicitly invalid source is rejected.
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
      description "Starts the trip when the immutable policy is current and E3 permits it."
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :ACTIVE)
      change Dispatch.Fleet.Changes.GuardAssignmentTransition
      change Dispatch.Accounts.Changes.IncrementVersion
      change optimistic_lock(:version)
    end

    update :complete do
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :COMPLETED)
      change set_attribute(:ends_at, &DateTime.utc_now/0)
      change Dispatch.Fleet.Changes.GuardAssignmentTransition
      change Dispatch.Accounts.Changes.IncrementVersion
      change optimistic_lock(:version)
      # Section 6.1: consent lasts for the trip plus grace, so it ends now too.
      change Dispatch.Fleet.Changes.CloseLocationConsents
    end

    update :cancel do
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :CANCELLED)
      change set_attribute(:ends_at, &DateTime.utc_now/0)
      change Dispatch.Fleet.Changes.GuardAssignmentTransition
      change Dispatch.Accounts.Changes.IncrementVersion
      change optimistic_lock(:version)
      # Section 6.1: consent lasts for the trip plus grace, so it ends now too.
      change Dispatch.Fleet.Changes.CloseLocationConsents
    end
  end

  @doc """
  Whether a trip is not yet over at `at`: PLANNED or ACTIVE, and not past its
  recorded end. What `Trips.mine/1` lists and `Locations.begin_consent/2` accepts.
  """
  @spec open?(struct(), DateTime.t()) :: boolean()
  def open?(%{status: status, ends_at: ends_at}, %DateTime{} = at),
    do:
      status in [:PLANNED, :ACTIVE] and (is_nil(ends_at) or DateTime.compare(ends_at, at) == :gt)

  code_interface do
    define :plan
    define :active
    define :for_operator, args: [:operator_participant_id]
    define :activate
    define :complete
  end
end
