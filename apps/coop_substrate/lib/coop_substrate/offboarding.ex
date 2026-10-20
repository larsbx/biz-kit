defmodule CoopSubstrate.Offboarding do
  @moduledoc """
  Offboarding a principal (docs/architecture/2026-10-19-offboarding.md): one
  `TaskPrincipalOffboardedV1` per project, signed with a governance key by
  `mix coop.offboard`, ends everything the principal holds there at
  admission (`Projections.Tasks.held_by/3`): device, suggester and reviewer
  grants, and delegations to or by them. Held for `{:offboarding, principal}`;
  the server signs nothing.

  Admission, not preparation, decides what ends, so a grant appended between
  the two ends too.

  **From the whole chapter** (`prepare_chapter/3`, `offboard_chapter/3`;
  docs/architecture/2026-10-19-chapter-offboarding.md): one offboarding per
  project the principal holds something in, then a `RoleKeyRevoked` for each
  governance key declared for them, the signer's own last, held together for
  `{:chapter_offboarding, principal}` and appended as one batch: all or none.
  The revocations are governance-signed, in the governance history, so an
  export derives the same keys. History stays: the principal, its identity binding and
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
  @spec fetch(String.t(), [String.t()]) :: %{
          principal_id: String.t(),
          projects: [map()],
          keys: [%{chapter_id: String.t(), key_id: String.t()}]
        }
  def fetch(principal, chapters) do
    gate = Log.gate()
    o = gate.orchestration

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
        end),
      keys:
        for(
          chapter <- chapters,
          key_id <- keys(gate, principal, chapter),
          do: %{chapter_id: chapter, key_id: key_id}
        )
    }
  end

  @doc """
  Prepare the principal's offboarding from every project of `chapter`, and
  the revocation of their governance keys there, to be signed together by
  the named governance key.
  """
  @spec prepare_chapter(String.t(), String.t(), String.t()) ::
          {:ok, %{id: String.t(), commands: [map()], expires_at: integer()}} | {:error, term()}
  def prepare_chapter(principal, chapter, governance_key_id) do
    gate = Log.gate()

    offboardings =
      for p <- CoopSubstrate.Administrators.projects(gate.orchestration, chapter),
          principal in p.people,
          do:
            {"TaskPrincipalOffboardedV1",
             %{
               "tenant_id" => p.tenant_id,
               "project_id" => p.project_id,
               "principal_id" => principal
             }}

    # The signer's own key last: every command before it is signed by a key still declared.
    revocations =
      for key_id <- Enum.sort_by(keys(gate, principal, chapter), &(&1 == governance_key_id)),
          do: {"RoleKeyRevoked", %{"role" => "governance", "key_id" => key_id}}

    with true <- offboardings ++ revocations != [] or {:error, :nothing_to_offboard},
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold_batch(
        {:chapter_offboarding, principal},
        chapter,
        offboardings ++ revocations,
        signer
      )
    end
  end

  @doc """
  Submit the signatures, one per prepared command. The principal's pending
  enrolment requests anywhere in the chapter are cancelled first.
  """
  @spec offboard_chapter(String.t(), String.t(), [binary()]) ::
          {:ok, [CoopSubstrate.Protocol.Envelope.t()]} | {:error, term()}
  def offboard_chapter(principal, held_id, signatures) do
    owner = {:chapter_offboarding, principal}

    with {:ok, [held | _]} <- Commands.peek(owner, held_id),
         :ok <- Enrolments.cancel(principal, {held.chapter_id}),
         do: Commands.submit_batch(owner, held_id, signatures)
  end

  # The governance keys of `chapter` declared for `principal`, sorted.
  defp keys(gate, principal, chapter),
    do:
      for(
        k <- CoopSubstrate.Administrators.keys(gate, chapter),
        k.principal_id == principal,
        do: k.key_id
      )

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

  @doc """
  Submit the governance signature. The principal's pending enrolment
  requests in the project are cancelled first, so no approval of one, even
  prepared and signed already, can be admitted after the offboarding; one
  admitted before it ends with it.
  """
  @spec offboard(String.t(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def offboard(principal, held_id, signature) do
    with {:ok, [held]} <- Commands.peek({:offboarding, principal}, held_id),
         :ok <- Enrolments.cancel(principal, State.scope(held)),
         do: Commands.submit({:offboarding, principal}, held_id, signature)
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
