defmodule Dispatch.Identity.PrincipalResolution do
  @moduledoc """
  Turns a verified token subject into the one actor a request acts under
  (Sections 23.3, 24.6).

  ## The bootstrapping problem

  Every other read in this system is authorized against an actor and scoped to a
  tenant. This one cannot be: it is the step that *produces* the actor, and the
  tenant is a property of the assignment it has not selected yet. A user is
  global (ADR-0005) and may hold assignments in several operating
  organizations, so the question "which authority contexts exist for this
  person?" is unavoidably asked before any tenant is known.

  Rather than loosen `Participant` and `RoleAssignment` to be globally readable
  — which would turn every forgotten `set_tenant` elsewhere from a loud error
  into a silent cross-tenant read — the untenanted step is confined to
  `contexts/2` below. That query returns identifiers and nothing else: no names,
  no capabilities, no domain data. It answers only *where* this person might
  act.

  Once a context is chosen, the assignment is re-read through Ash with the
  tenant set, and `Dispatch.Access.Actor` re-checks its validity interval. So
  the directory lookup narrows; it never grants. That is Section 24.6's "selects
  authority context but never grants it" made structural.

  ## Selection

  When the caller names an assignment, it must be one the directory already
  returned for them — a header naming someone else's assignment finds nothing,
  by the same code path that handles a stale browser tab. When the caller names
  none and holds exactly one, that one is used. When they hold several, the
  request is ambiguous and is refused: Section 23.3 forbids unioning
  capabilities across assignments, and choosing on the caller's behalf would be
  a union by another name.
  """

  import Ecto.Query, only: [from: 2]

  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.{RoleAssignment, User}

  require Ash.Query

  @type context :: %{
          role_assignment_id: Ash.UUID.t(),
          tenant_id: Ash.UUID.t(),
          participant_id: Ash.UUID.t()
        }

  @type error ::
          :unknown_principal
          | :no_active_assignment
          | :ambiguous_role_assignment
          | :role_assignment_not_held
          | :role_definition_not_loaded
          | :role_assignment_not_active

  @doc """
  Resolves `subject` and an optional requested assignment to one actor.

  `at` is threaded through selection, re-read, and the resulting actor so the
  validity interval is judged against a single instant rather than three
  successive clock reads.
  """
  @spec actor(String.t(), Ash.UUID.t() | nil, keyword()) :: {:ok, Actor.t()} | {:error, error()}
  def actor(subject, requested_assignment_id \\ nil, opts \\ []) do
    at = Keyword.get(opts, :at, DateTime.utc_now())

    with {:ok, user} <- fetch_user(subject),
         {:ok, chosen} <- select(contexts(user.id, at), requested_assignment_id),
         {:ok, assignment} <- fetch_assignment(chosen, at) do
      Actor.from_assignment(assignment, at: at)
    end
  end

  @doc """
  The authority contexts `user_id` holds at `at`, as identifiers only.

  Untenanted by necessity — see the module documentation. Kept as a projection
  over `role_assignments` and `participants` so that widening it to return
  domain data would be a visible change to this function rather than an
  invisible consequence of a resource-level setting.
  """
  @spec contexts(Ash.UUID.t(), DateTime.t()) :: [context()]
  def contexts(user_id, at) do
    from(ra in "role_assignments",
      join: p in "participants",
      on: p.id == ra.principal_id and p.tenant_id == ra.tenant_id,
      where: p.user_id == type(^user_id, :binary_id),
      where: p.status == "ACTIVE",
      where: ra.principal_type == "PARTICIPANT",
      where: ra.status == "ACTIVE",
      where: ra.starts_at <= ^at,
      where: is_nil(ra.ends_at) or ra.ends_at > ^at,
      order_by: [asc: ra.id],
      select: %{
        role_assignment_id: type(ra.id, :binary_id),
        tenant_id: type(ra.tenant_id, :binary_id),
        participant_id: type(p.id, :binary_id)
      }
    )
    |> Dispatch.Repo.all()
  end

  defp select([], _requested), do: {:error, :no_active_assignment}

  defp select(contexts, requested) when is_binary(requested) do
    case Enum.find(contexts, &(&1.role_assignment_id == requested)) do
      nil -> {:error, :role_assignment_not_held}
      context -> {:ok, context}
    end
  end

  defp select([only], nil), do: {:ok, only}
  defp select(_several, nil), do: {:error, :ambiguous_role_assignment}

  defp fetch_user(subject) do
    # REVIEWED-UNAUTHORIZED: resolving who is calling necessarily precedes
    # knowing what they may read, so this lookup cannot be subject to the
    # caller's own read policy without circularity. It is keyed by the verified
    # token subject, so it returns at most the caller's own record, and nothing
    # from that record reaches the response — only the actor built from it.
    User
    |> Ash.Query.for_read(:by_oidc_subject, %{oidc_subject: subject})
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %User{status: :ACTIVE} = user} -> {:ok, user}
      _otherwise -> {:error, :unknown_principal}
    end
  end

  defp fetch_assignment(context, at) do
    # REVIEWED-UNAUTHORIZED: the same circularity, now narrowed to one row the
    # directory query already established this principal holds. Tenant context is
    # set from that row rather than from the request, and the `:active` read
    # re-applies the validity interval in SQL, so a revocation between the two
    # queries is caught here and again in `Actor.from_assignment/2`.
    RoleAssignment
    |> Ash.Query.for_read(:active, %{at: at})
    |> Ash.Query.filter(id == ^context.role_assignment_id)
    |> Ash.Query.load(:role_definition)
    |> Ash.read_one(authorize?: false, tenant: context.tenant_id)
    |> case do
      {:ok, %RoleAssignment{} = assignment} -> {:ok, assignment}
      _otherwise -> {:error, :role_assignment_not_active}
    end
  end
end
