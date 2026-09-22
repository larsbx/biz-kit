defmodule EatsbotCore.Marketing.Touchpoint do
  @moduledoc """
  An NFC tag and/or QR sticker placed at a branch's checkout counter.

  The sticker encodes `url/1` (`/t/:code`), which redirects to the Telegram bot
  deep link `t.me/<bot>?start=v_<code>`: Telegram identifies the customer, the
  bot records a `Visit`.

  The touchpoint carries the agreed `commission_rate`; visits snapshot it at
  check-in so later renegotiations don't rewrite history.
  """
  use Ash.Resource,
    otp_app: :eatsbot,
    domain: EatsbotCore.Marketing,
    extensions: [AshAdmin.Resource],
    data_layer: AshPostgres.DataLayer,
    fragments: [EatsbotCore.Marketing.Policies]

  admin do
  end

  postgres do
    table "marketing_touchpoints"
    repo Eatsbot.Repo

    references do
      reference :branch, on_delete: :delete
    end
  end

  code_interface do
    define :create
    define :by_code, args: [:code], get?: true
  end

  actions do
    defaults [:read, :destroy, create: [:branch_id, :label, :kind, :commission_rate]]

    update :update do
      primary? true
      accept [:label, :kind, :commission_rate]
    end

    read :by_code do
      argument :code, :string, allow_nil?: false
      filter expr(code == ^arg(:code))
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :code, :string do
      allow_nil? false
      public? true
      writable? false
      default {EatsbotCore.Marketing.Attribution, :code, [8]}
    end

    attribute :label, :string, public?: true

    attribute :kind, :atom do
      allow_nil? false
      public? true
      default :nfc_qr
      constraints one_of: [:nfc, :qr, :nfc_qr]
    end

    attribute :commission_rate, :decimal do
      allow_nil? false
      public? true
      default {EatsbotCore.Marketing, :default_commission_rate, []}
      constraints min: 0, max: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :branch, EatsbotCore.Brands.Branch, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_code, [:code]
  end

  @doc "The URL to encode on the NFC tag / QR sticker."
  def url(%{code: code}), do: EatsbotCore.Marketing.config(:public_url) <> "/t/" <> code
end
