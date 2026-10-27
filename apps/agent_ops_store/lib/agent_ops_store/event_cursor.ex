defmodule AgentOpsStore.EventCursor do
  @moduledoc """
  Host-only discovery checkpoint storage. One SQL transaction registers an
  entire event's reconciliation effect (or no-op receipt) before checkpointing.
  No launch, grant, execution-attempt registration or business append occurs.
  Apply migration 004; grant only SELECT and the reviewed commit function to
  a host role distinct from the migration owner. Never expose this port to agents.
  """

  def snapshot(conn, home, subscriber) do
    case Postgrex.query(
           conn,
           "SELECT global_seq,global_hash FROM agent_ops.event_cursors WHERE home_id=$1 AND subscriber=$2",
           [home, subscriber]
         ) do
      {:ok, %{rows: [[seq, hash]]}} -> {:ok, %{seq: seq, hash: hash}}
      {:ok, %{rows: []}} -> {:ok, %{seq: 0, hash: nil}}
      _ -> {:error, :cursor_store_unavailable}
    end
  end

  def commit(conn, home, subscriber, expected, bundle) do
    args = [
      home,
      subscriber,
      expected.seq,
      expected.hash,
      bundle.seq,
      bundle.event_id,
      bundle.prev_hash,
      bundle.hash,
      bundle.effect_id,
      bundle.chapter_id,
      bundle.tenant_id,
      bundle.project_id
    ]

    sql = "SELECT agent_ops.commit_event_registration($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)"

    case Postgrex.query(conn, sql, args) do
      {:ok, %{rows: [["new"]]}} ->
        {:ok, :new}

      {:ok, %{rows: [["existing"]]}} ->
        {:ok, :existing}

      {:error, %Postgrex.Error{postgres: %{code: :serialization_failure}}} ->
        {:error, :cursor_conflict}

      _ ->
        {:error, :cursor_commit_refused}
    end
  rescue
    _ -> {:error, :cursor_commit_refused}
  end
end
