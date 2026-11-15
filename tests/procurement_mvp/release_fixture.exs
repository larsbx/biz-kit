# Offline synthetic fixture, deliberately OUTSIDE the application/release source.
# Run through bin/procurement eval. Never exposes an HTTP bootstrap or keeps a
# governance key in the long-running host. Must not run beside a live appender.
defmodule ProcurementReleaseFixture do
  alias CoopSubstrate.{Canonical, Crypto, Log, Procurement, ProcurementDispatch, RestaurantDeliveryWork}
  alias CoopSubstrate.Protocol.Envelope

  @tenant "11111111-1111-1111-1111-111111111111"
  @dispatch_key "acceptance-dispatch"
  @site "Synthetic north dock"

  # The machine fixture only signs. It never starts a second appender.
  def sign do
    :ok = Procurement.register_types!()
    seed = dispatch_seed()
    scope = %{source: :procurement, chapter: System.fetch_env!("PROCUREMENT_CHAPTER"),
      merchant: System.fetch_env!("PROCUREMENT_COOPERATIVE"),
      tenant: @tenant, key_id: @dispatch_key}

    body =
      case Jason.decode!(System.fetch_env!("PROCUREMENT_FIXTURE_INPUT")) do
        "work" -> RestaurantDeliveryWork.sign(scope, "", seed)
        payload ->
          signer = %{role: "procurement_dispatch", key_id: @dispatch_key,
            pubkey: Crypto.pubkey_from_seed(seed)}
          payload = Map.merge(payload, %{"cooperative_id" => scope.merchant, "tenant_id" => @tenant})
          {:ok, event} = Envelope.new(type: "ProcurementDispatchStepV1", chapter_id: scope.chapter,
            timestamp_ms: System.system_time(:millisecond), payload: payload, signers: [signer])
          {:ok, signed} = Envelope.sign(event, @dispatch_key, seed)
          {:ok, record} = Canonical.encode(Envelope.full_record_term(signed))
          %{"record" => Base.url_encode64(record, padding: false)}
      end

    report(body)
  end

  def run do
    unless System.get_env("PROCUREMENT_RELEASE_ACCEPTANCE") == "disposable-local-postgres" and
             System.get_env("EVENTSTORE_HOST") in ["localhost", "127.0.0.1", "::1"] and
             Regex.match?(~r/\Aprocurement_acceptance_[a-f0-9]{12}(_restore)?\z/,
               System.get_env("EVENTSTORE_DATABASE", "")),
      do: raise("fixture is restricted to explicit disposable loopback acceptance databases")

    unless System.get_env("PROCUREMENT_ENABLED") == "false",
      do: raise("offline fixture must not start the HTTP listener")

    {:ok, _} = Application.ensure_all_started(:commerce_core)
    {:ok, _} = Application.ensure_all_started(:coop_substrate)
    context = ProcurementHost.Auth.from_env!()

    case System.fetch_env!("PROCUREMENT_FIXTURE_MODE") do
      "seed" -> seed(context)
      "revoke" -> authority(context, false, 1)
      "inspect" -> :ok
      _ -> raise "unknown fixture mode"
    end

    report(inspect_ledger(context))
  end

  defp report(value), do: IO.puts("PROCUREMENT_FIXTURE_JSON:" <> Jason.encode!(value))
  defp dispatch_seed, do: Base.decode16!(System.fetch_env!("PROCUREMENT_FIXTURE_DISPATCH_SEED"), case: :mixed)

  defp seed(context) do
    unless Log.head().global_seq == 0, do: raise("refusing to seed an existing ledger")
    seed = governance_seed()
    admit(context, "RoleKeyDeclared", %{
      "role" => "governance", "key_id" => "acceptance-governance",
      "pubkey" => {:bytes, Crypto.pubkey_from_seed(seed)}
    })
    authority(context, true, 0)

    for business <- ["acceptance-buyer", "acceptance-merchant"] do
      admit(context, "ProcurementBusinessEnrolledV1", %{
        "cooperative_id" => context.cooperative_id, "business_id" => business,
        "active" => true, "evidence_ref" => "synthetic-enrollment", "expected_version" => 0
      })
    end

    admit(context, "ProcurementDispatchRouteV1", %{
      "cooperative_id" => context.cooperative_id, "tenant_id" => @tenant, "site" => @site,
      "key_id" => @dispatch_key, "pubkey" => {:bytes, Crypto.pubkey_from_seed(dispatch_seed())},
      "active" => true, "expected_version" => 0
    })
  end

  defp authority(context, active, expected) do
    admit(context, "ProcurementOperatorGrantedV1", %{
      "cooperative_id" => context.cooperative_id, "operator_id" => context.operator_id,
      "key_id" => context.key_id, "pubkey" => {:bytes, Crypto.pubkey_from_seed(context.seed)},
      "active" => active, "expires_at_ms" => Procurement.clock_ms() + 7_200_000,
      "expected_version" => expected
    })
  end

  defp governance_seed do
    seed = Base.decode16!(System.fetch_env!("PROCUREMENT_GOVERNANCE_SEED_HEX"), case: :mixed)
    unless byte_size(seed) == 32, do: raise("invalid synthetic governance seed")
    seed
  end

  # The current admission contract refuses signatures crossing a second boundary.
  # Only that explicit, pre-append refusal can be re-signed here. No arbitrary
  # errors, timeouts or unknown outcomes are retried by the offline fixture.
  defp admit(context, type, payload, attempts \\ 3) do
    seed = governance_seed()
    key = "acceptance-governance"
    {:ok, env} = Envelope.new(type: type, chapter_id: context.chapter_id,
      timestamp_ms: div(Procurement.clock_ms(), 1_000) * 1_000, payload: payload,
      signers: [%{role: "governance", key_id: key, pubkey: Crypto.pubkey_from_seed(seed)}])
    {:ok, signed} = Envelope.sign(env, key, seed)
    case Log.append(signed) do
      {:ok, [_]} -> :ok
      {:error, {:reject, 0, :stale_procurement_admission_time}} when attempts > 1 ->
        admit(context, type, payload, attempts - 1)
      _ -> raise "synthetic authority admission failed"
    end
  end

  defp inspect_ledger(context) do
    # read_all decodes and verifies the persisted signed records independently
    # of the live projection. Compare its length with the reconstructed head.
    {:ok, events} = Log.read_all()
    head = Log.head()
    unless length(events) == head.global_seq, do: raise("persisted event/head mismatch")
    Enum.each(events, fn event ->
      unless Envelope.verify(event) == :ok, do: raise("invalid persisted signature")
    end)
    state = Procurement.state(Log.gate())
    grant = Map.fetch!(state.grants,
      {context.chapter_id, context.cooperative_id, context.operator_id})
    requests = state.requests |> Enum.sort() |> Enum.map(fn {scope, row} ->
      quote = row.accepted_quote
      %{
        id: elem(scope, 2), dispatch_phase: ProcurementDispatch.handoff_phase(state, scope),
        outcome_ref: row.outcome_ref,
        phase: Atom.to_string(row.phase), version: row.version,
        command_count: map_size(row.receipts),
        quote_revision: if(quote, do: quote.revision),
        quote_total_minor: if(quote, do: quote.total_minor),
        payment_evidence_count: length(row.payment_evidence)
      }
    end)
    %{
      global_seq: head.global_seq, global_hash: Base.encode16(head.global_hash, case: :lower),
      verified_event_count: length(events), grant_active: grant.active,
      grant_version: grant.version, requests: requests
    }
  end
end

if System.get_env("PROCUREMENT_FIXTURE_MODE") == "sign",
  do: ProcurementReleaseFixture.sign(),
  else: ProcurementReleaseFixture.run()
