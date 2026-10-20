defmodule CoopSubstrate.Feed.View do
  @moduledoc """
  What a change-feed client sees of one project: its tasks, suggestions,
  delegations and custody receipts, each reduced to a whitelisted, JSON-safe
  value (docs/architecture/2026-10-18-change-feed.md). A task carries its
  readiness definition and SOP acknowledgement, who started it, and its
  evidence submission and review (not the evidence), and a receipt its
  digest, so a person's device can take each lifecycle step
  (docs/architecture/2026-10-19-lifecycle.md, 2026-10-19-execution.md). A
  cancelled task carries who cancelled it (governance: none) and why
  (2026-10-19-cancel-reopen.md).

  A project's view also carries its reader's own **devices** (`Devices.of/3`:
  operator and reviewer grants in the project, administrator keys of the
  chapter), so a person's page follows its access as it is granted and
  revoked (docs/architecture/2026-10-19-live-view.md). Another person's
  devices never appear; a view read without a reader has none.

  It carries the project's **workflows** under the blueprint revisions now
  governing them, and a task a workflow run made carries its `blueprint`:
  the revision, roadmap, workflow and definition it came from, its
  predecessors and its input names
  (docs/architecture/2026-10-20-workflow-view.md).

  A **chapter's** view, scope `{chapter}`, is for its administrators: its
  **projects** (`Administrators.projects/2`, keyed `tenant/project`, each
  part URI-encoded) and its **administrators** (`Administrators.keys/2`).

  Pure. `select/3` reads a view out of the membership projection; `diff/2`
  gives the changes between two views as whole-entity upserts; `apply/2`
  replays them. A client applying the diffs of successive views holds the
  latest view, however the events between them were batched.

  Derived fields (`delegation.delegator_grant_active`) are part of the value,
  so a change that affects an entity without touching its record (revoking the
  operator grant behind a delegation) still reaches the client.
  """

  alias CoopSubstrate.{Administrators, Devices}

  @project_kinds [:tasks, :suggestions, :delegations, :receipts, :devices, :workflows]
  @chapter_kinds [:projects, :administrators]

  @type project :: {chapter_id :: String.t(), tenant_id :: String.t(), project_id :: String.t()}
  @type scope :: project() | {chapter_id :: String.t()}
  @type kind ::
          :tasks
          | :suggestions
          | :delegations
          | :receipts
          | :devices
          | :workflows
          | :projects
          | :administrators
  @type t :: %{kind() => %{String.t() => map()}}
  @type change :: %{kind: kind(), id: String.t(), value: map() | nil}

  @doc "The empty view of a scope's shape: a project's (the default) or a chapter's."
  @spec empty(scope()) :: t()
  def empty(scope \\ {nil, nil, nil}), do: Map.new(kinds(scope), &{&1, %{}})

  defp kinds({_chapter}), do: @chapter_kinds
  defp kinds({_, _, _}), do: @project_kinds

  @doc "The view of `scope` as `principal` reads it (nil: no reader, so no devices)."
  @spec select(map(), scope(), String.t() | nil) :: t()
  def select(gate, scope, principal \\ nil)

  def select(gate, {chapter}, _principal) do
    %{
      projects:
        Map.new(
          Administrators.projects(gate.orchestration, chapter),
          &{project_id(&1), json(&1)}
        ),
      administrators:
        Map.new(Administrators.keys(gate, chapter), &{&1.key_id, Map.delete(&1, :key_id)})
    }
  end

  def select(gate, {chapter, tenant, project} = scope, principal) do
    o = gate.orchestration

    %{
      tasks:
        for(
          {{^chapter, ^tenant, ^project, id}, task} <- o.tasks,
          into: %{},
          do: {id, task(task)}
        ),
      suggestions:
        for({id, s} <- o.suggestions, in_scope?(s, scope), into: %{}, do: {id, suggestion(s)}),
      delegations:
        for(
          {id, d} <- o.delegations,
          in_scope?(d, scope),
          into: %{},
          do: {id, delegation(d, o.grants)}
        ),
      receipts:
        for(
          {id, r} <- o.custody_receipts,
          in_scope?(r, scope),
          into: %{},
          do: {id, json(Map.take(r, [:digest, :principal_id]))}
        ),
      devices: Map.new(Devices.of(gate, principal, scope), &{&1.id, Map.delete(&1, :id)}),
      workflows: workflows(o, scope)
    }
  end

  # Every workflow the project's blueprints define, under the revision now
  # governing it, keyed `roadmap/workflow` (each part URI-encoded), with its
  # definitions in the blueprint's order: what a person needs to run it.
  defp workflows(o, scope) do
    for {roadmap_key, roadmap} <- get_in(o, [:hierarchy, scope, :roadmaps]) || %{},
        {workflow_id, %{revision: revision}} <- roadmap.workflows,
        into: %{} do
      %{blueprint: blueprint, source: source} = o.blueprints[revision]
      {:ok, workflow} = TaskCore.Blueprint.workflow(blueprint, roadmap_key, workflow_id)

      {URI.encode_www_form(roadmap_key) <> "/" <> URI.encode_www_form(workflow_id),
       json(%{
         roadmap_key: roadmap_key,
         roadmap_name: roadmap.name,
         workflow_id: workflow_id,
         name: workflow["name"],
         revision_event_id: revision,
         source: Map.take(source, [:repository, :commit, :path]),
         definitions:
           Enum.map(workflow["tasks"], &Map.take(&1, ~w(id title description depends_on)))
       })}
    end
  end

  defp project_id(p),
    do: URI.encode_www_form(p.tenant_id) <> "/" <> URI.encode_www_form(p.project_id)

  @doc "Entities whose value differs, in a stable order; `value: nil` would mean removed."
  @spec diff(t(), t()) :: [change()]
  def diff(old, new) do
    for kind <- @project_kinds ++ @chapter_kinds,
        Map.has_key?(new, kind),
        id <-
          old[kind]
          |> Map.keys()
          |> Enum.concat(Map.keys(new[kind]))
          |> Enum.uniq()
          |> Enum.sort(),
        old[kind][id] != new[kind][id],
        do: %{kind: kind, id: id, value: new[kind][id]}
  end

  @spec apply(t(), [change()]) :: t()
  def apply(view, changes) do
    Enum.reduce(changes, view, fn
      %{kind: kind, id: id, value: nil}, acc -> update_in(acc, [kind], &Map.delete(&1, id))
      %{kind: kind, id: id, value: value}, acc -> put_in(acc, [kind, id], value)
    end)
  end

  # -- public values ----------------------------------------------------------------

  defp in_scope?(entity, {chapter, tenant, project}),
    do: {entity.chapter_id, entity.tenant_id, entity.project_id} == {chapter, tenant, project}

  defp task(t) do
    t
    |> Map.take(~w(state version title description definition_of_done timing timing_version
                   timing_delegation_id last_event_id started_by cancellation)a)
    |> Map.put(:dod, dod(t.dod))
    |> Map.put(:readiness, readiness(t[:readiness]))
    |> Map.put(:blueprint, t[:blueprint])
    |> json()
  end

  # The acknowledging public key stays out; its key ID tells a device whether
  # the acknowledgement is its own, which queuing and readiness require.
  defp readiness(nil), do: nil

  defp readiness(r) do
    %{
      event_id: r.event_id,
      artifact_requirements: r.artifact_requirements,
      predecessor_ids: r.predecessor_ids,
      sop_digest: r.sop_digest,
      acknowledgment:
        r.acknowledgment &&
          Map.take(r.acknowledgment, [:principal_id, :key_id, :custody_receipt_id])
    }
  end

  # Evidence and the submitter's key stay out: the feed says that evidence was
  # submitted and reviewed, not what it was.
  defp dod(nil), do: nil

  defp dod(d) do
    %{
      event_id: d.event_id,
      criteria: d.criteria,
      definition_ref: d.definition_ref,
      submission: d.submission && Map.take(d.submission, [:event_id, :principal_id]),
      review:
        d.review &&
          Map.take(d.review, [:event_id, :principal_id, :submission_event_id, :decision, :reason])
    }
  end

  defp suggestion(s) do
    s
    |> Map.take(~w(task_id kind change principal_id base_timing_version rationale
                   rationale_receipt_id status reason reason_receipt_id resolved_by_event_id)a)
    |> json()
  end

  defp delegation(d, grants) do
    d
    |> Map.take(~w(delegator_principal_id operator_grant_id principal_id key_id kinds task_ids
                   states window max_block_ms budget used active)a)
    |> Map.put(:delegator_grant_active, grants[d.operator_grant_id][:active] == true)
    |> json()
  end

  # Canonical byte strings become lowercase hex; everything else here is
  # already JSON-shaped (atoms encode as strings).
  defp json({:bytes, bytes}), do: Base.encode16(bytes, case: :lower)
  defp json(%{} = map), do: Map.new(map, fn {k, v} -> {k, json(v)} end)
  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value), do: value
end
