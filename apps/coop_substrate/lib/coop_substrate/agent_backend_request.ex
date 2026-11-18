defmodule CoopSubstrate.AgentBackendRequest do
  @moduledoc """
  Closed staging requests for the reference durable backend receiver.

  A trusted host supplies the exact plan and the receipt returned by
  `CoopSubstrate.Log.admit_agent_launch/3`, together with a separately pinned
  backend store identity. This module checks their structural consistency and
  recomputes both plan digests. It does not authenticate the caller or receipt,
  read current signed authority, contact the receiver, or grant permission to
  execute. Untrusted request bodies must never be treated as Log receipts.

  The reference receiver persists a request identity or a permanent fence. It
  starts no execution. An accepted response is not execution evidence, a fence
  is not verified termination, and an unknown lookup is not proof of absence.
  These responses must not be passed to an ExecutionPort/RecoveryPort as such
  evidence. No `verified: true` observation is produced here.

  Requests disclose only stable identifiers, the complete plan digest and its
  admitted deadline. They contain no plan contents, grants, lease token or
  credentials. The receiver owns the current-time deadline check; a builder
  result does not establish freshness or make dispatch atomic with revocation.
  """

  alias AgentCore.Attempts
  alias CoopSubstrate.AgentLaunchAdmission

  @request_schema "bizkit.agent-backend-request.v1"
  @receipt_schema "bizkit.agent-backend-receipt.v1"
  @error_schema "bizkit.agent-backend-error.v1"
  @store ~r/\Aagent-backend-store:[0-9a-f]{32}\z/
  @effect ~r/\Aagent-run:[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  @backend ~r/\Aagent-backend:[0-9a-f]{32}\z/
  @hex_digest ~r/\A[0-9a-f]{64}\z/
  @utc_time ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|\+00:00)\z/
  @max_bigint 9_223_372_036_854_775_807
  @execution_binding ~w(admission_id plan_digest execution_deadline)
  @errors %{
    "effect_fenced" => :agent_backend_effect_fenced,
    "binding_conflict" => :agent_backend_binding_conflict,
    "deadline_expired" => :agent_backend_deadline_expired,
    "invalid_request" => :agent_backend_invalid_request,
    "invalid_arguments" => :agent_backend_invalid_arguments,
    "invalid_store" => :agent_backend_invalid_store,
    "store_missing" => :agent_backend_store_missing,
    "store_exists" => :agent_backend_store_exists,
    "store_identity_mismatch" => :agent_backend_store_identity_mismatch,
    "database_busy" => :agent_backend_database_busy,
    "database_unavailable" => :agent_backend_database_unavailable
  }

  @doc "Build a reference create request from a trusted plan and exact Log receipt."
  @spec create(map(), map(), String.t()) :: {:ok, map()} | {:error, atom()}
  def create(plan, admission, store_id) do
    with true <- valid_store?(store_id) or {:error, :invalid_agent_backend_request},
         :ok <- valid_admission(admission),
         {:ok, descriptor_digest, plan_digest} <- digests(plan),
         true <-
           (plan.effect_id == admission.effect_id and
              descriptor_digest == admission.descriptor_digest and
              plan_digest == admission.plan_digest) or
             {:error, :agent_backend_admission_mismatch} do
      {:ok,
       target("create", admission.effect_id, store_id)
       |> Map.merge(%{
         "admission_id" => admission.admission_id,
         "plan_digest" => Base.encode16(plan_digest, case: :lower),
         "execution_deadline" => canonical_time(admission.execution_deadline)
       })}
    end
  end

  @doc "Build a permanent future-create fence; this does not request verified termination."
  @spec fence(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def fence(effect_id, store_id), do: target_request("fence", effect_id, store_id)

  @doc "Build a lookup whose unknown result must not be promoted to an absence proof."
  @spec lookup(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def lookup(effect_id, store_id), do: target_request("lookup", effect_id, store_id)

  @doc """
  Check a decoded reference response against its exact request.

  Success returns the same closed string-key map, without adding authority or
  verification flags. Known errors use a finite atom mapping and must carry
  the request's pinned store identity. A null or different error store identity
  cannot establish a response to this valid request and is rejected.

  Create binds every request field, including the exact deadline spelling.
  Lookup binds the store and effect and checks the returned binding's shape;
  a recovering host must separately compare that complete binding with its
  retained original create request before using the observation.
  """
  @spec verify_response(map(), term()) :: {:ok, map()} | {:error, atom()}
  def verify_response(request, decoded_map) do
    if valid_request?(request),
      do: response(request, decoded_map),
      else: {:error, :invalid_agent_backend_request}
  end

  @doc """
  Bind a lookup to the original create request and any previously observed
  backend identity. Unknown lookups and fences without a retained identity
  cannot recover an execution. A match checks binding only.
  """
  @spec verify_lookup_binding(map(), term(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def verify_lookup_binding(create, decoded_map, backend_id \\ nil) do
    with true <-
           (match?(%{"operation" => "create"}, create) and valid_request?(create) and
              (is_nil(backend_id) or valid_backend?(backend_id))) or
             {:error, :invalid_agent_backend_request},
         {:ok, lookup} <- lookup(create["effect_id"], create["store_id"]),
         {:ok, receipt} <- verify_response(lookup, decoded_map),
         true <- complete_binding?(receipt) or {:error, :agent_backend_identity_unobserved},
         true <-
           (Map.take(receipt, @execution_binding) == Map.take(create, @execution_binding) and
              (is_nil(backend_id) or receipt["backend_id"] == backend_id)) or
             {:error, :agent_backend_binding_conflict} do
      {:ok, receipt}
    end
  end

  defp target_request(operation, effect_id, store_id) do
    if valid_effect?(effect_id) and valid_store?(store_id),
      do: {:ok, target(operation, effect_id, store_id)},
      else: {:error, :invalid_agent_backend_request}
  end

  defp target(operation, effect_id, store_id) do
    %{
      "schema" => @request_schema,
      "operation" => operation,
      "store_id" => store_id,
      "effect_id" => effect_id
    }
  end

  defp valid_admission(
         %{
           admission_id: id,
           effect_id: effect,
           epoch: epoch,
           claim_version: claim_version,
           version: version,
           source_seq: seq,
           source_hash: source_hash,
           descriptor_digest: descriptor_digest,
           plan_digest: plan_digest,
           admitted_at: admitted_at,
           execution_deadline: deadline,
           disposition: disposition
         } = receipt
       )
       when map_size(receipt) == 12 do
    if valid_effect?(effect) and id == admission_id(effect) and positive_bigint?(epoch) and
         positive_bigint?(claim_version) and positive_bigint?(version) and
         version == claim_version + 1 and positive_bigint?(seq) and
         digest?(source_hash) and digest?(descriptor_digest) and digest?(plan_digest) and
         disposition in [:admitted, :existing] and utc_datetime?(admitted_at) and
         utc_datetime?(deadline) and DateTime.compare(admitted_at, deadline) == :lt,
       do: :ok,
       else: {:error, :invalid_agent_backend_admission}
  end

  defp valid_admission(_), do: {:error, :invalid_agent_backend_admission}

  defp digests(plan) do
    with {:ok, descriptor} <- Attempts.descriptor_digest(plan),
         {:ok, complete} <- AgentLaunchAdmission.plan_digest(plan) do
      {:ok, descriptor, complete}
    else
      _ -> {:error, :invalid_agent_backend_request}
    end
  rescue
    _ -> {:error, :invalid_agent_backend_request}
  end

  defp valid_request?(
         %{
           "schema" => @request_schema,
           "operation" => "create",
           "store_id" => store,
           "effect_id" => effect,
           "admission_id" => id,
           "plan_digest" => digest,
           "execution_deadline" => deadline
         } = request
       )
       when map_size(request) == 7 do
    valid_store?(store) and valid_effect?(effect) and id == admission_id(effect) and
      hex_digest?(digest) and match?({:ok, _}, wire_time(deadline))
  end

  defp valid_request?(
         %{
           "schema" => @request_schema,
           "operation" => operation,
           "store_id" => store,
           "effect_id" => effect
         } = request
       )
       when map_size(request) == 4 and operation in ["fence", "lookup"],
       do: valid_store?(store) and valid_effect?(effect)

  defp valid_request?(_), do: false

  defp response(
         request,
         %{"schema" => @error_schema, "error" => code, "store_id" => store} = error
       )
       when map_size(error) == 3 do
    case {store == request["store_id"], Map.fetch(@errors, code)} do
      {true, {:ok, reason}} -> {:error, reason}
      _ -> {:error, :invalid_agent_backend_response}
    end
  end

  defp response(
         request,
         %{
           "schema" => @receipt_schema,
           "operation" => operation,
           "store_id" => store,
           "effect_id" => effect,
           "state" => _,
           "backend_id" => _,
           "admission_id" => _,
           "plan_digest" => _,
           "execution_deadline" => _,
           "disposition" => _,
           "execution_started" => false,
           "termination_verified" => false,
           "future_creates_refused" => _
         } = receipt
       )
       when map_size(receipt) == 13 do
    if operation == request["operation"] and store == request["store_id"] and
         effect == request["effect_id"] and outcome?(request, receipt),
       do: {:ok, receipt},
       else: {:error, :invalid_agent_backend_response}
  end

  defp response(_, _), do: {:error, :invalid_agent_backend_response}

  defp outcome?(%{"operation" => "create"} = request, receipt) do
    receipt["state"] == "accepted" and receipt["disposition"] in ["created", "existing"] and
      receipt["future_creates_refused"] == false and complete_binding?(receipt) and
      receipt["admission_id"] == request["admission_id"] and
      receipt["plan_digest"] == request["plan_digest"] and
      receipt["execution_deadline"] == request["execution_deadline"]
  end

  defp outcome?(%{"operation" => "fence"}, receipt), do: fenced?(receipt)

  defp outcome?(%{"operation" => "lookup"}, %{"state" => "accepted"} = receipt) do
    receipt["disposition"] == "existing" and receipt["future_creates_refused"] == false and
      complete_binding?(receipt)
  end

  defp outcome?(%{"operation" => "lookup"}, %{"state" => "fenced"} = receipt),
    do: fenced?(receipt)

  defp outcome?(%{"operation" => "lookup"}, %{"state" => "unknown"} = receipt) do
    receipt["disposition"] == "unknown" and receipt["future_creates_refused"] == false and
      empty_binding?(receipt)
  end

  defp outcome?(_, _), do: false

  defp fenced?(receipt) do
    receipt["state"] == "fenced" and receipt["disposition"] == "fenced" and
      receipt["future_creates_refused"] == true and
      (empty_binding?(receipt) or complete_binding?(receipt))
  end

  defp complete_binding?(receipt) do
    valid_backend?(receipt["backend_id"]) and
      receipt["admission_id"] == admission_id(receipt["effect_id"]) and
      hex_digest?(receipt["plan_digest"]) and
      match?({:ok, _}, wire_time(receipt["execution_deadline"]))
  end

  defp empty_binding?(receipt) do
    Enum.all?(~w(backend_id admission_id plan_digest execution_deadline), &is_nil(receipt[&1]))
  end

  defp admission_id(effect),
    do: "agent-admission:" <> Base.encode16(:crypto.hash(:sha256, effect), case: :lower)

  defp digest?(value), do: is_binary(value) and byte_size(value) == 32
  defp positive_bigint?(value), do: is_integer(value) and value in 1..@max_bigint
  defp valid_store?(value), do: matches?(value, @store, 52)
  defp valid_effect?(value), do: matches?(value, @effect, 138)
  defp valid_backend?(value), do: matches?(value, @backend, 46)
  defp hex_digest?(value), do: matches?(value, @hex_digest, 64)

  defp matches?(value, pattern, maximum),
    do: is_binary(value) and byte_size(value) <= maximum and Regex.match?(pattern, value)

  defp utc_datetime?(
         %DateTime{
           calendar: Calendar.ISO,
           time_zone: "Etc/UTC",
           zone_abbr: "UTC",
           utc_offset: 0,
           std_offset: 0,
           year: year
         } = value
       )
       when year in 1..9999 do
    # Round-tripping also rejects forged DateTime fields and extra struct keys.
    case DateTime.from_iso8601(DateTime.to_iso8601(value)) do
      {:ok, ^value, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp utc_datetime?(_), do: false

  defp canonical_time(%DateTime{microsecond: {microsecond, _}} = value),
    do: DateTime.to_iso8601(%{value | microsecond: {microsecond, 6}})

  defp wire_time(value) do
    if matches?(value, @utc_time, 32) do
      case DateTime.from_iso8601(value) do
        {:ok, %DateTime{year: year} = date, 0} when year in 1..9999 -> {:ok, date}
        _ -> :error
      end
    else
      :error
    end
  end
end
