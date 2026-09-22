defmodule EatsbotCore.Marketing.Visit do
  @moduledoc """
  A customer's check-in at the counter via a touchpoint, and its redemption.

      check_in ──▶ :checked_in ──redeem(code, amount)──▶ :redeemed

  `check_in` decides attribution once (see `EatsbotCore.Marketing.Attribution`)
  and snapshots the commission rate; `redeem` books the bill amount and the
  resulting commission. The short `code` is what the customer shows the cashier.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Marketing,
    extensions: [AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    fragments: [EatsbotCore.Marketing.Policies]

  alias EatsbotCore.Marketing
  alias EatsbotCore.Marketing.Attribution

  require Ash.Query
  require Ash.Expr

  admin do
  end

  postgres do
    table "marketing_visits"
    repo Eatsbot.Repo

    references do
      reference :subscriber, on_delete: :delete
      reference :touchpoint, on_delete: :delete
      reference :promotion, on_delete: :nilify
    end
  end

  code_interface do
    define :check_in, args: [:touchpoint_code, :channel, :address]
    define :open_by_code, args: [:code], get?: true
    define :redeem, args: [:code, :amount]
    define :statement, args: [:branch_id, :from, :to]
  end

  actions do
    defaults [:read]

    create :check_in do
      argument :touchpoint_code, :string, allow_nil?: false
      argument :channel, :atom, allow_nil?: false
      argument :address, :string, allow_nil?: false

      change Marketing.Visit.CheckIn
    end

    read :open_by_code do
      argument :code, :string, allow_nil?: false

      prepare fn query, _context ->
        cutoff = DateTime.add(DateTime.utc_now(), -Marketing.redemption_window())

        Ash.Query.filter(
          query,
          code == ^query.arguments.code and status == :checked_in and checked_in_at >= ^cutoff
        )
      end
    end

    update :record_redemption do
      require_atomic? false
      argument :amount, :money, allow_nil?: false

      validate fn changeset, _context ->
        if Attribution.redeemable?(
             changeset.data,
             DateTime.utc_now(),
             Marketing.redemption_window()
           ),
           do: :ok,
           else: {:error, field: :code, message: "is not redeemable"}
      end

      change fn %{arguments: %{amount: amount}, data: visit} = changeset, _context ->
        changeset
        # guards against concurrent double redemption
        |> Ash.Changeset.filter(Ash.Expr.expr(status == :checked_in))
        |> Ash.Changeset.force_change_attributes(
          status: :redeemed,
          redeemed_at: DateTime.utc_now(),
          amount: amount,
          commission: Attribution.commission(amount, visit.commission_rate)
        )
      end
    end

    action :redeem, :struct do
      constraints instance_of: __MODULE__
      argument :code, :string, allow_nil?: false
      argument :amount, :money, allow_nil?: false

      run fn %{arguments: %{code: code, amount: amount}}, context ->
        opts = Ash.Context.to_opts(context)

        with {:ok, visit} <- open_by_code(String.upcase(code), opts) do
          Ash.update(visit, %{amount: amount}, Keyword.put(opts, :action, :record_redemption))
        end
      end
    end

    action :statement, :map do
      description "Commission owed to the service per currency, for redemptions in [from, to)."
      argument :branch_id, :uuid, allow_nil?: false
      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false

      run fn %{arguments: %{branch_id: branch_id, from: from, to: to}}, context ->
        __MODULE__
        |> Ash.Query.filter(
          touchpoint.branch_id == ^branch_id and status == :redeemed and
            redeemed_at >= ^from and redeemed_at < ^to
        )
        |> Ash.read(Ash.Context.to_opts(context))
        |> case do
          {:ok, visits} -> {:ok, Attribution.statement(visits)}
          error -> error
        end
      end
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :code, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :checked_in
      constraints one_of: [:checked_in, :redeemed]
    end

    attribute :attributed?, :boolean, allow_nil?: false, public?: true, default: false

    attribute :commission_rate, :decimal do
      allow_nil? false
      public? true
      default Decimal.new(0)
      constraints min: 0, max: 1
    end

    attribute :checked_in_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :redeemed_at, :utc_datetime_usec, public?: true
    attribute :amount, :money, public?: true
    attribute :commission, :money, public?: true

    timestamps()
  end

  relationships do
    belongs_to :subscriber, Marketing.Subscriber, allow_nil?: false, public?: true
    belongs_to :touchpoint, Marketing.Touchpoint, allow_nil?: false, public?: true
    belongs_to :promotion, Marketing.Promotion, public?: true
  end
end
