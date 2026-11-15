defmodule ResearchExchange.Server do
  @moduledoc """
  Serialized, bounded, in-memory admission adapter. No listener, executor,
  accounting ledger, award issuance, or call to Reward.accept/Reservation.settle.
  The public call surface cannot assert verifier success or select a principal.
  """
  use GenServer
  alias ResearchExchange.Evidence, as: E
  @core_snapshot_path Path.expand("../../CORE_SNAPSHOT.json", __DIR__)
  @external_resource @core_snapshot_path
  @core_snapshot @core_snapshot_path |> File.read!() |> :json.decode()
  @max_artifact 65_536
  @max_entries 128

  def start_link(config), do: GenServer.start_link(__MODULE__, config)
  def call(pid, token, tool, args), do: GenServer.call(pid, {:call, token, tool, args})
  def authenticate(pid, token), do: GenServer.call(pid, {:authenticate, token})
  # These are operator/worker ports, never registered MCP tools. Host isolation
  # is required: untrusted agents must not get BEAM/RPC access to this process.
  def observe(pid, observation, mac), do: GenServer.call(pid, {:observe, observation, mac})

  def observe_compute(pid, observation, mac),
    do: GenServer.call(pid, {:compute, observation, mac})

  def revoke(pid, token_hash), do: GenServer.call(pid, {:revoke, token_hash})
  def job(pid, id, worker_key), do: GenServer.call(pid, {:job, id, worker_key})
  def core, do: @core_snapshot

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
    {:ok, %{config: config, boot: boot, submissions: %{}, jobs: %{}, replay: %{}, version: 0}}
  end

  @impl true
  def handle_call({:authenticate, token}, _from, s), do: {:reply, auth(s, token), s}

  def handle_call({:revoke, h}, _from, s),
    do: {:reply, :ok, put_in(s.config.tokens, Map.delete(s.config.tokens, h))}

  def handle_call({:call, token, tool, args}, _from, s) do
    result = with {:ok, grant} <- auth(s, token), do: dispatch(s, grant, tool, args)

    case result do
      {:ok, value, updated} -> {:reply, {:ok, value}, updated}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  def handle_call({:job, id, key}, _from, s) do
    result =
      if E.equal?(key, s.config.worker_key) do
        case Map.fetch(s.jobs, id) do
          {:ok, j} -> {:ok, Map.take(j, [:binding, :capability, :artifact])}
          :error -> {:error, :not_found}
        end
      else
        {:error, :unauthorized}
      end

    {:reply, result, s}
  end

  def handle_call({kind, obs, mac}, _from, s) when kind in [:observe, :compute] do
    case record(s, kind, obs, mac) do
      {:ok, receipt, updated} -> {:reply, {:ok, receipt}, updated}
      {:error, reason} -> {:reply, {:error, reason}, s}
    end
  end

  defp auth(s, token)
       when is_binary(token) and byte_size(token) >= 32 and byte_size(token) <= 512 do
    case Map.get(s.config.tokens, E.hash(token)) do
      %{expires: expires} = grant ->
        if expires > now(s), do: {:ok, grant}, else: {:error, :unauthorized}

      _ ->
        {:error, :unauthorized}
    end
  end

  defp auth(_, _), do: {:error, :unauthorized}
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
        if map_size(s.submissions) >= @max_entries,
          do: {:error, :capacity},
          else: submit(s, g, lib, a)
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
            request(s, sub, a["submission_id"])
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
        b["policy_sha256"] == l["policy_sha256"]

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
        {:ok, r, s}

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

    id = E.digest("research-exchange/submission/v1", %{"boot" => s.boot, "binding" => binding})
    r = receipt(s, "submitted", id, binding, %{})
    item = %{binding: binding, artifact: a["artifact"], receipt: r}
    {:ok, r, %{s | submissions: Map.put(s.submissions, id, item), version: s.version + 1}}
  end

  defp request(s, sub, submission_id) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    binding =
      Map.merge(sub.binding, %{
        "submission_id" => submission_id,
        "nonce" => nonce,
        "boot" => s.boot,
        "expires_at" => now(s) + 300
      })

    id = E.digest("research-exchange/job/v1", binding)
    cap = E.mac(s.config.worker_key, "research-exchange/capability/v1", binding)

    r =
      receipt(s, "queued_execution_disabled", id, binding, %{
        "reservation" => "memory-only-capacity-slot",
        "credits_issued" => 0
      })

    j = %{
      binding: binding,
      artifact: sub.artifact,
      capability: cap,
      receipt: r,
      observed: false,
      compute: false,
      observations: %{}
    }

    {:ok, r, %{s | jobs: Map.put(s.jobs, id, j), version: s.version + 1}}
  end

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
         true <- now(s) < j.binding["expires_at"],
         {:ok, lib} <- Map.fetch(s.config.libraries, j.binding["library"]) |> found(),
         true <- current?(j.binding, lib),
         true <- valid_observation?(kind, obs),
         true <- E.equal?(mac, E.mac(key, domain, obs)) do
      flag = if kind == :observe, do: :observed, else: :compute

      if Map.fetch!(j, flag) do
        {:error, :observation_replay}
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
