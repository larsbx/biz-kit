defmodule CoopSubstrate.Offboarding do
  @moduledoc """
  Offboarding a principal (docs/architecture/2026-10-19-offboarding.md): one
  `TaskPrincipalOffboardedV1` per project, signed with a governance key by
  `mix coop.offboard`, ends everything the principal holds there at
  admission (`Projections.Tasks.held_by/3`): device, suggester and reviewer
  grants, and delegations to or by them. Held for `{:offboarding, principal}`;
  the server signs nothing.

  Admission, not preparation, decides what ends, so a grant appended between
  the two ends too. History stays: the principal, its identity binding and
  everything it signed remain on the ledger, and governance may grant it
  afresh later.
  """

  alias CoopSubstrate.{Commands, Enrolments, Log}
  alias CoopSubstrate.Projections.Tasks, as: State

  @kinds %{
    grants: "operator",
    suggester_grants: "suggester",
    dod_grants: "reviewer",
    delegations: "delegation"
  }

  @doc """
  What the principal holds, per project in `chapters`, for an administrator
  to judge (`Governance.Read` decides the chapters).
  """
  @spec fetch(String.t(), [String.t()]) :: %{principal_id: String.t(), projects: [map()]}
  def fetch(principal, chapters) do
    o = Log.gate().orchestration

    projects =
      for kind <- Map.keys(@kinds),
          {_, a} <- Map.fetch!(o, kind),
          a.active,
          a.chapter_id in chapters,
          uniq: true,
          do: {a.chapter_id, a.tenant_id, a.project_id}

    %{
      principal_id: principal,
      projects:
        projects
        |> Enum.sort()
        |> Enum.map(&{&1, State.held_by(o, principal, &1)})
        |> Enum.reject(&match?({_, []}, &1))
        |> Enum.map(fn {{chapter, tenant, project}, held} ->
          %{
            chapter_id: chapter,
            tenant_id: tenant,
            project_id: project,
            held: Enum.map(held, &describe(o, principal, &1))
          }
        end)
    }
  end

  @doc "Prepare the offboarding in one project, to be signed by the named governance key."
  @spec prepare(String.t(), CoopSubstrate.Feed.View.scope(), String.t()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare(principal, {chapter, tenant, project} = scope, governance_key_id) do
    with true <-
           State.held_by(Log.gate().orchestration, principal, scope) != [] or
             {:error, :nothing_to_offboard},
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold(
        {:offboarding, principal},
        chapter,
        "TaskPrincipalOffboardedV1",
        %{"tenant_id" => tenant, "project_id" => project, "principal_id" => principal},
        signer
      )
    end
  end

  @doc "Submit the governance signature; on admission, pending enrolments there are dropped too."
  @spec offboard(String.t(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def offboard(principal, held_id, signature) do
    with {:ok, env} <- Commands.submit({:offboarding, principal}, held_id, signature) do
      Enrolments.cancel(principal, State.scope(env))
      {:ok, env}
    end
  end

  defp describe(o, principal, {kind, id}) do
    a = Map.fetch!(o, kind)[id]

    %{
      event_id: id,
      kind: @kinds[kind],
      key_id: a.key_id,
      label: a[:device_label],
      direction: if(kind == :delegations, do: direction(a, principal))
    }
  end

  defp direction(%{delegator_principal_id: p}, p), do: "by"
  defp direction(_delegation, _principal), do: "to"
end
