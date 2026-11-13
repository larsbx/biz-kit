defmodule CoopSubstrate.Procurement do
  @moduledoc """
  Private, operator-assisted procurement over the canonical Log.

  Governance enrolls businesses and grants a cooperative-scoped signing key.
  A grant is not inferred from an arbitrary caller's `authorized` flag. Every
  command, read and retry checks the current grant; writes also check the signed
  session deadline inside Log. Ordinary external payment/fulfillment remains
  an operator attestation, never bank verification or settlement.

  Live admission checks the appender clock. Historical folds use signed time,
  so expiry or revocation today cannot erase previously admitted business facts.
  Procurement batches are deliberately singleton in this first host.
  """
  alias CommerceCore.MerchantPilot.Workflow
  alias CoopSubstrate.{Crypto, Log, ProcurementDispatch}
  alias CoopSubstrate.Protocol.Envelope

  @clock Application.compile_env(:coop_substrate, :procurement_clock, System)
  @grant "ProcurementOperatorGrantedV1"
  @business "ProcurementBusinessEnrolledV1"
  @command "ProcurementCommandAdmittedV1"
  @read "ProcurementSnapshotRequestV1"
  @route "ProcurementDispatchRouteV1"
  @dispatch_request "ProcurementDispatchRequestedV1"
  @dispatch_step "ProcurementDispatchStepV1"
  @types [@grant, @business, @command, @read, @route, @dispatch_request, @dispatch_step]
  @fields %{
    "request" => ~w(buyer_business_id description quantity currency needed_by_ms consent_ref)a,
    "qualify" => ~w(evidence_ref)a,
    "quote" => ~w(quote_id merchant_business_id revision total_minor currency expires_at_ms source_ref)a,
    "accept" => ~w(quote_id revision buyer_business_id evidence_ref)a,
    "fulfill" => ~w(evidence_ref)a,
    "cancel" => ~w(evidence_ref)a,
    "dispute" => ~w(evidence_ref)a,
    "payment_evidence" => ~w(evidence_ref)a
  }
  @actions Map.new(~w(request qualify quote accept fulfill cancel dispute payment_evidence)a,
    &{Atom.to_string(&1), &1})

  def event?(type), do: type in @types
  def clock_ms, do: @clock.system_time(:millisecond)
  def init, do: %{grants: %{}, businesses: %{}, requests: %{}, commands: %{}, events: %{}, dispatch: ProcurementDispatch.init()}
  def state(gate), do: Map.get(gate, :procurement, init())

  def event_types do
    common = %{"cooperative_id" => :string}
    operator = Map.merge(common, %{"operator_id" => :string, "grant_version" => :int,
      "session_expires_at_ms" => :int})
    %{
      @grant => spec("governance", Map.merge(common, %{"operator_id" => :string,
        "key_id" => :string, "pubkey" => :pubkey, "active" => :bool,
        "expires_at_ms" => :int, "expected_version" => :int})),
      @business => spec("governance", Map.merge(common, %{"business_id" => :string,
        "active" => :bool, "evidence_ref" => :string, "expected_version" => :int})),
      @command => spec("procurement_operator", Map.merge(operator,
        %{"request_id" => :string, "command" => :any})),
      @read => spec("procurement_operator", operator)
    } |> Map.merge(ProcurementDispatch.event_types(operator))
  end

  # Register through the existing extension registry BEFORE Log audits/replays.
  # A different declaration of these names is a boot error, not an override.
  def register_types! do
    existing = Application.get_env(:coop_substrate, :extra_event_types, %{})
    Enum.each(event_types(), fn {name, spec} ->
      case Map.fetch(existing, name) do
        :error -> :ok
        {:ok, ^spec} -> :ok
        _ -> raise "conflicting procurement event registration: #{name}"
      end
    end)
    Application.put_env(:coop_substrate, :extra_event_types, Map.merge(existing, event_types()))
    :ok
  end

  defp spec(role, fields), do: %{required_roles: [role], disclosure_class: :own_data,
    stream: {:payload_field, "private-procurement", "cooperative_id"},
    payload: %{required: fields, optional: %{}}}

  @doc "Build a signed host command; scope, key and session come from the host, not form attributes."
  def command(context, request_id, command) do
    signed(@command, context, Map.merge(operator_payload(context),
      %{"request_id" => request_id, "command" => command}))
  end

  def request_dispatch(context, request_id, version, pickup, dropoff, server \\ Log.server()) do
    payload = Map.merge(operator_payload(context), %{"request_id" => request_id,
      "expected_version" => version, "pickup_digest" => pickup, "dropoff_digest" => dropoff})
    with {:ok, env} <- signed(@dispatch_request, context, payload),
         {:ok, [_]} <- Log.append(env, server), do: :ok
  end

  def snapshot_request(context), do: signed(@read, context, operator_payload(context))

  defp operator_payload(c), do: %{"cooperative_id" => c.cooperative_id,
    "operator_id" => c.operator_id, "grant_version" => c.grant_version,
    "session_expires_at_ms" => c.session_expires_at_ms}

  defp signed(type, c, payload) do
    with {:ok, env} <- Envelope.new(type: type, chapter_id: c.chapter_id,
           timestamp_ms: div(clock_ms(), 1_000) * 1_000, payload: payload,
           signers: [%{role: "procurement_operator", key_id: c.key_id,
             pubkey: Crypto.pubkey_from_seed(c.seed)}]),
         {:ok, env} <- Envelope.sign(env, c.key_id, c.seed), do: {:ok, env}
  end

  def submit(context, request_id, command, server \\ Log.server()) do
    with {:ok, env} <- command(context, request_id, command),
         {:ok, [admitted]} <- Log.append(env, server), do: {:ok, admitted}
  end

  def snapshot(context, server \\ Log.server()) do
    with {:ok, request} <- snapshot_request(context),
      do: Log.procurement_snapshot(request, server)
  end

  # Executed in the Log mailbox: current grant + selected snapshot are one read.
  def read_snapshot(%Envelope{type: @read} = env, gate) do
    now = clock_ms()
    with :ok <- Envelope.verify(env),
         false <- Envelope.appended?(env),
         :ok <- fresh(env, now),
         :ok <- operator(env, gate, now) do
      ch = env.chapter_id
      coop = env.payload["cooperative_id"]
      s = state(gate)
      requests = for {{^ch, ^coop, _id} = key, row} <- s.requests do
        if Map.has_key?(row, :dispatch),
          do: Map.put(row, :dispatch_phase, ProcurementDispatch.handoff_phase(s, key)),
          else: row
      end
      route = ProcurementDispatch.route(s, ch, coop)
      site = if match?(%{active: true}, route), do: route.site
      businesses = for {{^ch, ^coop, id}, row} <- s.businesses, row.active, do: id
      {:ok, %{requests: Enum.sort_by(requests, &elem(&1.scope, 2)),
        businesses: Enum.sort(businesses), dispatch_site: site, grant_version: env.payload["grant_version"]}}
    else
      true -> {:error, :read_request_already_appended}
      {:error, _} = error -> error
    end
  end
  def read_snapshot(_, _), do: {:error, :invalid_snapshot_request}

  def live_check(%Envelope{type: type} = env, gate) when type in @types do
    now = clock_ms()
    with :ok <- fresh(env, now), {:ok, _} <- transition(env, gate, now), do: :ok
  end
  def live_check(_, _), do: :ok

  defp fresh(%Envelope{type: @dispatch_step, timestamp_ms: timestamp}, now) do
    if abs(now - timestamp) <= 30_000, do: :ok, else: {:error, :stale_procurement_dispatch_step}
  end

  defp fresh(env, now) do
    if env.timestamp_ms == div(now, 1_000) * 1_000,
      do: :ok, else: {:error, :stale_procurement_admission_time}
  end

  @doc false
  def fold!(env, gate) do
    with :ok <- Envelope.verify(env),
         {:ok, next} <- transition(env, gate, env.timestamp_ms) do
      put_in(next, [:events, env.event_id], env)
    else
      error -> raise "inconsistent procurement history: #{inspect(error)}"
    end
  end

  # Called before the generic duplicate path. Even an exact retry must carry
  # current authority/session; it returns the original durable event, no append.
  def duplicate(envelopes, gate) do
    if Enum.any?(envelopes, &event?(&1.type)) do
      case envelopes do
        [%Envelope{type: @command} = env] -> command_duplicate(env, gate)
        [%Envelope{type: @read}] -> {:error, :snapshot_requests_are_not_log_events}
        [env] -> if Map.has_key?(state(gate).events, env.event_id),
          do: {:error, :procurement_event_replay}, else: :new
        _ -> {:error, :procurement_requires_singleton_batch}
      end
    else
      :new
    end
  end

  defp command_duplicate(env, gate) do
    with :ok <- operator(env, gate, clock_ms()),
         {:ok, c} <- decode_command(env.payload["command"]),
         :ok <- scope(env) do
      s = state(gate)
      key = {request_key(env), c.id}
      case s.commands[key] do
        nil -> if Map.has_key?(s.events, env.event_id),
          do: {:error, :procurement_event_id_conflict}, else: :new
        original ->
          if (not Map.has_key?(s.events, env.event_id) or env.event_id == original.event_id) and
               original.payload["command"] == env.payload["command"] and
               original.payload["operator_id"] == env.payload["operator_id"] do
            {:ok, [original]}
          else
            {:error, :idempotency_conflict}
          end
      end
    end
  end

  defp transition(%Envelope{type: @grant} = env, gate, now) do
    p = env.payload
    s = state(gate)
    key = {env.chapter_id, p["cooperative_id"], p["operator_id"]}
    with :ok <- governance(env, gate), :ok <- scope(env),
         :ok <- expected(s.grants[key], p["expected_version"]),
         true <- id?(p["operator_id"]) and id?(p["key_id"]) and
           is_integer(p["expires_at_ms"]) and p["expires_at_ms"] >= 0 and
           (not p["active"] or p["expires_at_ms"] > now),
         {:bytes, <<_::256>> = pubkey} <- p["pubkey"] do
      row = %{key_id: p["key_id"], pubkey: pubkey, active: p["active"],
        expires_at_ms: p["expires_at_ms"], version: p["expected_version"] + 1}
      {:ok, put_in(s, [:grants, Access.key(key)], row)}
    else
      false -> {:error, :invalid_procurement_grant}
      {:error, _} = error -> error
      _ -> {:error, :invalid_procurement_grant}
    end
  end

  defp transition(%Envelope{type: @business} = env, gate, _now) do
    p = env.payload
    s = state(gate)
    key = {env.chapter_id, p["cooperative_id"], p["business_id"]}
    with :ok <- governance(env, gate), :ok <- scope(env),
         :ok <- expected(s.businesses[key], p["expected_version"]),
         true <- id?(p["business_id"]) and text?(p["evidence_ref"], 256) do
      row = %{active: p["active"], evidence_ref: p["evidence_ref"],
        version: p["expected_version"] + 1}
      {:ok, put_in(s, [:businesses, Access.key(key)], row)}
    else
      false -> {:error, :invalid_business_enrollment}
      {:error, _} = error -> error
    end
  end

  defp transition(%Envelope{type: @route} = env, gate, _now) do
    with :ok <- governance(env, gate), :ok <- scope(env),
         true <- id?(env.payload["key_id"]) or {:error, :invalid_dispatch_key},
         do: ProcurementDispatch.configure(state(gate), env)
  end

  defp transition(%Envelope{type: @dispatch_request} = env, gate, now) do
    with :ok <- operator(env, gate, now), :ok <- scope(env),
         true <- id?(env.payload["request_id"]) or {:error, :invalid_request_id},
         do: ProcurementDispatch.request(state(gate), env)
  end

  defp transition(%Envelope{type: @dispatch_step} = env, gate, now) do
    with :ok <- scope(env),
         do: ProcurementDispatch.step(state(gate), env, fn row, signed ->
           apply_dispatch_fulfillment(row, signed, now)
         end)
  end

  defp transition(%Envelope{type: @command} = env, gate, now) do
    s = state(gate)
    p = env.payload
    with :ok <- operator(env, gate, now), :ok <- scope(env),
         true <- id?(p["request_id"]),
         {:ok, c} <- decode_command(p["command"]),
         false <- Map.has_key?(s.commands, {request_key(env), c.id}),
         false <- Map.has_key?(s.events, env.event_id),
         :ok <- businesses(env, c, s),
         :ok <- ProcurementDispatch.permit_commercial(s, request_key(env), c.action) do
      trusted = %{authorized: true, chapter_id: env.chapter_id,
        cooperative_id: p["cooperative_id"], request_id: p["request_id"],
        actor_id: p["operator_id"], now_ms: now}
      case apply_kernel(s.requests[request_key(env)], trusted, c) do
        {:ok, row, :accepted} ->
          {:ok, s |> put_in([:requests, Access.key(request_key(env))], row)
            |> put_in([:commands, Access.key({request_key(env), c.id})], env)}
        {:error, _} = error -> error
        _ -> {:error, :procurement_command_replay}
      end
    else
      true -> {:error, :procurement_command_replay}
      false -> {:error, :invalid_request_id}
      {:error, _} = error -> error
    end
  end
  defp transition(_, _, _), do: {:error, :snapshot_requests_are_not_log_events}

  defp apply_dispatch_fulfillment(row, env, now) do
    {chapter, cooperative, request} = row.scope
    trusted = %{authorized: true, chapter_id: chapter, cooperative_id: cooperative,
      request_id: request, actor_id: hd(env.signers).key_id, now_ms: now}
    command = %{id: env.event_id, expected_version: row.version, action: :fulfill,
      attrs: %{evidence_ref: "dispatch:" <> env.payload["proof_id"]}}

    case apply_kernel(row, trusted, command) do
      {:ok, fulfilled, :accepted} -> {:ok, fulfilled}
      {:error, _} = error -> error
      _ -> {:error, :procurement_dispatch_fulfillment_refused}
    end
  end

  # The procurement host includes CommerceCore in its release closure. Keep the
  # generic substrate compilable for unrelated narrow hosts; absent kernel is
  # an explicit rejection (and historical replay fails closed), never bypass.
  defp apply_kernel(row, trusted, command) do
    case Code.ensure_loaded(Workflow) do
      {:module, Workflow} -> apply(Workflow, :apply_command, [row, trusted, command])
      _ -> {:error, :procurement_kernel_unavailable}
    end
  end

  defp governance(env, gate) do
    case env.signers do
      [%{role: "governance", key_id: id, pubkey: pubkey}] ->
        if get_in(gate, [:role_keys, {env.chapter_id, "governance"}, id]) == pubkey,
          do: :ok, else: {:error, :procurement_governance_required}
      _ -> {:error, :procurement_governance_required}
    end
  end

  defp operator(env, gate, now) do
    p = env.payload
    grant = state(gate).grants[{env.chapter_id, p["cooperative_id"], p["operator_id"]}]
    case {grant, env.signers} do
      {%{active: true, key_id: key, pubkey: pub, version: version, expires_at_ms: expires},
       [%{role: "procurement_operator", key_id: key, pubkey: pub}]} ->
        if p["grant_version"] == version and expires > now and
             is_integer(p["session_expires_at_ms"]) and p["session_expires_at_ms"] > now,
          do: :ok, else: {:error, :procurement_authority_expired_or_replaced}
      _ -> {:error, :procurement_forbidden}
    end
  end

  defp scope(env) do
    if id?(env.chapter_id) and id?(env.payload["cooperative_id"]),
      do: :ok, else: {:error, :invalid_procurement_scope}
  end
  defp request_key(env), do: {env.chapter_id, env.payload["cooperative_id"], env.payload["request_id"]}
  defp expected(nil, 0), do: :ok
  defp expected(%{version: v}, v), do: :ok
  defp expected(_, _), do: {:error, :stale_authority_version}

  defp businesses(env, c, s) do
    ids = case c.action do
      :request -> [c.attrs[:buyer_business_id]]
      :quote -> [c.attrs[:merchant_business_id]]
      :accept ->
        row = s.requests[request_key(env)]
        quote = if row, do: row.quotes[c.attrs[:quote_id]]
        [c.attrs[:buyer_business_id], if(quote, do: quote.merchant_business_id)]
      _ -> []
    end
    if Enum.all?(ids, fn id ->
      match?(%{active: true}, s.businesses[{env.chapter_id, env.payload["cooperative_id"], id}])
    end), do: :ok, else: {:error, :business_not_enrolled}
  end

  @doc "Closed string-key decoding; never interns user input as atoms."
  def decode_command(%{"id" => id, "expected_version" => v, "action" => a, "attrs" => attrs} = c)
      when map_size(c) == 4 and is_map(attrs) do
    case @fields[a] do
      nil -> {:error, :invalid_command}
      fields ->
        if Enum.sort(Map.keys(attrs)) == Enum.sort(Enum.map(fields, &Atom.to_string/1)) do
          {:ok, %{id: id, expected_version: v, action: @actions[a],
            attrs: Map.new(fields, &{&1, attrs[Atom.to_string(&1)]})}}
        else
          {:error, :invalid_command_attributes}
        end
    end
  end
  def decode_command(_), do: {:error, :invalid_command}

  defp id?(v), do: is_binary(v) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/, v)
  defp text?(v, limit), do: is_binary(v) and String.valid?(v) and
    byte_size(v) in 1..limit and String.trim(v) != ""
end
