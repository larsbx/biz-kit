defmodule Dispatch.Fleet.StopParty do
  @moduledoc """
  An organization's relationship to one stop (Section 22.2).

  The stop-level mirror of `LoadParty`, and the reason a shipper sees one pickup
  rather than a load. Acceptance criteria 16 and 17 scope a shipper and a
  receiver to *their* stop: Section 4.3 keeps the full driver timeline, the
  continuous route trace, unrelated stops, negotiated rate, internal carrier
  notes, and other parties' communications off those surfaces entirely.

  `FACILITY` exists separately from `SHIPPER` and `RECEIVER` because a yard or
  warehouse operator may need stop access without being the commercial
  counterparty for the freight.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "stop_parties"
    repo Dispatch.Repo

    identity_wheres_to_sql unique_active_relationship: "status = 'ACTIVE'"
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :stop_id, :uuid, allow_nil?: false, public?: true
    attribute :organization_id, :uuid, allow_nil?: false, public?: true

    attribute :relationship, :atom do
      constraints one_of: [:SHIPPER, :RECEIVER, :FACILITY]
      allow_nil? false
      public? true
    end

    attribute :starts_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :ends_at, :utc_datetime_usec, public?: true

    attribute :status, :atom do
      constraints one_of: [:ACTIVE, :ENDED]
      default :ACTIVE
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
    attribute :version, :integer, default: 0, allow_nil?: false
  end

  identities do
    identity :unique_active_relationship, [:stop_id, :organization_id, :relationship],
      where: expr(status == :ACTIVE)
  end

  relationships do
    belongs_to :stop, Dispatch.Fleet.Stop do
      source_attribute :stop_id
      attribute_writable? true
    end

    belongs_to :organization, Dispatch.Accounts.Organization do
      source_attribute :organization_id
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :add do
      accept [:tenant_id, :stop_id, :organization_id, :relationship, :starts_at, :ends_at]
      change set_attribute(:status, :ACTIVE)
    end

    read :active do
      argument :at, :utc_datetime_usec, default: &DateTime.utc_now/0

      filter expr(
               status == :ACTIVE and starts_at <= ^arg(:at) and
                 (is_nil(ends_at) or ends_at > ^arg(:at))
             )
    end

    read :for_stop do
      argument :stop_id, :uuid, allow_nil?: false
      argument :at, :utc_datetime_usec, default: &DateTime.utc_now/0

      filter expr(
               stop_id == ^arg(:stop_id) and status == :ACTIVE and starts_at <= ^arg(:at) and
                 (is_nil(ends_at) or ends_at > ^arg(:at))
             )
    end

    update :end_relationship do
      accept []
      require_atomic? false
      argument :expected_version, :integer

      change set_attribute(:status, :ENDED)
      change set_attribute(:ends_at, &DateTime.utc_now/0)
      change Dispatch.Accounts.Changes.IncrementVersion
    end
  end

  code_interface do
    define :add
    define :active
    define :for_stop, args: [:stop_id]
    define :end_relationship
  end
end
