defmodule Dispatch.Fleet.AssignmentContact do
  @moduledoc """
  A contact reachable in connection with one assignment (Section 22.2).

  Section 22.2 is explicit that this grants nothing: "a contact record, phone
  number, email address, organization kind, or caller claim never grants access
  by itself." An inbound call from a number listed here is still resolved
  against role assignments and party relationships before anything is disclosed
  (Section 27.3), and an unrecognised caller receives only public or minimal
  information.

  What it is for is the reverse direction — knowing which thread an inbound
  message belongs to (Section 8.5), and who an outbound `CallPlan` may name.
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Fleet,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "assignment_contacts"
    repo Dispatch.Repo
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :assignment_id, :uuid, allow_nil?: false, public?: true
    attribute :contact_id, :uuid, allow_nil?: false, public?: true

    attribute :relationship, :atom do
      constraints one_of: [:BROKER, :DISPATCHER, :SHIPPER, :RECEIVER, :OTHER]
      allow_nil? false
      public? true
    end

    create_timestamp :created_at
    update_timestamp :updated_at
  end

  identities do
    identity :unique_contact_relationship, [:assignment_id, :contact_id, :relationship]
  end

  relationships do
    belongs_to :assignment, Dispatch.Fleet.Assignment do
      source_attribute :assignment_id
      attribute_writable? true
    end

    belongs_to :contact, Dispatch.Accounts.Contact do
      source_attribute :contact_id
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    create :attach do
      accept [:tenant_id, :assignment_id, :contact_id, :relationship]
    end

    read :for_assignment do
      argument :assignment_id, :uuid, allow_nil?: false
      filter expr(assignment_id == ^arg(:assignment_id))
    end
  end

  code_interface do
    define :attach
    define :for_assignment, args: [:assignment_id]
  end
end
