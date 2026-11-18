defmodule CommerceCore.Tax.Jurisdictions do
  @moduledoc """
  Tax profiles (`CommerceCore.Tax.flat/4`) for the jurisdictions a merchant
  may be configured in, by ISO 3166-2 code. Each entry records what it rests
  on; confirm with a tax adviser before relying on one.

  ## US-MI, Michigan

    * 6% General Sales Tax on prepared food; no local sales taxes.
    * An itemized delivery charge is not taxed (Public Acts 20 and 21 of 2023,
      from 2023-04-26; Revenue Administrative Bulletin 2023-16). Our snapshot
      always itemizes the delivery fee. Whether a restaurant's own delivery
      fee on prepared food falls under that exemption is to be confirmed.
    * Rounding (MCL 205.73(2)): the tax is carried to the third decimal and
      rounded up to a whole cent when that digit is greater than 4, down when
      it is 4 or less; a seller may compute it per item or per invoice
      (Internal Policy Directive 2004-5). `Tax.flat/4` computes it once per
      order, which equals the statute's rule on the order's taxable total
      (proved in `jurisdictions_test.exs`).
    * Voluntary tips are not taxed, and are never a tax input here.
    * Cash rounding to a nickel (Treasury notice of 2025-12-08 on the penny
      phase-out) happens after the tax and does not change it.
  """

  @profiles %{
    "US-MI" => %{rate: "0.06", fee_taxable?: false}
  }

  @doc "The tax profile for a jurisdiction code."
  @spec profile(String.t()) ::
          {:ok, CommerceCore.Tax.profile()} | {:error, :unknown_jurisdiction}
  def profile(code) do
    case Map.fetch(@profiles, code) do
      {:ok, p} -> {:ok, %{p | rate: Decimal.new(p.rate)}}
      :error -> {:error, :unknown_jurisdiction}
    end
  end

  @doc "The supported jurisdiction codes."
  def codes, do: Map.keys(@profiles)
end
