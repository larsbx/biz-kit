defmodule Dispatch.Fleet.Validations.CurrencyWithAmount do
  @moduledoc """
  An amount without a currency is not a price.

  Section 19.2 requires monetary amounts to be integer minor units *plus* an ISO
  4217 code. A bare `agreed_rate_minor` would be ambiguous between currencies
  whose minor units differ: "1999" means something different in USD than in a
  zero-decimal currency.
  """

  use Ash.Resource.Validation

  @impl Ash.Resource.Validation
  def validate(changeset, _opts, _context) do
    amount = Ash.Changeset.get_attribute(changeset, :agreed_rate_minor)
    currency = Ash.Changeset.get_attribute(changeset, :currency)

    cond do
      is_nil(amount) and is_nil(currency) -> :ok
      not is_nil(amount) and not is_nil(currency) -> :ok
      is_nil(currency) -> {:error, field: :currency, message: "is required when an amount is set"}
      true -> {:error, field: :agreed_rate_minor, message: "is required when a currency is set"}
    end
  end

  @impl Ash.Resource.Validation
  def atomic(changeset, opts, context),
    do: {:not_atomic, inspect(validate(changeset, opts, context))}
end
