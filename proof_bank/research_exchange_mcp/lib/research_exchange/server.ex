defmodule ResearchExchange.Server do
  @moduledoc """
  Serialized, bounded admission adapter with optional SQLite persistence. No listener, executor,
  accounting ledger, award issuance, or call to Reward.accept/Reservation.settle.
  The public call surface cannot assert verifier success or select a principal.
  """
  use GenServer
  alias ResearchExchange.Evidence, as: E
  alias ResearchExchange.SQLite
  @core_revision "d6c07ef7b57e844c3aaad8d2c7dff938098a71bf"
  @core_source "e46f8f6c12f790d6889085d072b58f92067004077a8b7f430abcb8433bbb0776"
  @max_artifact 65_536
  @max_entries 128
  @call_timeout 15_000

  def start_link(config), do: GenServer.start_link(__MODULE__, config, timeout: @call_timeout)

  def call(pid, token, tool, args),
    do: GenServer.call(pid, {:call, token, tool, args}, @call_timeout)

  def authenticate(pid, token), do: GenServer.call(pid, {:authenticate, token}, @call_timeout)
  # These are operator/worker ports, never registered MCP tools. Host isolation
  # is required: untrusted agents must not get BEAM/RPC access to this process.
  def observe(pid, observation, mac),
    do: GenServer.call(pid, {:observe, observation, mac}, @call_timeout)

  def observe_compute(pid, observation, mac),
    do: GenServer.call(pid, {:compute, observation, mac}, @call_timeout)

  def revoke(pid, token_hash), do: GenServer.call(pid, {:revoke, token_hash}, @call_timeout)
  def job(pid, id, worker_key), do: GenServer.call(pid, {:job, id, worker_key}, @call_timeout)
  def core, do: %{"revision" => @core_revision, "source_manifest_sha256" => @core_source}

  @impl true
  def init(config) do
    # Provisioning is trusted operator input, not contributor JSON.
    keys = for k <- [:receipt_key, :worker_key, :meter_key], do: Map.fetch!(config, k)
    true = Enum.all?(keys, &(is_binary(&1) and byte_size(&1) >= 32))
    true = length(Enum.uniq(keys)) == 3

    true =
      Enum.all?(config.tokens, fn {h, grant} ->
        hex?(h, 64) and not Enum.any?(keys, &(E.hash(&1) == h)) and
          is_binary(grant.principal) and grant.principal != "" and
          is_integer(grant.expires) and is_list(grant.libraries) and is_list(grant.scopes)
      end)

    true =
      Enum.all?(config.libraries, fn {id, lib} ->
        id == lib["id"] and hex?(lib["revision"], 40) and hex?(lib["snapshot_sha256"], 64) and
          hex?(lib["environment_sha256"], 64) and hex?(lib["policy_sha256"], 64) and
          lib["engine"] in ["lean", "quint"] and is_integer(lib["generation"]) and
          lib["generation"] > 0
      end)

    boot = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    state = %{
      config: config,
      boot: boot,
      submissions: %{},
      jobs: %{},
      replay: %{},
      revoked: %{},
      version: 0,
      journal: nil
    }

    case Map.fetch(config, :sqlite_path) do
      :error ->
        {:ok, state}

      {:ok, path} ->
        case SQLite.open(path, config.receipt_key) do
          {:ok, port, epoch, version, data} ->
            {:ok,
             Map.merge(%{state | journal: port, version: version} |> Map.put(:epoch, epoch), data)}

          {:error, reason} ->
            {:stop, reason}
        end
    end
  end

  @impl true
  def handle_call(message, from, %{journal: nil} = s), do: transition(message, from, s)

  def handle_call({:compute, _, _}, _from, s),
    do: {:reply, {:error, :metering_disabled}, s}

  def handle_call(message, from, s) do
    with :ok <- SQLite.fence(s),
         {:reply, reply, updated} <- transition(message, from, s),
         :ok <- if(updated == s, do: :ok, else: SQLite.commit(s, updated)) do
      version = if updated == s, do: s.version, else: s.version + 1
      {:reply, reply, %{updated | version: version}}
    else
      {:error, :journal_unavailable} = error -> {:stop, :normal, error, s}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  @impl true
  def format_status(status) do
    # GenServer diagnostics must not print bearer tokens, operator keys or artifacts.
    Map.merge(status, %{state: :redacted, message: :redacted, log: []})
  end

  @impl true
  def handle_info({port, {:exit_status, _}}, %{journal: port} = s), do: {:stop, :normal, s}

  defp transition({:authenticate, token}, _from, s), do: {:reply, auth(s, token), s}

  defp transition({:revoke, h}, _from, s) do
    if Map.has_key?(s.config.tokens, h),
      do: {:reply, :ok, put_in(s.revoked[h], true)},
      else: {:reply, :ok, s}
  end

  defp transition({:call, token, tool, args}, _from, s) do
    result = with {:ok, grant} <- auth(s, token), do: dispatch(s, grant, tool, args)

    case result do
      {:ok, value, updated} -> {:reply, {:ok, value}, updated}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp transition({:job, id, key}, _from, s) do
    with true <- E.equal?(key, s.config.worker_key),
         {:ok, j} <- Map.fetch(s.jobs, id),
         {:ok, current} <- worker_job(s, j) do
      updated = if j == current, do: s, else: put_in(s.jobs[id], current)
      {:reply, {:ok, Map.take(current, [:binding, :capability, :artifact])}, updated}
    else
      false -> {:reply, {:error, :unauthorized}, s}
      :error -> {:reply, {:error, :not_found}, s}
      {:error, _} = error -> {:reply, error, s}
    end
  end

  defp transition({kind, obs, mac}, _from, s) when kind in [:observe, :compute] do
    case record(s, kind, obs, mac) do
      {:ok, receipt, updated} -> {:reply, {:ok, receipt}, updated}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp auth(s, token)
       when is_binary(token) and byte_size(token) >= 32 and byte_size(token) <= 512 do
    grant(s, E.hash(token))
  end

  defp auth(_, _), do: {:error, :unauthorized}

  defp grant(s, hash) do
    case if(s.revoked[hash], do: nil, else: s.config.tokens[hash]) do
      %{expires: expires} = grant ->
        if expires > now(s),
          do: {:ok, Map.put(grant, :credential, hash)},
          else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp now(s), do: Map.get(s.config, :clock, fn -> System.system_time(:second) end).()
  defp hex?(x, n), do: is_binary(x) and byte_size(x) == n and String.match?(x, ~r/\A[0-9a-f]+\z/)
  defp exact?(m, keys), do: is_map(m) and Enum.sort(Map.keys(m)) == Enum.sort(keys)
  defp text?(x), do: is_binary(x) and byte_size(x) in 1..128 and String.valid?(x)
  defp scope(g, name), do: if(name in g.scopes, do: :ok, else: {:error, :forbidden})

  defp library(s, g, id) do
    if id in g.libraries,
      do: Map.fetch(s.config.libraries, id) |> found(),
      else: {:error, :forbidden}
  end

  defp found({:ok, x}), do: {:ok, x}
  defp found(:error), do: {:error, :forbidden}

  defp dispatch(s, g, "library_discover", args) do
    with true <- exact?(args, []), :ok <- scope(g, "library:read") do
      libs =
        s.config.libraries
        |> Enum.filter(fn {id, _} -> id in g.libraries end)
        |> Enum.sort()
        |> Enum.map(&elem(&1, 1))

      {:ok, %{"libraries" => libs, "core" => core(), "benefits" => benefits()}, s}
    else
      false -> {:error, :invalid_arguments}
      error -> error
    end
  end

  defp dispatch(s, g, "proof_submit", a) do
    with true <-
           exact?(a, [
             "idempotency_key",
             "library",
             "revision",
             "snapshot_sha256",
             "generation",
             "target",
             "artifact",
             "artifact_sha256"
           ]),
         :ok <- scope(g, "proof:submit"),
         {:ok, lib} <- library(s, g, a["library"]),
         true <-
           text?(a["idempotency_key"]) and text?(a["target"]) and is_binary(a["artifact"]) and
             String.valid?(a["artifact"]) and byte_size(a["artifact"]) in 1..@max_artifact,
         true <-
           a["revision"] == lib["revision"] and a["snapshot_sha256"] == lib["snapshot_sha256"] and
             is_integer(a["generation"]) and a["generation"] == lib["generation"],
         true <- E.equal?(a["artifact_sha256"], E.hash(a["artifact"])) do
      replay(s, g, "proof_submit", a, fn ->
        submit(s, g, lib, a)
      end)
    else
      false -> {:error, :invalid_or_stale_binding}
      error -> error
    end
  end

  defp dispatch(s, g, "verification_request", a) do
    with true <- exact?(a, ["idempotency_key", "submission_id"]),
         true <- text?(a["idempotency_key"]),
         :ok <- scope(g, "verification:request"),
         {:ok, sub} <- owned(s.submissions, a["submission_id"], g),
         {:ok, lib} <- library(s, g, sub.binding["library"]),
         true <- current?(sub.binding, lib) do
      replay(s, g, "verification_request", a, fn ->
        cond do
          map_size(s.jobs) >= @max_entries ->
            {:error, :capacity}

          Enum.any?(s.jobs, fn {_, j} -> j.binding["submission_id"] == a["submission_id"] end) ->
            {:error, :already_requested}

          true ->
            request(s, sub, a["submission_id"], g.credential)
        end
      end)
    else
      false -> {:error, :invalid_or_stale_binding}
      error -> error
    end
  end

  defp dispatch(s, g, "receipt_get", a) do
    with true <- exact?(a, ["id"]), :ok <- scope(g, "library:read") do
      case owned(Map.merge(s.submissions, s.jobs), a["id"], g) do
        {:ok, item} ->
          with {:ok, _} <- library(s, g, item.binding["library"]) do
            {:ok, item.receipt, s}
          end

        error ->
          error
      end
    else
      false -> {:error, :invalid_arguments}
      error -> error
    end
  end

  defp dispatch(_, _, _, _), do: {:error, :unknown_tool}

  defp benefits,
    do: %{
      "purpose" => "nonprofit-open-source-research",
      "recognition" => "proposed",
      "ecosystem_credits" => "nonmonetary-policy-pending",
      "issuance_enabled" => false
    }

  defp owned(items, id, g) do
    case Map.get(items, id) do
      %{binding: %{"contributor" => p}} = item when p == g.principal -> {:ok, item}
      _ -> {:error, :not_found}
    end
  end

  defp current?(b, l),
    do:
      b["source_revision"] == l["revision"] and
        b["engine"] == l["engine"] and
        b["source_snapshot_sha256"] == l["snapshot_sha256"] and b["generation"] == l["generation"] and
        b["environment_sha256"] == l["environment_sha256"] and
        b["policy_sha256"] == l["policy_sha256"] and b["core"] == core()

  defp replay(s, g, tool, a, create) do
    key = {g.principal, a["idempotency_key"]}
    digest = E.digest("research-exchange/request/v1", %{"tool" => tool, "arguments" => a})

    case Map.get(s.replay, key) do
      nil ->
        if map_size(s.replay) >= @max_entries * 2 do
          {:error, :capacity}
        else
          case create.() do
            {:ok, r, updated} -> {:ok, r, put_in(updated.replay[key], {digest, r})}
            error -> error
          end
        end

      {^digest, r} ->
        binding = r["payload"]["binding"]

        if current?(binding, s.config.libraries[binding["library"]]),
          do: {:ok, r, s},
          else: {:error, :invalid_or_stale_binding}

      _ ->
        {:error, :idempotency_conflict}
    end
  end

  defp submit(s, g, lib, a) do
    binding = %{
      "contributor" => g.principal,
      "library" => lib["id"],
      "engine" => lib["engine"],
      "source_revision" => lib["revision"],
      "source_snapshot_sha256" => lib["snapshot_sha256"],
      "generation" => lib["generation"],
      "target" => a["target"],
      "artifact_sha256" => a["artifact_sha256"],
      "environment_sha256" => lib["environment_sha256"],
      "policy_sha256" => lib["policy_sha256"],
      "core" => core()
    }

    identity = if s.journal, do: binding, else: %{"boot" => s.boot, "binding" => binding}
    id = E.digest("research-exchange/submission/v1", identity)

    case Map.fetch(s.submissions, id) do
      {:ok, item} ->
        {:ok, item.receipt, s}

      :error when map_size(s.submissions) >= @max_entries ->
        {:error, :capacity}

      :error ->
        r = receipt(s, "submitted", id, binding, %{})
        item = %{binding: binding, artifact: a["artifact"], receipt: r}
        {:ok, r, %{s | submissions: Map.put(s.submissions, id, item), version: s.version + 1}}
    end
  end

  defp request(s, sub, submission_id, credential) do
    binding = attempt(s, Map.put(sub.binding, "submission_id", submission_id))

    id = E.digest("research-exchange/job/v1", binding)
    cap = E.mac(s.config.worker_key, "research-exchange/capability/v1", binding)

    r =
      receipt(s, "queued_execution_disabled", id, binding, %{
        "reservation" =>
          if(s.journal, do: "sqlite-capacity-slot", else: "memory-only-capacity-slot"),
        "credits_issued" => 0
      })

    j = %{
      binding: binding,
      credential: credential,
      artifact: sub.artifact,
      capability: cap,
      receipt: r,
      observed: false,
      compute: false,
      observations: %{}
    }

    {:ok, r, %{s | jobs: Map.put(s.jobs, id, j), version: s.version + 1}}
  end

  defp attempt(s, binding) do
    Map.merge(binding, %{
      "nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      "boot" => s.boot,
      "reservation_version" => s.version + 1,
      "expires_at" => now(s) + 300
    })
  end

  defp worker_job(%{journal: nil}, j), do: {:ok, j}

  defp worker_job(s, j) do
    with :ok <- current_job(s, j), false <- j.observed do
      if live_attempt?(s, j) do
        {:ok, j}
      else
        binding = attempt(s, j.binding)
        cap = E.mac(s.config.worker_key, "research-exchange/capability/v1", binding)
        {:ok, %{j | binding: binding, capability: cap}}
      end
    else
      true -> {:error, :reservation_closed}
      error -> error
    end
  end

  defp current_job(%{journal: nil}, _), do: :ok

  defp current_job(s, j) do
    with {:ok, g} <- grant(s, j.credential),
         true <- g.principal == j.binding["contributor"],
         :ok <- scope(g, "verification:request"),
         {:ok, lib} <- library(s, g, j.binding["library"]),
         true <- current?(j.binding, lib),
         true <- E.equal?(j.binding["artifact_sha256"], E.hash(j.artifact)) do
      :ok
    else
      _ -> {:error, :stale_reservation}
    end
  end

  defp live_attempt?(s, j),
    do: j.binding["boot"] == s.boot and now(s) < j.binding["expires_at"]

  defp receipt(s, status, id, binding, details) do
    E.receipt(
      %{
        "schema" => "research-exchange/evidence/v1",
        "id" => id,
        "status" => status,
        "binding" => binding,
        "recorded_at" => now(s),
        "state_version" => s.version + 1,
        "details" => details,
        "mathematical_acceptance" => false,
        "credit_issuance" => false
      },
      s.config.receipt_key
    )
  end

  defp record(s, kind, obs, mac) do
    # The observation covers the COMPLETE immutable job binding, not just a job ID.
    fields =
      if kind == :observe,
        do: ["job_id", "binding", "capability", "outcome", "evidence_sha256"],
        else: ["job_id", "binding", "capability", "cpu_milliseconds", "observation_sha256"]

    key = if kind == :observe, do: s.config.worker_key, else: s.config.meter_key

    domain =
      if kind == :observe,
        do: "research-exchange/verifier-observation/v1",
        else: "research-exchange/compute-observation/v1"

    with true <- exact?(obs, fields),
         {:ok, j} <- Map.fetch(s.jobs, obs["job_id"]) |> found(),
         true <- obs["binding"] == j.binding and E.equal?(obs["capability"], j.capability),
         :ok <- current_job(s, j),
         {:ok, lib} <- Map.fetch(s.config.libraries, j.binding["library"]) |> found(),
         true <- current?(j.binding, lib),
         true <- valid_observation?(kind, obs),
         true <- E.equal?(mac, E.mac(key, domain, obs)),
         true <- live_attempt?(s, j) or (s.journal != nil and j.observed) do
      flag = if kind == :observe, do: :observed, else: :compute

      if Map.fetch!(j, flag) do
        if s.journal != nil and j.observations[domain] == Map.delete(obs, "capability"),
          do: {:ok, j.receipt, s},
          else: {:error, :observation_replay}
      else
        status =
          if kind == :observe,
            do: "verifier_observation_recorded",
            else: "compute_observation_recorded"

        observations = Map.put(j.observations, domain, Map.delete(obs, "capability"))

        r =
          receipt(s, status, obs["job_id"], j.binding, %{
            "observations" => observations,
            "previous_receipt_sha256" => j.receipt["sha256"]
          })

        updated =
          j |> Map.put(flag, true) |> Map.put(:receipt, r) |> Map.put(:observations, observations)

        {:ok, r, %{s | jobs: Map.put(s.jobs, obs["job_id"], updated), version: s.version + 1}}
      end
    else
      _ -> {:error, :invalid_observation}
    end
  end

  defp valid_observation?(:observe, o),
    do:
      o["outcome"] in ["checker_passed", "checker_failed", "timeout"] and
        hex?(o["evidence_sha256"], 64)

  defp valid_observation?(:compute, o),
    do:
      is_integer(o["cpu_milliseconds"]) and o["cpu_milliseconds"] in 0..300_000 and
        hex?(o["observation_sha256"], 64)
end
