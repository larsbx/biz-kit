defmodule EatsbotCore.Marketing.Policies do
  @moduledoc """
  Shared policies: customer data (chat ids, bills) is visible to admins and to
  trusted integrations (the bot, the redirect controller) only.
  """
  use Spark.Dsl.Fragment, of: Ash.Resource, authorizers: [Ash.Policy.Authorizer]

  policies do
    bypass actor_attribute_equals(:access_level, :admin) do
      authorize_if always()
    end

    policy always() do
      authorize_if actor_attribute_equals(:access_level, :private)
    end
  end
end
