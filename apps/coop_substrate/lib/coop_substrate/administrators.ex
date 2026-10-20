defmodule CoopSubstrate.Administrators do
  @moduledoc """
  A chapter's administrators (docs/architecture/2026-10-19-administration.md):
  its declared governance keys and the principal each was declared for. An
  administrator's browser holds such a key, enrolled like a device
  (`CoopSubstrate.Enrolments`, role `governance`).

  Any governance key revokes another (`RoleKeyRevoked`), with a reason; the
  ledger refuses to revoke a chapter's last one. Held for
  `{:role_key_revocation, chapter, key_id}`; the server signs nothing.

  An administrator acts on every project of the chapter
  (docs/architecture/2026-10-19-chapter-projects.md), which `projects/1`
  lists.
  """

  alias CoopSubstrate.{Commands, Log}
  alias TaskCore.State

  @doc "The chapter's governance keys, each with the principal it names, if any."
  @spec list(String.t()) :: [%{key_id: String.t(), principal_id: String.t() | nil}]
  def list(chapter), do: keys(Log.gate(), chapter)

  @doc "`list/1` against the membership projection `gate`: pure, as the change feed reads it."
  def keys(gate, chapter) do
    for {key_id, _pubkey} <- gate.role_keys[{chapter, "governance"}] || %{} do
      %{key_id: key_id, principal_id: gate.role_key_members[{chapter, "governance", key_id}]}
    end
    |> Enum.sort_by(& &1.key_id)
  end

  @doc """
  The chapter's projects: each with a task or a grant (active or not), its
  tasks by state, the principals holding something there now, as
  offboarding counts them (`TaskCore.State.held_by/3`), and the number of
  active grants and delegations, so any change in access changes the
  project (docs/architecture/2026-10-19-live-view.md).
  """
  @spec projects(String.t()) :: [
          %{
            tenant_id: String.t(),
            project_id: String.t(),
            tasks: %{String.t() => pos_integer()},
            grants: non_neg_integer(),
            people: [String.t()]
          }
        ]
  def projects(chapter), do: projects(Log.gate().orchestration, chapter)

  @doc "`projects/1` against the task projection `o`: pure, as the change feed reads it."
  def projects(o, chapter) do
    authorities = for {_, _, a} <- State.authorities(o), a.chapter_id == chapter, do: a
    states = for {{^chapter, t, p, _}, task} <- o.tasks, do: {{t, p}, task.state}

    people =
      for a <- authorities,
          a.active,
          principal <- State.holders(a),
          uniq: true,
          do: {{a.tenant_id, a.project_id}, principal}

    (Enum.map(authorities, &{&1.tenant_id, &1.project_id}) ++ Enum.map(states, &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn {tenant, project} = scope ->
      %{
        tenant_id: tenant,
        project_id: project,
        tasks: Enum.frequencies(for {^scope, state} <- states, do: state),
        grants: Enum.count(authorities, &(&1.active and {&1.tenant_id, &1.project_id} == scope)),
        people: Enum.sort(for {^scope, principal} <- people, do: principal)
      }
    end)
  end

  @doc "Prepare the revocation of governance key `key_id`, to be signed by `governance_key_id`."
  @spec prepare_revocation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare_revocation(chapter, key_id, reason, governance_key_id) do
    with true <-
           Map.has_key?(Log.gate().role_keys[{chapter, "governance"}] || %{}, key_id) or
             {:error, :unknown_role_key},
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold(
        {:role_key_revocation, chapter, key_id},
        chapter,
        "RoleKeyRevoked",
        %{"role" => "governance", "key_id" => key_id, "reason" => reason},
        signer
      )
    end
  end

  @spec revoke(String.t(), String.t(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def revoke(chapter, key_id, held_id, signature),
    do: Commands.submit({:role_key_revocation, chapter, key_id}, held_id, signature)
end
