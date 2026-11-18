defmodule TaskCore.Projects do
  @moduledoc """
  A project's owner, the principal kinds that make one eligible, and the
  intake catalogue the owner adopted (docs/architecture/2026-11-02-project-ownership.md,
  2026-11-02-typed-intake.md).

  Ownership establishes accountability, grants establish authority, and
  governance controls both. Owning a project permits nothing by itself.

    * `TaskPrincipalKindDeclaredV1` and `TaskPrincipalKindWithdrawnV1`, by
      governance, chapter-wide: that a principal is `human` or an `agent`,
      or no longer either. The kind is a governance attestation, not proof
      of personhood.
    * `TaskProjectOwnerAssignedV1`, by governance: the project's one
      accountable owner. An owner can be replaced, never removed, so a
      project that has had an owner always has one.

  An owner is **eligible** while governance has declared them `human` and
  they hold an active operator grant in the project. An undeclared principal
  never qualifies. `violations/1` lists the projects whose owner is not;
  admission refuses any transition that adds one, by whatever route the
  owner would lose eligibility (`TaskCore.Admission.check_transition/2`).

    * `TaskIntakeCatalogueAdoptedV1`, by the project's owner, signing with an
      active operator grant in the project: the request types the project
      accepts. The catalogue is YAML the host stores; admission reads and
      decodes it by digest (`TaskCore.Host.read_catalogue/1`) and requires the
      signed catalogue to be its normal form (`TaskCore.Intake`). Replay folds
      the signed catalogue and reads no store.
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
  @kinds ~w(human agent)
  @principal_types ~w(TaskPrincipalKindDeclaredV1 TaskPrincipalKindWithdrawnV1)

  def event_types do
    %{
      "TaskPrincipalKindDeclaredV1" =>
        principal_spec(%{"principal_id" => :string, "kind" => :string}),
      "TaskPrincipalKindWithdrawnV1" => principal_spec(%{"principal_id" => :string}),
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

  # A principal's kind belongs to the chapter, not to one project.
  defp principal_spec(fields) do
    %{
      required_roles: ["governance"],
      disclosure_class: :edges,
      stream: {:chapter_scoped, "task_principals"},
      payload: %{required: fields, optional: %{}}
    }
  end

  @doc "The chapter-scoped event types, which name no tenant or project."
  def principal_types, do: @principal_types

  def init, do: %{projects: %{}, project_commands: %{}, principal_kinds: %{}}

  @doc "The kind governance declared for `principal` in `chapter`: `\"human\"`, `\"agent\"` or nil."
  def kind(state, chapter, principal), do: Map.get(state.principal_kinds, {chapter, principal})

  @doc "The project's owner, or nil."
  def owner(state, scope), do: get_in(state, [:projects, scope, :owner])

  @doc """
  Whether `principal` may be `scope`'s owner now: declared human in the
  chapter, holding an active operator grant in the project.
  """
  def eligible?(state, {chapter, _tenant, _project} = scope, principal) do
    kind(state, chapter, principal) == "human" and
      Enum.any?(state.grants, fn {_id, g} ->
        g.active and g.principal_id == principal and
          {g.chapter_id, g.tenant_id, g.project_id} == scope
      end)
  end

  @doc "Whether the project has an owner, and that owner is eligible."
  def eligible_owner?(state, scope) do
    case owner(state, scope) do
      nil -> false
      principal -> eligible?(state, scope, principal)
    end
  end

  @doc "Whether the project may take new work: `:ok`, or why not."
  def accepts_work(state, scope) do
    cond do
      owner(state, scope) == nil -> {:error, :project_has_no_owner}
      eligible_owner?(state, scope) -> :ok
      true -> {:error, :project_owner_ineligible}
    end
  end

  @doc "The projects whose owner is not eligible, sorted. An admitted ledger has none."
  def violations(state) do
    Enum.sort(
      for {scope, %{owner: owner}} <- state.projects,
          owner != nil,
          not eligible?(state, scope, owner),
          do: scope
    )
  end

  @doc "The catalogue the project adopted, `%{digest:, catalogue:, event_id:}`, or nil."
  def catalogue(state, scope), do: get_in(state, [:projects, scope, :catalogue])

  # -- admission -----------------------------------------------------------------

  # Eligibility is not checked here: an ineligible owner is a violation, which
  # admission refuses after the event, or after the batch (`check_transition/2`).
  def check(%{type: "TaskPrincipalKindDeclaredV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         :ok <- Admission.nonempty_fields(p, ~w(principal_id)),
         true <- p["kind"] in @kinds or {:error, :invalid_principal_kind} do
      if kind(state, env.chapter_id, p["principal_id"]) == p["kind"],
        do: {:error, :principal_kind_unchanged},
        else: :ok
    end
  end

  def check(%{type: "TaskPrincipalKindWithdrawnV1", payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         :ok <- Admission.nonempty_fields(p, ~w(principal_id)) do
      if kind(state, env.chapter_id, p["principal_id"]) == nil,
        do: {:error, :principal_kind_not_declared},
        else: :ok
    end
  end

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

  def handle_event(%{type: "TaskPrincipalKindDeclaredV1", payload: p} = env, state) do
    state
    |> put_in([:principal_kinds, Access.key({env.chapter_id, p["principal_id"]})], p["kind"])
    |> put_in([:project_commands, Access.key(env.event_id)], env)
  end

  def handle_event(%{type: "TaskPrincipalKindWithdrawnV1", payload: p} = env, state) do
    state
    |> update_in([:principal_kinds], &Map.delete(&1, {env.chapter_id, p["principal_id"]}))
    |> put_in([:project_commands, Access.key(env.event_id)], env)
  end

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
