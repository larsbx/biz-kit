defmodule Dispatch.Operations.ParticipantStatusEvent do
  @moduledoc """
  A participant's declaration of their own operational status (Sections 5.2, 22.3).

  This is the resource Section 1's central distinction rests on. A status here
  is a **driver declaration**, not an observed fact, an external notice, or an
  AI inference. Section 5.2 permits only `source=PARTICIPANT` holding
  `status.declare.self` to update the displayed status; a geofence or an agent
  runtime may produce a suggestion such as "arrival likely", but the suggestion
  stays separate until the participant confirms it.

  Append-only. Section 5.1 lets a driver correct or supersede a status at any
  time, and Section 12 makes a correction a new event that references what it
  supersedes — never a rewrite. The resource therefore has no update or destroy
  action at all: one that existed but was policy-denied would still be a
  refactor away from being allowed, and the immutability is the product
  requirement rather than a permission setting.

  `(device_id, device_sequence)` is unique, which is what makes Section 14's
  offline outbox safe. A handset that uploads, loses the response and retries
  must not produce two declarations; the second write resolves to the first
  (Section 24.1 returns the original `201` body for a duplicate with the same
  content).
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Dispatch.Access.Checks.{ActingOnSelf, HasCapability, OwnRecords}
  alias Dispatch.Operations.Status

  postgres do
    table "participant_status_events"
    repo Dispatch.Repo

    # Partial: a declaration made from the portal carries no device, and NULLs
    # would otherwise collide under a total index.
    identity_wheres_to_sql unique_device_sequence:
                             "device_id IS NOT NULL AND device_sequence IS NOT NULL"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :participant_id, :uuid, allow_nil?: false, public?: true
    attribute :role_assignment_id, :uuid, allow_nil?: false, public?: true
    attribute :assignment_id, :uuid, public?: true

    attribute :status, :atom do
      constraints one_of: Status.all()
      allow_nil? false
      public? true
    end

    attribute :occurred_at, :utc_datetime_usec do
      description "When the participant says it happened."
      allow_nil? false
      public? true
    end

    attribute :recorded_at, :utc_datetime_usec do
      description """
      When the server stored it. Distinct from `occurred_at` because Section 4.2
      shows declaration time and age, and an event created offline may arrive
      much later — collapsing the two would make a stale declaration look fresh.
      """

      allow_nil? false
      public? true
    end

    attribute :source, :atom do
      constraints one_of: [:PARTICIPANT]
      default :PARTICIPANT
      allow_nil? false
      public? true
    end

    attribute :note, :string do
      constraints max_length: 1_000
      public? true
    end

    attribute :location_sample_id, :uuid, public?: true

    attribute :verification, :atom do
      constraints one_of: [:NONE, :DEVICE_AUTHENTICATED, :SYSTEM_BIOMETRIC, :FACE_1_TO_1]
      default :NONE
      allow_nil? false
      public? true
    end

    attribute :supersedes_event_id, :uuid do
      description "The event this correction replaces. History is appended, never rewritten."
      public? true
    end

    attribute :device_id, :uuid, public?: true
    attribute :device_sequence, :integer, public?: true
    attribute :correlation_id, :string, public?: true

    create_timestamp :created_at
  end

  identities do
    # Section 22.3 names the pair `(device_id, device_sequence)` unqualified. A
    # device belongs to one tenant and `devices.installation_id` is already
    # globally unique, so scoping this to a tenant would add nothing while
    # leaving the stated constraint weaker than written.
    #
    # Partial, because a status declared from the portal carries no device.
    identity :unique_device_sequence, [:device_id, :device_sequence],
      where: expr(not is_nil(device_id) and not is_nil(device_sequence)),
      all_tenants?: true
  end

  validations do
    validate {Dispatch.Operations.Validations.StatusDeclaration, []}
  end

  actions do
    defaults [:read]

    create :declare do
      description """
      Records a declaration. Section 5.2 restricts this to the participant
      themselves; the policies below enforce that rather than a controller.
      """

      accept [
        :tenant_id,
        :participant_id,
        :role_assignment_id,
        :assignment_id,
        :status,
        :occurred_at,
        :note,
        :location_sample_id,
        :verification,
        :supersedes_event_id,
        :device_id,
        :device_sequence,
        :correlation_id
      ]

      change set_attribute(:source, :PARTICIPANT)
      change set_attribute(:recorded_at, &DateTime.utc_now/0)
    end

    read :history do
      description "A participant's declarations, newest first."
      argument :participant_id, :uuid, allow_nil?: false

      filter expr(participant_id == ^arg(:participant_id))
      prepare build(sort: [occurred_at: :desc, created_at: :desc])
    end

    read :current do
      description """
      The latest declaration for a participant.

      Section 4.2 shows this as the current status card with its declaration
      time and age. "Latest" is by `occurred_at`, not arrival: an event created
      offline at 09:00 and uploaded at 11:00 did not supersede one declared at
      10:00.
      """

      argument :participant_id, :uuid, allow_nil?: false
      get? true

      filter expr(participant_id == ^arg(:participant_id))
      prepare build(sort: [occurred_at: :desc, created_at: :desc], limit: 1)
    end
  end

  policies do
    # Section 5.2: only source=PARTICIPANT holding status.declare.self may
    # update the displayed self-declared status, and Section 23.2 attaches
    # `self_only` to that capability.
    policy action(:declare) do
      # Both must hold. The capability alone would let any holder declare a
      # status about anyone; `self_only` is what makes it a declaration.
      forbid_unless HasCapability.of("status.declare.self")
      authorize_if ActingOnSelf.on(:participant_id)
    end

    # Section 4.1 and 6.3: a driver reads their own history. Operations reads
    # for a dispatcher arrive with the surfaces that need them.
    policy action_type(:read) do
      # A dispatcher reads across the roster; Section 23.2 gives them
      # `operations.participant.read` and Section 23.3 narrows the rows by
      # carrier and assignment relationship in the surfaces that use it.
      authorize_if HasCapability.of("operations.participant.read")

      # Otherwise the actor may read only their own declarations, and the
      # restriction is a filter rather than a verdict.
      forbid_unless HasCapability.of("communications.read.self")
      authorize_if OwnRecords.on(:participant_id)
    end
  end

  code_interface do
    define :declare
    define :history, args: [:participant_id]
    define :current, args: [:participant_id]
  end
end
