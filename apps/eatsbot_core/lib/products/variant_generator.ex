defmodule EatsbotCore.Products.Product.VariantGenerator do
  @moduledoc """
  Generates variants for a product, using its options.
  """
  use Ash.Resource.Change

  @impl true
  @spec change(Ash.Changeset.t(), term(), term()) :: Ash.Changeset.t()
  def change(
        %{
          data: %{
            options: options,
            name: name,
            description: description,
            sku: sku,
            prices: prices,
            discount_rules: discount_rules
          }
        } = changeset,
        _opts,
        _context
      ) do
    combinations = cartesian_product(options)

    # Build all changesets first and validate them
    variant_changesets =
      Enum.map(combinations, fn combination ->
        prices =
          if is_list(prices),
            do:
              prices
              |> Enum.map(fn %{money: money} ->
                %{money: %{amount: money.amount, currency: money.currency}}
              end),
            else: []

        EatsbotCore.Products.Variant
        |> Ash.Changeset.for_create(
          :create,
          %{
            option_value_ids: combination |> Enum.map(& &1.id),
            name: name,
            description: description,
            sku: sku,
            discount_rules: discount_rules
          },
          authorize?: false
        )
        |> Ash.Changeset.manage_relationship(:product, %{id: changeset.data.id}, type: :append)
        |> Ash.Changeset.manage_relationship(:option_values, combination, type: :append)
        |> Ash.Changeset.manage_relationship(:prices, prices,
          on_no_match: {:create, :create_for_variant},
          on_match: :ignore
        )
      end)

    # Validate all changesets before attempting to create
    validation_errors =
      variant_changesets
      |> Enum.with_index()
      |> Enum.flat_map(fn {cs, idx} ->
        if cs.valid? do
          []
        else
          [{idx, cs.errors}]
        end
      end)

    case validation_errors do
      [] ->
        # All changesets are valid, proceed with transaction
        case create_variants_in_transaction(variant_changesets) do
          {:ok, _variants} ->
            changeset

          {:error, reason} ->
            Ash.Changeset.add_error(changeset, "Failed to create variants: #{inspect(reason)}")
        end

      errors ->
        # Add validation errors to changeset
        Ash.Changeset.add_error(
          changeset,
          "Variant validation failed for #{length(errors)} variant(s): #{inspect(errors)}"
        )
    end
  end

  # Create all variants within a transaction for atomicity
  defp create_variants_in_transaction(changesets) do
    repo = AshPostgres.DataLayer.Info.repo(EatsbotCore.Products.Variant)

    repo.transaction(fn ->
      Enum.reduce_while(changesets, [], fn changeset, acc ->
        case Ash.create(changeset) do
          {:ok, variant} ->
            {:cont, [variant | acc]}

          {:error, error} ->
            # Rollback the transaction on any error
            repo.rollback(error)
        end
      end)
      |> Enum.reverse()
    end)
  end

  # gets all the possible value combinations
  defp cartesian_product(list) do
    Enum.reduce(list, [[]], fn option, acc ->
      for combination <- acc, value <- option.option_values, do: [value | combination]
    end)
  end
end
