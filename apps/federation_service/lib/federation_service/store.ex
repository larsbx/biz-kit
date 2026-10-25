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

  def handle_info({:DOWN, ref, :process, pid, _}, s) do
    subscribers =
      case s.subscribers[pid] do
        {^ref, _} -> Map.delete(s.subscribers, pid)
        _ -> s.subscribers
      end

    worker = if match?(%{monitor: ^ref}, s.gossip_worker), do: nil, else: s.gossip_worker
    {:noreply, %{s | subscribers: subscribers, gossip_worker: worker}}
  end

  defp restore(log, lock) do
    base = %{
      inbox: %{},
      remote: %{},
      local: %{},
      outbox: %{},
      blocks: %{},
      events: %{},
      publications: %{},
      redeliveries: %{}
    }

    base =
      Map.merge(base, %{
        gossip_inbox: %{},
        gossip_sends: %{},
        sync_incoming: %{},
        sync_outgoing: %{},
        sync_meta: %{}
      })

    {:ok,
     %{
       log: log,
       lock: lock,
       data: replay(log, :start, base),
       rates: %{},
       subscribers: %{},
       gossip_worker: nil
     }}
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

  def handle_call({:sync_put, table, key, row}, _, s)
      when table in [:sync_incoming, :sync_outgoing] do
    case Map.fetch!(s.data, table)[key] do
      nil ->
        if map_size(Map.fetch!(s.data, table)) >= 128 do
          {:reply, {:error, :capacity}, s}
        else
          meta =
            if s.data.sync_meta == %{},
              do: [
                {:sync_meta, :journal, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}
              ],
              else: []

          commit(s, meta ++ [{table, key, row}], :ok)
        end

      %{message: message} when message == row.message ->
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, :catchup_conflict}, s}
    end
  end

  def handle_call({:sync_complete, key}, _, s) do
    row = Map.fetch!(s.data.sync_incoming, key)

    if row.status == :pending,
      do: commit(s, [{:sync_incoming, key, %{row | status: :complete}}], :ok),
      else: {:reply, :ok, s}
  end

  def handle_call({:sync_sent, key, now}, _, s) do
    table = if Map.has_key?(s.data.sync_outgoing, key), do: :sync_outgoing, else: :sync_incoming
    row = Map.fetch!(Map.fetch!(s.data, table), key)
    commit(s, [{table, key, %{row | last_sent: now}}], :ok)
  end

  def handle_call({:sync_receipt, m, scope, peer_key, local_key, now}, _, s) do
    found =
      Enum.find(s.data.sync_outgoing, fn {_, row} ->
        offer = row.message

        not blocked?(s.data, m["from"], "") and offer["round"] == m["round"] and
          offer["batch"] == m["batch"] and
          offer["from"] == m["to"] and offer["to"] == m["from"] and
          offer["expires"] == m["expires"] and offer["expires"] > now and
          offer["publisher"] == local_key and
          Map.take(offer, ~w(halaqa_id charter_hash epoch)) === scope and row.peer_key == peer_key
      end)

    core = Map.drop(m, ~w(signature announcement))

    case found do
      {key, %{status: :pending} = row} ->
        receipt = %{message: core, signed_message: m, received_at: now}

        commit(
          s,
          [{:sync_outgoing, key, Map.merge(row, %{status: :complete, receipt: receipt})}],
          :ok
        )

      {_, %{status: :complete, receipt: %{message: ^core}}} ->
        {:reply, :ok, s}

      _ ->
        {:reply, {:error, :catchup_refused}, s}
    end
  end

  def handle_call(:claim_gossip_worker, {pid, _}, s) do
    case s.gossip_worker do
      nil -> {:reply, :ok, %{s | gossip_worker: %{pid: pid, monitor: Process.monitor(pid)}}}
      %{pid: ^pid} -> {:reply, :ok, s}
      _ -> {:reply, {:error, :gossip_worker_exists}, s}
    end
  end

  def handle_call(:subscribe, {pid, _}, s) do
    cond do
      Map.has_key?(s.subscribers, pid) ->
        {:reply, :ok, s}

      map_size(s.subscribers) >= 32 ->
        {:reply, {:error, :capacity}, s}

      true ->
        {:reply, :ok,
         %{s | subscribers: Map.put(s.subscribers, pid, {Process.monitor(pid), false})}}
    end
  end

  def handle_call(:notifications_received, {pid, _}, s) do
    subscribers = Map.update(s.subscribers, pid, {nil, false}, fn {ref, _} -> {ref, false} end)

    subscribers =
      if subscribers[pid] == {nil, false}, do: Map.delete(subscribers, pid), else: subscribers

    {:reply, :ok, %{s | subscribers: subscribers}}
  end

  def handle_call({:gossip_enqueue, item}, _, s) do
    id = item.candidate.activity_id

    cross = s.data.inbox[id]

    case if(cross == nil, do: s.data.gossip_inbox[id], else: {:cross, cross}) do
      {:cross, %{activity: activity}} when activity == item.activity ->
        {:reply, {:ok, :duplicate}, s}

      {:cross, _} ->
        {:reply, {:error, :activity_conflict}, s}

      nil ->
        if map_size(s.data.gossip_inbox) >= 10_000,
          do: {:reply, {:error, :capacity}, s},
          else: commit(s, [{:gossip_inbox, id, item}], {:ok, :queued})

      %{hash: hash} when hash == item.hash ->
        {:reply, {:ok, :duplicate}, s}

      _ ->
        {:reply, {:error, :activity_conflict}, s}
    end
  end

  def handle_call({:gossip_project, id, metadata, now}, _, s),
    do: project(s, :gossip_inbox, id, metadata, now)

  def handle_call({:gossip_reject, id, reason}, _, s) do
    row = Map.fetch!(s.data.gossip_inbox, id)
    commit(s, [{:gossip_inbox, id, %{row | status: {:rejected, reason}}}], {:error, reason})
  end

  def handle_call({:gossip_sent, topic, id, now}, _, s) do
    key = {topic, id}

    if not Map.has_key?(s.data.gossip_sends, key) and map_size(s.data.gossip_sends) >= 10_000,
      do: {:reply, {:error, :capacity}, s},
      else: commit(s, [{:gossip_sends, key, now}], :ok)
  end

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

    cross = s.data.gossip_inbox[id]

    case if(cross == nil, do: s.data.inbox[id], else: {:cross, cross}) do
      {:cross, %{activity: ^activity}} ->
        {:reply, {:ok, :duplicate}, s}

      {:cross, _} ->
        {:reply, {:error, :activity_conflict}, s}

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
    project(s, :inbox, id, metadata, now)
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
                   generation: Delivery.generation(s.data, activity["actor"], dest),
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
      if not row.withdrawn and Map.get(row, :transport) != "iroh-gossip" and
           not blocked?(s.data, row.actor, id) do
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

  def handle_call({:redeliver, actor, peers, peer, now}, _, s) do
    old = s.data.redeliveries[peer]

    cond do
      peer not in peers or peer == actor or blocked?(s.data, peer, "") ->
        {:reply, {:error, :peer_refused}, s}

      old == nil and map_size(s.data.redeliveries) >= 10_000 ->
        {:reply, {:error, :capacity}, s}

      true ->
        generation = if old == nil, do: 1, else: old.generation + 1
        request = %{actor: actor, generation: generation, requested_at: now}
        commit(s, [{:redeliveries, peer, request}], {:ok, generation})
    end
  end

  def handle_call({:delivery, key, generation, success, now}, _, s) do
    row = Map.fetch!(s.data.outbox, key)

    if generation == Map.get(row, :generation, 0) and
         generation == Delivery.generation(s.data, row.activity["actor"], row.destination) do
      record_delivery(s, key, row, generation, success, now)
    else
      {:reply, {:error, :stale_delivery}, s}
    end
  end

  defp record_delivery(s, key, row, generation, success, now) do
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

    row =
      if success do
        row
        |> Map.put_new(:acknowledged_at, now)
        |> Map.put(:acknowledged_generation, generation)
        |> Map.put(:last_acknowledged_at, now)
      else
        row
      end

    commit(s, [{:outbox, key, row}], :ok)
  end

  defp project(s, table, id, metadata, now) do
    item = Map.fetch!(Map.fetch!(s.data, table), id)
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
        row =
          if table == :gossip_inbox do
            Map.merge(row, %{
              transport: "iroh-gossip",
              halaqa_scope: Map.take(item.envelope, ~w(halaqa_id charter_hash epoch)),
              publisher_key: item.envelope["publisher"]
            })
          else
            row
          end

        commit(s, [{:remote, c.listing_id, row}, {table, id, %{item | status: :applied}}], :ok)

      {:error, reason} ->
        commit(s, [{table, id, %{item | status: {:rejected, reason}}}], {:error, reason})
    end
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
      # Notifications are hints after durability, coalesced to one per subscriber.
      subscribers =
        if Enum.any?(changes, fn {table, _, _} ->
             table in [:local, :blocks, :gossip_inbox, :sync_incoming, :sync_outgoing]
           end) do
          Map.new(s.subscribers, fn {pid, {ref, pending}} ->
            unless pending, do: send(pid, {:discovery_committed, self()})
            {pid, {ref, true}}
          end)
        else
          s.subscribers
        end

      {:reply, result,
       %{s | data: apply_changes({:transaction, changes}, s.data), subscribers: subscribers}}
    else
      error -> {:stop, {:storage_failure, error}, {:error, :storage_failure}, s}
    end
  end

  def blocked?(data, actor, listing),
    do:
      data.blocks[actor] == true or data.blocks[URI.parse(actor).host] == true or
        data.blocks[listing] == true
end
