defmodule EatsbotCore.Marketing.Promotion do
  @moduledoc """
  A time-boxed offer at a branch (e.g. "free churro with any order").

  `announce` stamps every subscribed customer of the branch as notified — the
  premise for attributing their next check-in — and publishes
  `promotion:announced` for channel adapters (e.g. Telegram) to deliver.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Marketing,
    extensions: [AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    notifiers: [Ash.Notifier.PubSub],
    fragments: [EatsbotCore.Marketing.Policies]

  require Ash.Query
  alias EatsbotCore.Marketing.Subscriber

  admin do
  end

  postgres do
    table "marketing_promotions"
    repo Eatsbot.Repo

    references do
      reference :branch, on_delete: :delete
    end
  end

  code_interface do
    define :create
    define :announce
    define :active_for_branch, args: [:branch_id], get?: true
  end

  actions do
    defaults [:read, :destroy, create: [:branch_id, :title, :body, :starts_at, :ends_at]]

    update :update do
      primary? true
      accept [:title, :body, :starts_at, :ends_at]
    end

    update :announce do
      require_atomic? false
      change set_attribute(:announced_at, &DateTime.utc_now/0)

      change after_action(fn _changeset, promotion, context ->
               Subscriber
               |> Ash.Query.filter(branch_id == ^promotion.branch_id and status == :subscribed)
               |> Ash.bulk_update!(:mark_notified, %{at: promotion.announced_at},
                 strategy: [:atomic, :stream],
                 actor: context.actor
               )

               {:ok, promotion}
             end)
    end

    read :active_for_branch do
      argument :branch_id, :uuid, allow_nil?: false

      filter expr(
               branch_id == ^arg(:branch_id) and starts_at <= now() and
                 (is_nil(ends_at) or ends_at > now())
             )

      prepare build(sort: [starts_at: :desc], limit: 1)
    end
  end

  pub_sub do
    module EatsbotWeb.Endpoint
    prefix "promotion"
    publish :announce, ["announced"]
  end

  validations do
    validate compare(:ends_at, greater_than: :starts_at),
      where: [present([:starts_at, :ends_at])],
      message: "must end after it starts"
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :title, :string, allow_nil?: false, public?: true
    attribute :body, :string, allow_nil?: false, public?: true

    attribute :starts_at, :utc_datetime_usec do
      allow_nil? false
      public? true
      default &DateTime.utc_now/0
    end

    attribute :ends_at, :utc_datetime_usec, public?: true
    attribute :announced_at, :utc_datetime_usec, public?: true, writable?: false

    timestamps()
  end

  relationships do
    belongs_to :branch, EatsbotCore.Brands.Branch, allow_nil?: false, public?: true
  end
end
