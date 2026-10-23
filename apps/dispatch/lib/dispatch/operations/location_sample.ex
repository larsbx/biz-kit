defmodule Dispatch.Operations.LocationSample do
  @moduledoc """
  One position a participant's device acquired and uploaded under a consent
  grant (Sections 6.1, 22.3, 24.2).

  An observation, not a declaration (Section 1): it records where the device
  said it was, with its accuracy, age, provider and mock flag, and the portal
  always shows the accuracy and age with it. Append-only.

  `position` is `geography(Point,4326)` (Section 28.2). `(device_id,
  device_sequence)` is unique, so a batch retried after a lost response
  resolves to the samples already stored rather than to copies.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Dispatch.Access.Checks.{ActingOnSelf, HasCapability, OwnRecords}

  # Section 25.3: stored and uploaded, but marked low accuracy above this.
  @low_accuracy_m 250

  postgres do
    table "location_samples"
    repo Dispatch.Repo

    custom_indexes do
      # Without tenant_id: GIST has no operator class for uuid, and the
      # tenant is filtered by the query either way.
      index [:position], using: "GIST", all_tenants?: true
      index [:participant_id, :occurred_at]
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    # Client-assigned (`sample_id`), so an outbox can reconcile by it.
    uuid_v7_primary_key :id, writable?: true

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :participant_id, :uuid, allow_nil?: false, public?: true
    attribute :role_assignment_id, :uuid, allow_nil?: false, public?: true
    attribute :assignment_id, :uuid, allow_nil?: false, public?: true
    attribute :position, Dispatch.Geo.Types.Point, allow_nil?: false, public?: true

    attribute :accuracy_m, :float do
      constraints min: 0
      allow_nil? false
      public? true
    end

    attribute :speed_mps, :float, public?: true
    attribute :bearing_deg, :float, constraints: [min: 0, max: 360], public?: true

    attribute :provider, :string do
      constraints max_length: 32
      allow_nil? false
      public? true
    end

    attribute :is_mock, :boolean, default: false, allow_nil?: false, public?: true
    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :received_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :device_id, :uuid, allow_nil?: false, public?: true
    attribute :device_sequence, :integer, allow_nil?: false, public?: true
    attribute :consent_grant_id, :uuid, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_device_sequence, [:device_id, :device_sequence], all_tenants?: true
  end

  actions do
    defaults [:read]

    create :ingest_location_sample do
      accept [
        :id,
        :tenant_id,
        :participant_id,
        :role_assignment_id,
        :assignment_id,
        :position,
        :accuracy_m,
        :speed_mps,
        :bearing_deg,
        :provider,
        :is_mock,
        :occurred_at,
        :device_id,
        :device_sequence,
        :consent_grant_id
      ]

      change set_attribute(:received_at, &DateTime.utc_now/0)
    end

    read :latest do
      description "A participant's most recently acquired sample (by acquisition, not arrival)."
      argument :participant_id, :uuid, allow_nil?: false
      get? true
      filter expr(participant_id == ^arg(:participant_id))
      prepare build(sort: [occurred_at: :desc, received_at: :desc], limit: 1)
    end
  end

  policies do
    policy action(:ingest_location_sample) do
      forbid_unless HasCapability.of("location.share.self")
      authorize_if ActingOnSelf.on(:participant_id)
    end

    # Section 6.3: the participant reads their own; an operations reader reads
    # the roster's, and what of a sample a page shows is the view model's.
    policy action_type(:read) do
      authorize_if HasCapability.of("operations.participant.read")
      forbid_unless HasCapability.of("location.share.self")
      authorize_if OwnRecords.on(:participant_id)
    end
  end

  code_interface do
    define :latest, args: [:participant_id]
  end

  @doc "Section 25.3's low-accuracy mark."
  @spec low_accuracy?(%{accuracy_m: number()}) :: boolean()
  def low_accuracy?(%{accuracy_m: accuracy}), do: accuracy > @low_accuracy_m
end
