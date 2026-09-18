defmodule Dispatch.Access.RoleProfile do
  @moduledoc """
  The role-specific semantics contract of Section 23.2.

  A profile module validates workflow rules that differ by role. It cannot grant
  a capability and cannot bypass an Ash policy: `capabilities/1` reads the
  definition's stored manifest, and shared authorization checks operate on
  capabilities and scope regardless of which profile produced them.

  `role_definitions.profile_module` may name only a module compiled into the
  release and listed in `ROLE_PROFILE_MODULE_ALLOWLIST` (Section 23.2), so
  database content cannot load arbitrary code.
  """

  alias Dispatch.Accounts.{RoleAssignment, RoleDefinition}

  @doc """
  The capability set this definition grants.

  Reads the stored manifest. A profile module MUST NOT add a key that is not in
  `capabilities_json`; Section 23.2 makes the manifest the authority so that a
  capability change is an audited data change, not a code change.
  """
  @callback capabilities(RoleDefinition.t()) :: MapSet.t()

  @doc """
  Whether this role may move from `current` to `requested`.

  Section 23.2 requires regulatory or workflow distinctions that change data
  semantics to be explicit validation rules rather than display labels.
  """
  @callback validate_status_transition(current :: term(), requested :: term(), context :: map()) ::
              :ok | {:error, atom()}

  @doc """
  Feature keys the Android client may enable for this assignment.

  Section 23.2 requires the field application to enable features from a signed
  server capability document, never from an `if role == DRIVER` check, so this
  is the only place a role's feature set is decided.
  """
  @callback android_features(RoleAssignment.t()) :: [String.t()]

  @doc "The operations projection this assignment renders (Section 4.3)."
  @callback operations_projection(RoleAssignment.t()) :: atom()

  @doc """
  The allowlisted profile modules, from `ROLE_PROFILE_MODULE_ALLOWLIST`.

  Section 31 fails startup when a seeded or active definition references
  anything else.
  """
  @spec allowlist() :: [module()]
  def allowlist do
    :dispatch
    |> Application.get_env(:role_profile_module_allowlist, [])
    |> Enum.map(fn
      module when is_atom(module) -> module
      name when is_binary(name) -> Module.concat([name])
    end)
  end

  @doc """
  Whether `module` may be referenced by a role definition.

  Both conditions are required: listed in configuration *and* compiled in.
  Configuration alone would let a deployment name a module that does not exist;
  compilation alone would let any module in the release be selected from the
  database.
  """
  @spec allowed?(module() | nil) :: boolean()
  def allowed?(nil), do: false

  def allowed?(module) when is_atom(module) do
    module in allowlist() and Code.ensure_loaded?(module) and
      function_exported?(module, :capabilities, 1)
  end

  @doc "Resolves a stored module name to an allowed module."
  @spec fetch(String.t() | module() | nil) ::
          {:ok, module()} | {:error, :profile_module_not_allowed}
  def fetch(nil), do: {:error, :profile_module_not_allowed}

  def fetch(name) when is_binary(name) do
    fetch(Module.concat([name]))
  rescue
    ArgumentError -> {:error, :profile_module_not_allowed}
  end

  def fetch(module) when is_atom(module) do
    if allowed?(module), do: {:ok, module}, else: {:error, :profile_module_not_allowed}
  end
end
