defmodule Eatsbot.LocalizationDependencyTest do
  use ExUnit.Case, async: true

  alias Eatsbot.Extensions.TelegramBot.Gettext, as: BotGettext

  test "English and Spanish delivery translations survive the interpolation migration" do
    Gettext.with_locale(EatsbotCore.Gettext, "en", fn ->
      assert Gettext.gettext(EatsbotCore.Gettext, "The order is processing") ==
               "The order is processing"
    end)

    Gettext.with_locale(EatsbotCore.Gettext, "es", fn ->
      assert Gettext.gettext(EatsbotCore.Gettext, "The order is processing") ==
               "La orden está en preparación"
    end)
  end

  test "Telegram translations interpolate every delivery field in both locales" do
    Enum.each(["en", "es"], fn locale ->
      Gettext.with_locale(BotGettext, locale, fn ->
        text =
          Gettext.gettext(BotGettext, "delivery_info",
            name: "Zoë O'Neil",
            phone: "+123",
            address: "Main Street",
            notes: "50% complete"
          )

        assert text =~ "Zoë O'Neil"
        assert text =~ "+123"
        assert text =~ "Main Street"
        assert text =~ "50% complete"
        refute text =~ "%{"
      end)
    end)
  end

  test "the command example retains its literal token placeholder" do
    Gettext.with_locale(BotGettext, "es", fn ->
      text =
        Gettext.gettext(
          BotGettext,
          "No active deliveries found. Please start one by using `/new {token}` or stop sharing location."
        )

      assert text =~ "`/new {token}`"
    end)
  end

  test "web validation messages bind ordinary Gettext placeholders" do
    assert Gettext.dgettext(Eatsbot.Gettext, "errors", "must be equal to %{number}", number: 23) =~
             "23"
  end

  test "Money 6 renders using the Telegram Gettext locale" do
    money = Money.new!(:USD, "12.34")

    Gettext.with_locale(BotGettext, "en", fn ->
      assert Eatsbot.Extensions.TelegramBot.Marketing.redeemed(%{code: "AB12", amount: money}) =~
               "12.34"
    end)

    Gettext.with_locale(BotGettext, "es", fn ->
      assert Eatsbot.Extensions.TelegramBot.Marketing.redeemed(%{code: "AB12", amount: money}) =~
               "12,34"
    end)
  end

  test "Decimal 3 preserves currency and exact arithmetic through Money 6" do
    money = Money.new!(:USD, "0.10") |> Money.mult!(3)
    assert money.currency == :USD
    assert Decimal.equal?(money.amount, Decimal.new("0.30"))
  end
end
