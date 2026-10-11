defmodule CoopSubstrate.Projections.Tasks do
  @moduledoc """
  Pure task/grant state for the first common-ledger transition. It has no Repo,
  side effects, or snapshot input. The append gate uses the same fold as replay.
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.Protocol.Envelope

  @impl true
  def init, do: %{grants: %{}, tasks: %{}, proposals: %{}}

  @impl true
  def handle_event(%Envelope{type: "TaskOperatorGrantedV1", payload: p} = env, state) do
    grant = %{
      chapter_id: env.chapter_id,
      tenant_id: p["tenant_id"],
      project_id: p["project_id"],
      principal_id: p["principal_id"],
      key_id: p["key_id"],
      pubkey: elem(p["pubkey"], 1),
      active: true
    }

    put_in(state, [:grants, Access.key(env.event_id)], grant)
  end

  def handle_event(%Envelope{type: "TaskOperatorRevokedV1", payload: p}, state) do
    put_in(state, [:grants, p["authorization_event_id"], :active], false)
  end

  def handle_event(%Envelope{type: "TaskBaselineRecordedV1", payload: p} = env, state) do
    task = %{
      state: "inbox",
      version: 1,
      title: p["title"],
      definition_of_done: p["definition_of_done"],
      definition_ref: p["definition_ref"],
      legacy_row_id: p["legacy_row_id"],
      source_digest: p["source_digest"],
      baseline_event_id: env.event_id,
      last_event_id: env.event_id
    }

    put_in(state, [:tasks, Access.key(task_key(env))], task)
  end

  def handle_event(%Envelope{type: "TaskProposedV1"} = env, state) do
    state
    |> update_in([:tasks, task_key(env)], fn task ->
      %{task | state: "proposed", version: task.version + 1, last_event_id: env.event_id}
    end)
    |> put_in([:proposals, Access.key(env.event_id)], env)
  end

  def handle_event(_env, state), do: state

  def task_key(%Envelope{chapter_id: ch, payload: p}),
    do: {ch, p["tenant_id"], p["project_id"], p["task_id"]}
end
