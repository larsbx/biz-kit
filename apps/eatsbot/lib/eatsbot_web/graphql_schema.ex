defmodule EatsbotWeb.GraphqlSchema do
  @moduledoc """
  Schema for GraphQL endpoints.
  """
  use Absinthe.Schema

  use AshGraphql,
    domains: [EatsbotCore.Deliveries, EatsbotCore.Carts, EatsbotCore.Brands, EatsbotCore.Products],
    generate_sdl_file: "priv/schema.graphql"

  import_types Absinthe.Plug.Types

  query do
    # Custom Absinthe queries can be placed here
  end

  object :money do
    field(:amount, non_null(:decimal))
    field(:currency, non_null(:string))
  end

  input_object :money_input do
    field(:amount, non_null(:decimal))
    field(:currency, non_null(:string))
  end
end
