defmodule CommerceCore.Tax.JurisdictionsTest do
  @moduledoc """
  Michigan, where the rebuilt eatsbot launches: 6% on prepared food, no local
  sales tax, an itemized delivery fee untaxed, and the statute's rounding rule
  (MCL 205.73(2)): carry the tax to the third decimal, round up to a whole cent
  when that digit is greater than 4, down when it is 4 or less.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CommerceCore.Tax
  alias CommerceCore.Tax.Jurisdictions

  defp m(n), do: Money.from_integer(n, :USD)
  defp minor(money), do: money |> Money.to_integer_exp() |> elem(1)

  # The statute, literally: the exact tax in mills (thousandths of a dollar),
  # truncated at the third decimal, then its third decimal digit decides.
  defp statute(base_cents) do
    mills = div(base_cents * 6 * 10, 100)
    div(mills, 10) + if(rem(mills, 10) > 4, do: 1, else: 0)
  end

  test "Michigan's profile: 6%, delivery fee untaxed" do
    assert {:ok, %{rate: rate, fee_taxable?: false}} = Jurisdictions.profile("US-MI")
    assert Decimal.equal?(rate, Decimal.new("0.06"))
    assert Jurisdictions.profile("US-XX") == {:error, :unknown_jurisdiction}
    assert "US-MI" in Jurisdictions.codes()
  end

  property "the order's tax is exactly what MCL 205.73(2) gives on the taxable total" do
    {:ok, mi} = Jurisdictions.profile("US-MI")

    check all(
            lines <- list_of(integer(0..200_000), min_length: 1, max_length: 8),
            fee <- integer(0..2_000)
          ) do
      {:ok, taxed} = Tax.flat(:USD, mi, Enum.map(lines, &m/1), m(fee))
      assert minor(taxed.total) == statute(Enum.sum(lines))
      assert minor(taxed.fee) == 0
    end
  end

  test "Treasury's penny-notice example: $3.39 → $0.20, and the half-cent boundary" do
    {:ok, mi} = Jurisdictions.profile("US-MI")
    tax = fn cents -> {:ok, t} = Tax.flat(:USD, mi, [m(cents)], m(0)); minor(t.total) end
    # $3.39 × 6% = $0.2034 → third decimal 3 → $0.20.
    assert tax.(339) == 20
    # $0.75 × 6% = $0.045 → 5 → up to $0.05; $0.74 × 6% = $0.0444 → 4 → $0.04.
    assert {tax.(75), tax.(74)} == {5, 4}
  end
end
