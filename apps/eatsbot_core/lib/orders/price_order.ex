defmodule EatsbotCore.Orders.PriceOrder do
  @moduledoc """
  Prices a new order with `EatsbotCore.Orders.Pricing` and creates its line snapshots.

  Amount adjustments left nil default to zero in the order's currency. Any pricing
  error becomes a changeset error, so an inconsistent order is never written (I₂).
  """
  use Ash.Resource.Change

  alias EatsbotCore.Orders.Pricing

  @adjustments ~w(discount_total tax_total delivery_fee tip)a

  @impl true
  def change(changeset, _opts, _context) do
    with {:ok, currency} <- currency(changeset),
         adjustments = Map.new(@adjustments, &{&1, amount(changeset, &1, currency)}),
         {:ok, priced} <- Pricing.price(currency, lines(changeset), adjustments) do
      changeset
      |> Ash.Changeset.force_change_attributes(adjustments)
      |> Ash.Changeset.force_change_attributes(Map.take(priced, [:subtotal, :total]))
      |> Ash.Changeset.manage_relationship(:lines, priced.lines, type: :create)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message: "cannot price order: #{inspect(reason)}"
        )
    end
  end

  defp currency(changeset) do
    with code when is_binary(code) <- Ash.Changeset.get_attribute(changeset, :currency),
         {:ok, currency} <- Money.validate_currency(code) do
      {:ok, currency}
    else
      _ -> {:error, :invalid_currency}
    end
  end

  defp amount(changeset, key, currency),
    do: Ash.Changeset.get_attribute(changeset, key) || Money.zero(currency)

  defp lines(changeset),
    do: changeset |> Ash.Changeset.get_argument(:lines) |> List.wrap() |> Enum.map(&Map.new/1)
end
