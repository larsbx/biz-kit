defmodule EatsbotCore.Marketing.Subscriber do
  @moduledoc """
  A customer who opted in to a branch's promotions on a channel, by scanning
  its touchpoint. `/stop` (see `unsubscribe_all`) opts out.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Marketing,
    extensions: [AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    fragments: [EatsbotCore.Marketing.Policies]

  require Ash.Query

  admin do
  end

  postgres do
    table "marketing_subscribers"
    repo Eatsbot.Repo

    foreign_key_names [
      {:id, "marketing_visits_subscriber_id_fkey", "has visits (the commission ledger)"}
    ]

    references do
      reference :branch, on_delete: :delete
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :channel, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:telegram]
    end

    attribute :address, :string do
      description "Channel-specific recipient, e.g. the Telegram chat id."
      allow_nil? false
      public? true
      sensitive? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :subscribed
      constraints one_of: [:subscribed, :unsubscribed]
    end

    attribute :last_notified_at, :utc_datetime_usec, public?: true

    timestamps()
  end

  relationships do
    belongs_to :branch, EatsbotCore.Brands.Branch, allow_nil?: false, public?: true
    has_many :visits, EatsbotCore.Marketing.Visit, public?: true
  end

  actions do
    defaults [:read, :destroy]

    create :subscribe do
      accept [:channel, :address, :branch_id]
      upsert? true
      upsert_identity :unique_address_per_branch
      upsert_fields [:status, :updated_at]
      change set_attribute(:status, :subscribed)
    end

    update :mark_notified do
      argument :at, :utc_datetime_usec, allow_nil?: false
      change set_attribute(:last_notified_at, arg(:at))
    end

    update :unsubscribe do
      change set_attribute(:status, :unsubscribed)
    end

    read :subscribed_to_branch do
      argument :branch_id, :uuid, allow_nil?: false
      filter expr(branch_id == ^arg(:branch_id) and status == :subscribed)
    end

    action :unsubscribe_all do
      argument :channel, :atom, allow_nil?: false
      argument :address, :string, allow_nil?: false

      run fn %{arguments: %{channel: channel, address: address}}, context ->
        __MODULE__
        |> Ash.Query.filter(channel == ^channel and address == ^address)
        |> Ash.bulk_update!(:unsubscribe, %{},
          strategy: [:atomic, :stream],
          actor: context.actor
        )

        :ok
      end
    end
  end

  code_interface do
    define :subscribe
    define :subscribed_to_branch, args: [:branch_id]
    define :unsubscribe_all, args: [:channel, :address]
  end

  identities do
    identity :unique_address_per_branch, [:channel, :address, :branch_id]
  end

  aggregates do
    max :last_attributed_at, :visits, :checked_in_at do
      filter expr(attributed?)
    end
  end
end
