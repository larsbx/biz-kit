defmodule Dispatch.Access.Roles.Base do
  @moduledoc """
  Shared implementation for the seeded role profiles.

  Every profile reads its capabilities from the stored manifest; Section 23.2
  makes that the authority, so the default `capabilities/1` here is the whole of
  it and a profile that overrode it would be granting capabilities in code.

  A profile customises `validate_status_transition/3`, `android_features/1`, and
  `operations_projection/1` — the workflow semantics that genuinely differ.
  """

  @doc false
  defmacro __using__(opts) do
    projection = Keyword.fetch!(opts, :projection)
    features = Keyword.get(opts, :android_features, [])

    quote do
      @behaviour Dispatch.Access.RoleProfile

      @impl Dispatch.Access.RoleProfile
      def capabilities(%{capabilities_json: capabilities}) when is_list(capabilities) do
        MapSet.new(capabilities)
      end

      def capabilities(_definition), do: MapSet.new()

      @impl Dispatch.Access.RoleProfile
      def operations_projection(_assignment), do: unquote(projection)

      @impl Dispatch.Access.RoleProfile
      def android_features(_assignment), do: unquote(features)

      @impl Dispatch.Access.RoleProfile
      def validate_status_transition(_current, _requested, _context),
        do: {:error, :status_not_declarable_by_role}

      # Section 22.2: one active assignment unless a profile says otherwise.
      @impl Dispatch.Access.RoleProfile
      def allows_concurrent_assignments?,
        do: unquote(Keyword.get(opts, :concurrent_assignments, false))

      defoverridable capabilities: 1,
                     operations_projection: 1,
                     android_features: 1,
                     validate_status_transition: 3,
                     allows_concurrent_assignments?: 0
    end
  end
end
