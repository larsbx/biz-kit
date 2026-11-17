defmodule CoopSubstrate.RestaurantKeyAudit do
  @moduledoc """
  Opt-in audit of retained restaurant and role key events against the key
  separation rules in PR #429. Runs against the canonical Log on an already
  running node. The result is tied to an exact global sequence and hash.
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Protocol.Envelope

  @device "RestaurantDeviceGrantedV1"
  @dispatch "RestaurantDispatchGrantedV1"
  @grant_revoked "RestaurantDeviceRevokedV1"
  @role "RoleKeyDeclared"
  @role_revoked "RoleKeyRevoked"
  @declarations [@device, @dispatch, @role]
  @revocations [@grant_revoked, @role_revoked]
  @key_events @declarations ++ @revocations

  @doc "Audit the prefix at the appender's current head."
  def scan, do: scan(Log.head())

  @doc "Repeat an audit at a captured Log head (using its binary global hash)."
  def scan(head) do
    with {:ok, audit} <- Log.replay_verified(__MODULE__, head) do
      {:ok, report(audit, head)}
    end
  end

  @doc false
  @impl true
  def init do
    %{membership: Membership.init(), sources: %{}, revocations: %{}, findings: []}
  end

  @doc false
  @impl true
  # These are the Membership events that change restaurant grants or declared
  # role keys. Inspect the preceding state, then apply the historical fold.
  def handle_event(%Envelope{type: type} = event, audit) when type in @key_events do
    next = observe_key(event, audit)
    %{next | membership: Membership.handle_event(event, audit.membership)}
  end

  def handle_event(_, audit), do: audit

  defp observe_key(%Envelope{type: type, chapter_id: chapter, payload: payload} = event, audit)
       when type in @declarations do
    {:bytes, pubkey} = payload["pubkey"]
    key = {chapter, pubkey}
    sources = Map.get(audit.sources, key, %{})
    current = event_ref(event)

    findings =
      for {rule, [_ | _] = earlier} <- conflicts(current, Map.values(sources)) do
        %{
          rule: rule,
          pubkey_sha256: hex(:crypto.hash(:sha256, pubkey)),
          event: current,
          earlier_events: Enum.sort_by(earlier, & &1.global_seq)
        }
      end

    %{
      audit
      | sources: Map.put(audit.sources, key, Map.put(sources, slot(event), current)),
        findings: Enum.reverse(findings, audit.findings)
    }
  end

  defp observe_key(%Envelope{type: type, chapter_id: chapter} = event, audit)
       when type in @revocations do
    slot = slot(event)
    key = {chapter, revoked_pubkey(audit.membership, chapter, slot)}
    sources = Map.fetch!(audit.sources, key)
    original = Map.fetch!(sources, slot)
    revocation = event_ref(event)

    # Revoked restaurant grants keep counting. Role declarations leave the
    # active set, but earlier findings retain their original event references.
    sources = if type == @role_revoked, do: Map.delete(sources, slot), else: sources

    %{
      audit
      | sources: Map.put(audit.sources, key, sources),
        revocations: Map.put(audit.revocations, original.global_seq, revocation)
    }
  end

  defp conflicts(%{type: @device, merchant_id: merchant}, earlier) do
    [
      device_dispatch_key_reuse: Enum.filter(earlier, &(&1.type == @dispatch)),
      merchant_key_reuse: merchant_grants(earlier, merchant)
    ]
  end

  defp conflicts(%{type: @dispatch, merchant_id: merchant, tenant_id: tenant}, earlier) do
    [
      device_dispatch_key_reuse: Enum.filter(earlier, &(&1.type == @device)),
      dispatch_role_key_reuse: Enum.filter(earlier, &(&1.type == @role)),
      dispatch_cross_tenant_key_reuse:
        Enum.filter(
          earlier,
          &match?(%{type: @dispatch, tenant_id: other} when other != tenant, &1)
        ),
      merchant_key_reuse: merchant_grants(earlier, merchant)
    ]
  end

  defp conflicts(%{type: @role}, earlier),
    do: [dispatch_role_key_reuse: Enum.filter(earlier, &(&1.type == @dispatch))]

  defp merchant_grants(earlier, merchant),
    do: Enum.filter(earlier, &match?(%{merchant_id: ^merchant}, &1))

  defp slot(%Envelope{type: type, payload: payload}) when type in [@role, @role_revoked],
    do: {:role, payload["role"], payload["key_id"]}

  defp slot(%Envelope{payload: payload}),
    do: {:grant, payload["merchant_id"], payload["key_id"]}

  defp revoked_pubkey(membership, chapter, {:role, role, key_id}),
    do: Map.fetch!(Map.fetch!(membership.role_keys, {chapter, role}), key_id)

  defp revoked_pubkey(membership, chapter, {:grant, merchant, key_id}),
    do: Map.fetch!(membership.restaurant.grants, {chapter, merchant, key_id}).pubkey

  defp event_ref(event) do
    {:ok, hash} = Envelope.event_hash(event)

    ref = %{
      event_id: event.event_id,
      event_hash: hex(hash),
      global_seq: event.global_seq,
      stream_id: event.stream_id,
      stream_seq: event.stream_seq,
      type: event.type,
      chapter_id: event.chapter_id,
      key_id: event.payload["key_id"]
    }

    case slot(event) do
      {:role, role, _} ->
        Map.put(ref, :role, role)

      {:grant, merchant, _} when event.type == @dispatch ->
        Map.merge(ref, %{merchant_id: merchant, tenant_id: event.payload["tenant_id"]})

      {:grant, merchant, _} ->
        Map.put(ref, :merchant_id, merchant)
    end
  end

  defp report(audit, head) do
    findings =
      for finding <- Enum.reverse(audit.findings) do
        %{
          finding
          | event: with_revocation(finding.event, audit.revocations),
            earlier_events:
              Enum.map(finding.earlier_events, &with_revocation(&1, audit.revocations))
        }
      end

    %{
      schema: "restaurant-key-collision-audit.v1",
      as_of: %{global_seq: head.global_seq, global_hash: hex(head.global_hash)},
      historical_violations: findings,
      violation_count: length(findings)
    }
  end

  defp with_revocation(ref, revocations),
    do: Map.put(ref, :revoked_in, Map.get(revocations, ref.global_seq))

  defp hex(nil), do: nil
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
