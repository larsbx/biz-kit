defmodule BizKit.Identity.PausedSessionStore do
  @moduledoc false
  @behaviour BizKit.Identity.SessionStore
  @name {:global, __MODULE__}

  def start_remote_keeper do
    parent = self()

    spawn(fn ->
      {:ok, _} =
        Supervisor.start_link(
          [{BizKit.Cluster.Singleton, BizKit.Identity.Sessions}],
          strategy: :one_for_one,
          name: BizKit.Identity.RaceSupervisor
        )

      send(parent, :started)
      Process.sleep(:infinity)
    end)

    receive do
      :started -> :ok
    end
  end

  def start_link, do: Agent.start_link(fn -> %{rows: %{}, pause: nil} end, name: @name)
  def pause_next_read(owner), do: Agent.update(@name, &%{&1 | pause: owner})

  def put(hash, principal, identity, at) do
    row = %{principal: principal, identity: identity, authenticated_at: at}
    Agent.update(@name, &put_in(&1, [:rows, hash], row))
  end

  def get(hash) do
    {row, owner} =
      Agent.get_and_update(@name, fn s ->
        {{Map.fetch(s.rows, hash), s.pause}, %{s | pause: nil}}
      end)

    if owner do
      ref = make_ref()
      send(owner, {:store_read, self(), ref})

      receive do
        {:resume, ^ref} -> :ok
      after
        5_000 -> raise "paused read was not resumed"
      end
    end

    row
  end

  def delete(hash), do: Agent.update(@name, &%{&1 | rows: Map.delete(&1.rows, hash)})

  def delete_principal(principal) do
    Agent.update(@name, fn s ->
      %{s | rows: Map.reject(s.rows, fn {_, row} -> row.principal == principal end)}
    end)
  end
end
