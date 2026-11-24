defmodule AgentOpsStore.EventRegistrations do
  @moduledoc """
  Idempotent operational registration, never a subscription or cursor store.
  Use an ordinary host connection (not a caller-owned open transaction) so
  successful registration is committed BEFORE EventStore.ack/2 is invoked.
  The trusted host role needs INSERT/SELECT only; no mutation of existing rows.
  """
  @insert """
  INSERT INTO agent_ops.event_effect_registrations
    (subscription_name,event_id,global_seq,event_hash,effect_id,chapter_id,tenant_id,project_id)
    VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
    ON CONFLICT DO NOTHING RETURNING event_id
  """
  def register(conn, subscription, bundle) when is_pid(conn) or is_atom(conn) do
    values = [
      bundle.seq,
      bundle.hash,
      bundle.effect_id,
      bundle.chapter_id,
      bundle.tenant_id,
      bundle.project_id
    ]

    case Postgrex.query(conn, @insert, [subscription, bundle.event_id | values]) do
      {:ok, %{rows: [[_]]}} -> {:ok, :new}
      {:ok, %{rows: []}} -> existing(conn, subscription, bundle.event_id, values)
      _ -> {:error, :effect_registration_refused}
    end
  rescue
    _ -> {:error, :effect_registration_refused}
  end

  def register(_, _, _), do: {:error, :uncommitted_connection_refused}

  defp existing(conn, subscription, event_id, values) do
    sql = """
    SELECT global_seq,event_hash,effect_id,chapter_id,tenant_id,project_id
      FROM agent_ops.event_effect_registrations WHERE subscription_name=$1 AND event_id=$2
    """

    case Postgrex.query(conn, sql, [subscription, event_id]) do
      {:ok, %{rows: [^values]}} -> {:ok, :existing}
      {:ok, _} -> {:error, :event_effect_conflict}
      _ -> {:error, :effect_registration_refused}
    end
  end
end
