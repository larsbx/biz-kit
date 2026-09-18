defmodule Dispatch.Accounts.Device do
  @moduledoc """
  A registered installation of the field application (Section 22.1).

  `last_sequence` is the server's view of the device's monotonic counter.
  Section 14 requires Android to store unsent events locally and sync with a
  per-device sequence, and Section 22.3 makes `(device_id, device_sequence)` the
  idempotency key for status and location ingestion — so a retried upload after
  a dropped response resolves to the original event rather than a duplicate.

  `public_key` is registered after interactive login (Section 23.1) and verifies
  the signature on offline-created events. Section 7.2 keeps biometric material
  off the server entirely; nothing here is biometric.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Accounts,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "devices"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :participant_id, :uuid, allow_nil?: false, public?: true

    attribute :installation_id, :string do
      description "Stable per-installation identifier. Unique across all tenants."
      allow_nil? false
      public? true
    end

    attribute :public_key, :string do
      description "Registered after interactive login; verifies offline event signatures."
      allow_nil? false
      public? true
    end

    attribute :last_sequence, :integer do
      description "Highest accepted device_sequence. Never decreases."
      default 0
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :REVOKED, :LOST]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    attribute :last_seen_at, :utc_datetime_usec, public?: true

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    # Section 22.1 lists `devices.installation_id` unqualified, and in the same
    # list qualifies `contacts.phone_e164` as "within a tenant". The contrast is
    # deliberate: an installation is one physical app on one handset, so it must
    # not be registrable under two tenants at once. `all_tenants?` is what makes
    # the index global rather than per-tenant, which attribute multitenancy
    # would otherwise make it.
    identity :unique_installation, [:installation_id], all_tenants?: true
  end

  relationships do
    belongs_to :participant, Dispatch.Accounts.Participant do
      source_attribute :participant_id
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :register do
      accept [:tenant_id, :participant_id, :installation_id, :public_key]
    end

    read :active do
      filter expr(status == :ACTIVE)
    end

    update :revoke do
      description "Lost-device handling (Section 13). Revocation is not reversible; re-register instead."
      accept []
      require_atomic? false
      argument :expected_version, :integer
      change set_attribute(:status, :REVOKED)
      change Dispatch.Accounts.Changes.IncrementVersion
    end

    update :record_sequence do
      description "Advances the accepted sequence. Monotonic: a replayed lower value is ignored."
      accept [:last_sequence]
      require_atomic? false

      validate fn changeset, _context ->
        current = Ash.Changeset.get_data(changeset, :last_sequence) || 0
        proposed = Ash.Changeset.get_attribute(changeset, :last_sequence)

        if is_integer(proposed) and proposed > current do
          :ok
        else
          {:error, field: :last_sequence, message: "must increase monotonically"}
        end
      end

      change set_attribute(:last_seen_at, &DateTime.utc_now/0)
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :register
    define :active
    define :revoke
  end
end
