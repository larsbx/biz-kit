defmodule EatsbotCore.MarketingTest do
  use Eatsbot.DataCase, async: true

  alias EatsbotCore.Brands.{Brand, Branch}
  alias EatsbotCore.Deliveries.Actors
  alias EatsbotCore.Marketing.{Promotion, Subscriber, Touchpoint, Visit}

  @actor Actors.private()

  setup do
    brand = Brand.create!(%{name: "Taquería"}, authorize?: false)

    branch =
      Branch.create!(
        %{name: "Centro", address: "Calle 1", latitude: 0.0, longitude: 0.0, brand_id: brand.id},
        authorize?: false
      )

    touchpoint =
      Touchpoint.create!(
        %{branch_id: branch.id, label: "Counter", commission_rate: Decimal.new("0.10")},
        actor: @actor
      )

    promotion =
      Promotion.create!(
        %{
          branch_id: branch.id,
          title: "Free churro",
          body: "Get a free churro with any order today.",
          starts_at: DateTime.add(DateTime.utc_now(), -3600),
          ends_at: DateTime.add(DateTime.utc_now(), 3600)
        },
        actor: @actor
      )

    {:ok, branch: branch, touchpoint: touchpoint, promotion: promotion}
  end

  defp check_in(touchpoint, address \\ "42"),
    do: Visit.check_in!(touchpoint.code, :telegram, address, actor: @actor)

  describe "touchpoint" do
    test "gets a unique deep-link-safe code and a sticker URL", %{touchpoint: touchpoint} do
      assert touchpoint.code =~ ~r/\A[0-9A-Z]{8}\z/
      assert Touchpoint.url(touchpoint) =~ ~r{/t/#{touchpoint.code}\z}
      assert Touchpoint.by_code!(touchpoint.code, actor: @actor).id == touchpoint.id
    end
  end

  describe "check-in" do
    test "a first scan subscribes the customer but is not attributed",
         %{touchpoint: touchpoint, promotion: promotion} do
      visit = check_in(touchpoint)

      refute visit.attributed?
      assert Decimal.equal?(visit.commission_rate, 0)
      assert visit.promotion_id == promotion.id
      assert visit.code =~ ~r/\A[0-9A-Z]{6}\z/

      assert [%{status: :subscribed, address: "42"}] = Ash.read!(Subscriber, actor: @actor)
    end

    test "a scan after a promotion was announced is attributed at the touchpoint's rate",
         %{touchpoint: touchpoint, promotion: promotion} do
      check_in(touchpoint)
      Promotion.announce!(promotion, actor: @actor)

      visit = check_in(touchpoint)

      assert visit.attributed?
      assert Decimal.equal?(visit.commission_rate, touchpoint.commission_rate)
    end

    test "one announcement credits at most one visit",
         %{touchpoint: touchpoint, promotion: promotion} do
      check_in(touchpoint)
      Promotion.announce!(promotion, actor: @actor)

      assert check_in(touchpoint).attributed?
      refute check_in(touchpoint).attributed?
    end

    test "unknown touchpoint codes are rejected" do
      assert {:error, _} = Visit.check_in("NOPE0000", :telegram, "42", actor: @actor)
    end
  end

  describe "announce" do
    test "stamps announced_at and notifies only subscribed customers",
         %{touchpoint: touchpoint, promotion: promotion} do
      check_in(touchpoint, "1")
      check_in(touchpoint, "2")
      Subscriber.unsubscribe_all!(:telegram, "2", actor: @actor)

      promotion = Promotion.announce!(promotion, actor: @actor)
      assert promotion.announced_at

      notified =
        Subscriber
        |> Ash.read!(actor: @actor)
        |> Map.new(&{&1.address, &1.last_notified_at})

      assert %{"1" => %DateTime{}, "2" => nil} = notified
    end

    test "publishes promotion:announced for channel adapters", %{promotion: promotion} do
      Phoenix.PubSub.subscribe(Eatsbot.PubSub, "promotion:announced")
      Promotion.announce!(promotion, actor: @actor)

      assert_receive %{topic: "promotion:announced", payload: %{data: %{id: id}}}
      assert id == promotion.id
    end

    test "active promotions exclude expired ones", %{branch: branch, promotion: promotion} do
      Promotion.create!(
        %{
          branch_id: branch.id,
          title: "Old",
          body: "Expired",
          starts_at: DateTime.add(DateTime.utc_now(), -7200),
          ends_at: DateTime.add(DateTime.utc_now(), -3600)
        },
        actor: @actor
      )

      assert Promotion.active_for_branch!(branch.id, actor: @actor).id == promotion.id
    end
  end

  describe "redeem" do
    test "books the bill amount and the commission for an attributed visit",
         %{touchpoint: touchpoint, promotion: promotion} do
      check_in(touchpoint)
      Promotion.announce!(promotion, actor: @actor)
      %{code: code} = check_in(touchpoint)

      visit = Visit.redeem!(code, Money.new!(:CLP, 20_000), actor: @actor)

      assert visit.status == :redeemed
      assert visit.redeemed_at
      assert Money.equal?(visit.amount, Money.new!(:CLP, 20_000))
      assert Money.equal?(visit.commission, Money.new!(:CLP, 2_000))
    end

    test "a non-attributed visit is redeemable at zero commission", %{touchpoint: touchpoint} do
      %{code: code} = check_in(touchpoint)

      assert Money.zero?(Visit.redeem!(code, Money.new!(:CLP, 5_000), actor: @actor).commission)
    end

    test "a code can be redeemed once", %{touchpoint: touchpoint} do
      %{code: code} = check_in(touchpoint)
      Visit.redeem!(code, Money.new!(:CLP, 1_000), actor: @actor)

      assert {:error, _} = Visit.redeem(code, Money.new!(:CLP, 1_000), actor: @actor)
    end

    test "statement sums commission per currency for a branch",
         %{branch: branch, touchpoint: touchpoint, promotion: promotion} do
      for address <- ["1", "2"] do
        check_in(touchpoint, address)
      end

      Promotion.announce!(promotion, actor: @actor)

      for {address, amount} <- [{"1", 10_000}, {"2", 30_000}] do
        %{code: code} = check_in(touchpoint, address)
        Visit.redeem!(code, Money.new!(:CLP, amount), actor: @actor)
      end

      from = DateTime.add(DateTime.utc_now(), -86_400)
      to = DateTime.add(DateTime.utc_now(), 60)

      assert %{CLP: total} = Visit.statement!(branch.id, from, to, actor: @actor)
      assert Money.equal?(total, Money.new!(:CLP, 4_000))
    end
  end

  describe "authorization" do
    test "the public cannot read subscribers or visits", %{touchpoint: touchpoint} do
      check_in(touchpoint)

      assert [] = Ash.read!(Subscriber, actor: Actors.public())
      assert [] = Ash.read!(Visit, actor: Actors.public())
      assert [] = Ash.read!(Subscriber)
    end
  end
end
