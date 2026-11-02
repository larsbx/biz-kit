defmodule TaskCore.Projects do
  @moduledoc """
  A project's owner, and the intake catalogue the owner adopted for it
  (docs/architecture/2026-11-02-typed-intake.md).

    * `TaskProjectOwnerAssignedV1`, by governance: the principal who owns the
      project. An owner can be replaced, never removed, so a project that has
      had an owner always has one.
    * `TaskIntakeCatalogueAdoptedV1`, by the project's owner, signing with an
      active operator grant in the project: the request types the project
      accepts. The catalogue is YAML the host stores; admission reads and
      decodes it by digest (`TaskCore.Host.read_catalogue/1`) and requires the
      signed catalogue to be its normal form (`TaskCore.Intake`). Replay folds
      the signed catalogue and reads no store.

  A typed Definition of Done (`TaskDoDDefinedV2`) cites the catalogue its
  project has adopted, and only that one. Uploading a catalogue changes
  nothing: adopting it does, and only the owner adopts.
  """

  alias TaskCore.{Admission, Intake, State}

  @scope %{"tenant_id" => :string, "project_id" => :string}

  def event_types do
    %{
      "TaskProjectOwnerAssignedV1" =>
        spec("governance", Map.put(@scope, "principal_id", :string)),
      "TaskIntakeCatalogueAdoptedV1" =>
        spec(
          "operator",
          Map.merge(@scope, %{
            "principal_id" => :string,
            "authorization_event_id" => :string,
            "catalogue_digest" => :hash,
            "catalogue" => :any
          })
        )
    }
  end

  defp spec(role, fields) do
    %{
      required_roles: [role],
      disclosure_class: :edges,
      stream: {:payload_fields, "task_projects", ~w(tenant_id project_id)},
      payload: %{required: fields, optional: %{}}
    }
  end

  def init, do: %{projects: %{}, project_commands: %{}}

  @doc "The project's owner, or nil."
  def owner(state, scope), do: get_in(state, [:projects, scope, :owner])

  @doc "The catalogue the project adopted, `%{digest:, catalogue:, event_id:}`, or nil."
  def catalogue(state, scope), do: get_in(state, [:projects, scope, :catalogue])

  # -- admission -----------------------------------------------------------------

  def check(%{type: "TaskProjectOwnerAssignedV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         :ok <- Admission.nonempty_fields(p, ~w(principal_id)) do
      if owner(state, State.scope(env)) == p["principal_id"],
        do: {:error, :project_owner_unchanged},
        else: :ok
    end
  end

  def check(%{type: "TaskIntakeCatalogueAdoptedV1", payload: p} = env, state, _keys) do
    scope = State.scope(env)

    with {:ok, grant} <- grant(state, p["authorization_event_id"]),
         :ok <- Admission.authorized(env, grant),
         :ok <- owned_by(state, scope, p["principal_id"]),
         {:ok, stored} <- read(state.host, p["catalogue_digest"]),
         true <- stored == p["catalogue"] or {:error, :intake_catalogue_mismatch} do
      digest = p["catalogue_digest"]

      case catalogue(state, scope) do
        %{digest: ^digest} -> {:error, :intake_catalogue_already_adopted}
        _ -> :ok
      end
    end
  end

  defp owned_by(state, scope, principal) do
    case owner(state, scope) do
      nil -> {:error, :project_has_no_owner}
      ^principal -> :ok
      _other -> {:error, :not_project_owner}
    end
  end

  defp grant(state, id) do
    case Map.fetch(state.grants, id) do
      {:ok, grant} -> {:ok, grant}
      :error -> {:error, :unknown_task_grant}
    end
  end

  # Fails closed: a host that cannot produce the digest's catalogue admits none.
  defp read(host, {:bytes, <<digest::binary-size(32)>>}) do
    with true <- Code.ensure_loaded?(host) and function_exported?(host, :read_catalogue, 1),
         {:ok, decoded} <- host.read_catalogue(digest) do
      Intake.normalize_catalogue(decoded)
    else
      _ -> {:error, :intake_catalogue_unavailable}
    end
  end

  defp read(_host, _digest), do: {:error, :intake_catalogue_unavailable}

  # -- fold ----------------------------------------------------------------------

  def handle_event(%{type: "TaskProjectOwnerAssignedV1", payload: p} = env, state) do
    state
    |> update_in([:projects, Access.key(State.scope(env), %{catalogue: nil})], fn project ->
      Map.merge(project, %{owner: p["principal_id"], owner_event_id: env.event_id})
    end)
    |> put_in([:project_commands, Access.key(env.event_id)], env)
  end

  def handle_event(%{type: "TaskIntakeCatalogueAdoptedV1", payload: p} = env, state) do
    adopted = %{digest: p["catalogue_digest"], catalogue: p["catalogue"], event_id: env.event_id}

    state
    |> put_in([:projects, State.scope(env), :catalogue], adopted)
    |> put_in([:project_commands, Access.key(env.event_id)], env)
  end

  def handle_event(_env, state), do: state
end
