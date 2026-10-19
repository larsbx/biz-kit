defmodule CoopSubstrate.Feed.View do
  @moduledoc """
  What a change-feed client sees of one project: its tasks, suggestions,
  delegations and custody receipts, each reduced to a whitelisted, JSON-safe
  value (docs/architecture/2026-10-18-change-feed.md). A task carries its
  readiness definition and SOP acknowledgement, and a receipt its digest, so
  a person's device can take each lifecycle step
  (docs/architecture/2026-10-19-lifecycle.md).

  Pure. `select/2` reads a view out of the task projection; `diff/2` gives the
  changes between two views as whole-entity upserts; `apply/2` replays them.
  A client applying the diffs of successive views holds the latest view,
  however the events between them were batched.

  Derived fields (`delegation.delegator_grant_active`) are part of the value,
  so a change that affects an entity without touching its record (revoking the
  operator grant behind a delegation) still reaches the client.
  """

  @kinds [:tasks, :suggestions, :delegations, :receipts]

  @type scope :: {chapter_id :: String.t(), tenant_id :: String.t(), project_id :: String.t()}
  @type kind :: :tasks | :suggestions | :delegations | :receipts
  @type t :: %{kind() => %{String.t() => map()}}
  @type change :: %{kind: kind(), id: String.t(), value: map() | nil}

  @spec empty() :: t()
  def empty, do: Map.new(@kinds, &{&1, %{}})

  @spec select(map(), scope()) :: t()
  def select(o, {chapter, tenant, project} = scope) do
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
        )
    }
  end

  @doc "Entities whose value differs, in a stable order; `value: nil` would mean removed."
  @spec diff(t(), t()) :: [change()]
  def diff(old, new) do
    for kind <- @kinds,
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
                   timing_delegation_id last_event_id)a)
    |> Map.put(:dod, dod(t.dod))
    |> Map.put(:readiness, readiness(t[:readiness]))
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
      review: d.review && Map.take(d.review, [:event_id, :principal_id, :decision, :reason])
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
