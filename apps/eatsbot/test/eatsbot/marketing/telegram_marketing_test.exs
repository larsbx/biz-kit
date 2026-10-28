defmodule Eatsbot.Extensions.TelegramBot.MarketingTest do
  use EatsbotWeb.ConnCase, async: false

  alias Eatsbot.Extensions.TelegramBot.{CheckIn, Redeem}
  alias Eatsbot.Extensions.TelegramBot.Marketing, as: Texts
  alias EatsbotCore.Brands.{Brand, Branch}
  alias EatsbotCore.Deliveries.Actors
  alias EatsbotCore.Marketing.{Promotion, Subscriber, Touchpoint, Visit}

  @actor Actors.private()
  @customer 1001
  @cashier 2002

  setup do
    brand = Brand.create!(%{name: "Taquería"}, authorize?: false)

    branch =
      Branch.create!(
        %{name: "Centro", address: "Calle 1", latitude: 0.0, longitude: 0.0, brand_id: brand.id},
        authorize?: false
      )

    touchpoint = Touchpoint.create!(%{branch_id: branch.id}, actor: @actor)
    {:ok, branch: branch, touchpoint: touchpoint}
  end

  defp update(from, text) do
    Telegex.Helper.typedmap(
      %{
        update_id: 1,
        message: %{
          message_id: 1,
          date: 0,
          text: text,
          chat: %{id: from, type: "private"},
          from: %{id: from, is_bot: false, first_name: "Ana"}
        }
      },
      Telegex.Type.Update
    )
  end

  defp context, do: %Eatsbot.Extensions.TelegramBot.ChainContext{bot: nil}

  defp reply({:done, %{payload: %{text: text, chat_id: chat_id}}}), do: {chat_id, text}

  describe "customer check-in via sticker deep link" do
    test "subscribes, records a visit and replies with the promotion and code",
         %{branch: branch, touchpoint: touchpoint} do
      Promotion.create!(
        %{branch_id: branch.id, title: "Free churro", body: "With any order (today!)"},
        actor: @actor
      )

      {chat_id, text} =
        CheckIn.call(update(@customer, "/start v_#{touchpoint.code}"), context()) |> reply()

      assert chat_id == @customer
      assert [%{code: code}] = Ash.read!(Visit, actor: @actor)
      assert text =~ "Free churro"
      assert text =~ "With any order (today!)"
      assert text =~ code
    end

    test "without an active promotion it still issues a visit code", %{touchpoint: touchpoint} do
      {_, text} =
        CheckIn.call(update(@customer, "/start v_#{touchpoint.code}"), context()) |> reply()

      assert [%{code: code}] = Ash.read!(Visit, actor: @actor)
      assert text =~ code
    end

    test "an unknown sticker gets an apology, not a crash" do
      {_, text} = CheckIn.call(update(@customer, "/start v_ZZZZZZZZ"), context()) |> reply()
      assert text == Texts.invalid_touchpoint()
    end

    test "/stop unsubscribes from every branch", %{touchpoint: touchpoint} do
      CheckIn.call(update(@customer, "/start v_#{touchpoint.code}"), context())
      CheckIn.call(update(@customer, "/stop"), context())

      assert [%{status: :unsubscribed}] = Ash.read!(Subscriber, actor: @actor)
    end

    test "other messages pass through to the rest of the chain" do
      assert {:ok, _} = CheckIn.call(update(@customer, "/new"), context())
      assert {:ok, _} = CheckIn.call(update(@customer, "/start"), context())
    end
  end

  describe "staff /redeem" do
    test "books the amount and confirms", %{touchpoint: touchpoint} do
      %{code: code} = Visit.check_in!(touchpoint.code, :telegram, "#{@customer}", actor: @actor)

      {chat_id, text} =
        Redeem.call(update(@cashier, "/redeem #{String.downcase(code)} 15000"), context())
        |> reply()

      assert chat_id == @cashier
      assert text =~ code
      assert [%{status: :redeemed, amount: amount}] = Ash.read!(Visit, actor: @actor)
      assert Money.equal?(amount, Money.new!(:CLP, 15_000))
    end

    test "rejects unknown codes and malformed input" do
      assert {_, text} = Redeem.call(update(@cashier, "/redeem NOPE12 100"), context()) |> reply()
      assert text == Texts.redeem_failed()

      for bad <- ["/redeem", "/redeem ABC", "/redeem ABC -5", "/redeem ABC 1,5x"] do
        assert {_, text} = Redeem.call(update(@cashier, bad), context()) |> reply()
        assert text == Texts.redeem_usage()
      end
    end
  end

  describe "texts" do
    test "parse_redeem/1 accepts integers and dot decimals only" do
      assert {:ok, "AB12CD", amount} = Texts.parse_redeem("ab12cd 12500")
      assert Decimal.equal?(amount, 12_500)
      assert {:ok, _, amount} = Texts.parse_redeem(" AB12CD   9.90 ")
      assert Decimal.equal?(amount, Decimal.new("9.90"))
      assert :error = Texts.parse_redeem("AB12CD 0")
      assert :error = Texts.parse_redeem("AB12CD 1e3")
    end

    test "promotion text carries title, body and opt-out hint" do
      text = Texts.promotion(%{title: "2x1", body: "Tacos al pastor"})
      assert text =~ "2x1"
      assert text =~ "Tacos al pastor"
      assert text =~ "/stop"
    end
  end

  describe "sticker URL" do
    setup do
      previous = Application.get_env(:eatsbot, EatsbotCore.Marketing, [])

      Application.put_env(
        :eatsbot,
        EatsbotCore.Marketing,
        Keyword.put(previous, :telegram_bot_username, "EatsbotBot")
      )

      on_exit(fn -> Application.put_env(:eatsbot, EatsbotCore.Marketing, previous) end)
    end

    test "/t/:code redirects to the bot deep link", %{conn: conn, touchpoint: touchpoint} do
      conn = get(conn, "/t/#{touchpoint.code}")
      assert redirected_to(conn, 302) == "https://t.me/EatsbotBot?start=v_#{touchpoint.code}"
    end

    test "/t/:code 404s for unknown stickers", %{conn: conn} do
      assert conn |> get("/t/ZZZZZZZZ") |> response(404)
    end
  end
end
