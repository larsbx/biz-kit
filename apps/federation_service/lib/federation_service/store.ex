defmodule FederationService.Store do
  @moduledoc """
  Per-installation discovery journal, not a business ledger. One writer per
  directory. A single disk_log record commits each multi-index change; sync
  completes before acknowledgment. Incomplete tails are repaired on restart.
  Storage exhaustion fails closed; never evict tombstones or replay evidence.
  """
  use GenServer
  alias FederationCore.Marketplace
  alias FederationService.Delivery

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def call(store, op), do: GenServer.call(store, op, 15_000)

  def init(opts) do
    File.mkdir_p!(opts[:directory])
    File.chmod!(opts[:directory], 0o700)

    with {:ok, lock} <- lock(opts[:directory]) do
      log = {:federation_discovery, Path.expand(opts[:directory])}
      file = Path.join(opts[:directory], "discovery.log") |> String.to_charlist()

      case :disk_log.open(name: log, file: file, type: :halt, size: 67_108_864) do
        {:ok, ^log} ->
          restore(log, lock)

        {:repaired, ^log, _, _} ->
          restore(log, lock)

        error ->
          Port.close(lock)
          {:stop, error}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp lock(directory) do
    case System.find_executable("flock") do
      nil ->
        {:error, :flock_required}

      exe ->
        port =
          Port.open({:spawn_executable, exe}, [
            :binary,
            :exit_status,
            :use_stdio,
            args: [
              "-w",
              "1",
              "-E",
              "75",
              Path.join(directory, "writer.lock"),
              "sh",
              "-c",
              "printf 'LOCKED\n'; read -r release"
            ]
          ])

        receive do
          {^port, {:data, "LOCKED\n"}} -> {:ok, port}
          {^port, {:exit_status, _}} -> {:error, :directory_in_use}
        after
          2000 ->
            Port.close(port)
            {:error, :lock_timeout}
        end
    end
  end

  def handle_info({port, {:exit_status, _}}, %{lock: port} = s), do: {:stop, :writer_lock_lost, s}

  defp restore(log, lock) do
    base = %{
      inbox: %{},
      remote: %{},
      local: %{},
      outbox: %{},
      blocks: %{},
      events: %{},
      publications: %{}
    }

    {:ok, %{log: log, lock: lock, data: replay(log, :start, base), rates: %{}}}
  end

  defp replay(log, at, state) do
    case :disk_log.chunk(log, at) do
      :eof ->
        state

      {next, entries} when is_list(entries) ->
        replay(log, next, Enum.reduce(entries, state, &apply_changes/2))

      {_, _, _bad} ->
        raise "corrupt discovery journal"

      {:error, reason} ->
        raise "discovery journal unavailable: #{inspect(reason)}"
    end
  end

  defp apply_changes({:transaction, changes}, state),
    do:
      Enum.reduce(changes, state, fn {table, key, value}, s -> put_in(s, [table, key], value) end)

  def terminate(_, s) do
    :disk_log.close(s.log)

    if Port.info(s.lock) do
      Port.command(s.lock, "release\n")

      receive do
        {port, {:exit_status, _}} when port == s.lock -> :ok
      after
        1000 -> if Port.info(s.lock), do: Port.close(s.lock)
      end
    end
  end

  def handle_call(:snapshot, _, s), do: {:reply, s.data, s}

  def handle_call({:rate, key, limit, now}, _, s) do
    rates = Map.filter(s.rates, fn {_, {at, _}} -> at == div(now, 60) end)
    {_, n} = Map.get(rates, key, {div(now, 60), 0})

    if n >= limit or map_size(rates) >= 1024 do
      {:reply, {:error, :rate_limited}, %{s | rates: rates}}
    else
      {:reply, :ok, %{s | rates: Map.put(rates, key, {div(now, 60), n + 1})}}
    end
  end

  def handle_call({:block, key, blocked}, _, s) when is_binary(key) and is_boolean(blocked),
    do: commit(s, [{:blocks, key, blocked}], :ok)

  def handle_call({:enqueue, activity, candidate, hash, now}, _, s) do
    id = candidate.activity_id

    case s.data.inbox[id] do
      nil ->
        if map_size(s.data.inbox) >= 10_000 do
          {:reply, {:error, :capacity}, s}
        else
          item = %{
            activity: activity,
            candidate: candidate,
            hash: hash,
            received_at: now,
            status: :pending,
            attempts: 0,
            next_at: now
          }

          commit(s, [{:inbox, id, item}], {:ok, :queued})
        end

      %{hash: ^hash} ->
        {:reply, {:ok, :duplicate}, s}

      _ ->
        {:reply, {:error, :activity_conflict}, s}
    end
  end

  def handle_call({:defer, id, now}, _, s) do
    row = Map.fetch!(s.data.inbox, id)

    row = %{
      row
      | attempts: row.attempts + 1,
        next_at: now + min(3600, Integer.pow(2, min(row.attempts + 1, 11)))
    }

    commit(s, [{:inbox, id, row}], :ok)
  end

  def handle_call({:reject, id, reason}, _, s),
    do:
      commit(
        s,
        [{:inbox, id, %{Map.fetch!(s.data.inbox, id) | status: {:rejected, reason}}}],
        {:error, reason}
      )

  def handle_call({:project, id, metadata, now}, _, s) do
    item = Map.fetch!(s.data.inbox, id)
    c = item.candidate
    old = s.data.remote[c.listing_id]

    result =
      cond do
        item.status != :pending ->
          {:error, :already_processed}

        blocked?(s.data, c.actor, c.listing_id) ->
          {:error, :blocked}

        old != nil and old.actor != c.actor ->
          {:error, :owner_substitution}

        c.kind == :delete ->
          {:ok,
           %{
             actor: c.actor,
             source: URI.parse(c.actor).host,
             listing_id: c.listing_id,
             withdrawn: true,
             verified_at: now,
             metadata: nil,
             activity_id: id
           }}

        old != nil and old.withdrawn ->
          {:error, :withdrawn}

        true ->
          project_metadata(c, metadata, old, now)
      end

    case result do
      {:ok, row} ->
        commit(s, [{:remote, c.listing_id, row}, {:inbox, id, %{item | status: :applied}}], :ok)

      {:error, reason} ->
        commit(s, [{:inbox, id, %{item | status: {:rejected, reason}}}], {:error, reason})
    end
  end

  def handle_call({:publish, event_id, activity, metadata, destinations, now}, _, s) do
    fingerprint =
      :crypto.hash(:sha256, :erlang.term_to_binary({activity, metadata}))

    case s.data.events[event_id] do
      ^fingerprint ->
        {:reply, {:ok, :duplicate}, s}

      nil ->
        if map_size(s.data.events) >= 10_000 or
             map_size(s.data.outbox) + length(destinations) > 10_000 do
          {:reply, {:error, :capacity}, s}
        else
          id = activity["object"]["id"]
          old = s.data.local[id]
          withdrawn = activity["type"] == "Delete"

          if old != nil and
               (old.withdrawn or
                  (not withdrawn and metadata["revision"] <= old.metadata["revision"])) do
            {:reply, {:error, :stale_or_withdrawn}, s}
          else
            local = %{
              actor: activity["actor"],
              source: URI.parse(activity["actor"]).host,
              listing_id: id,
              withdrawn: withdrawn,
              metadata: metadata,
              verified_at: now,
              activity_id: activity["id"]
            }

            changes =
              for dest <- destinations do
                key = {activity["id"], dest}

                {:outbox, key,
                 %{
                   activity: activity,
                   destination: dest,
                   status: :pending,
                   attempts: 0,
                   next_at: now
                 }}
              end

            commit(
              s,
              changes ++
                [
                  {:local, id, local},
                  {:events, event_id, fingerprint},
                  {:publications, activity["id"], activity}
                ],
              {:ok, :published}
            )
          end
        end

      _ ->
        {:reply, {:error, :event_conflict}, s}
    end
  end

  def handle_call({:refresh, id, metadata, now}, _, s) do
    row = Map.fetch!(s.data.remote, id)

    row =
      if not row.withdrawn and not blocked?(s.data, row.actor, id) do
        row = %{row | checked_at: now}
        if row.metadata == metadata, do: %{row | verified_at: now}, else: row
      else
        row
      end

    commit(s, [{:remote, id, row}], :ok)
  end

  def handle_call({:reconcile, actor, peers, now}, _, s) do
    {changes, stats} = Delivery.plan(s.data, actor, peers, now)
    if changes == [], do: {:reply, {:ok, stats}, s}, else: commit(s, changes, {:ok, stats})
  end

  def handle_call({:delivery, key, success, now}, _, s) do
    row = Map.fetch!(s.data.outbox, key)
    attempts = row.attempts + 1

    row = %{
      row
      | attempts: attempts,
        status:
          if(row.status == :pending,
            do: if(success, do: :delivered, else: :pending),
            else: row.status
          ),
        next_at: now + min(3600, Integer.pow(2, min(attempts, 11)))
    }

    row = Map.put(row, :last_delivery, %{at: now, acknowledged: success})
    row = if success, do: Map.put_new(row, :acknowledged_at, now), else: row
    commit(s, [{:outbox, key, row}], :ok)
  end

  defp project_metadata(c, m, old, now) do
    with {:ok, _} <- Marketplace.validate_metadata(m, c.actor),
         true <- m["id"] == c.listing_id do
      cond do
        old != nil and m["revision"] <= old.metadata["revision"] ->
          {:error, :stale_revision}

        true ->
          {:ok,
           %{
             actor: c.actor,
             source: URI.parse(c.actor).host,
             listing_id: c.listing_id,
             withdrawn: false,
             verified_at: now,
             metadata: m,
             metadata_url: c.metadata_url,
             checked_at: now,
             activity_id: c.activity_id
           }}
      end
    else
      _ -> {:error, :invalid_metadata_binding}
    end
  end

  defp commit(s, changes, result) do
    with :ok <- :disk_log.log(s.log, {:transaction, changes}), :ok <- :disk_log.sync(s.log) do
      {:reply, result, %{s | data: apply_changes({:transaction, changes}, s.data)}}
    else
      error -> {:stop, {:storage_failure, error}, {:error, :storage_failure}, s}
    end
  end

  def blocked?(data, actor, listing),
    do:
      data.blocks[actor] == true or data.blocks[URI.parse(actor).host] == true or
        data.blocks[listing] == true
end
