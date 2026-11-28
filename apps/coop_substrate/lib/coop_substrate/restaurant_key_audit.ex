defmodule CoopSubstrate.RestaurantKeyAudit do
  @moduledoc """
  Opt-in audit of a ledger's chapter key history: the chapter key fence
  (`CoopSubstrate.KeyFence`) replayed over a verified prefix. It folds the
  appender's own gate (`AdmissionGate`) and, before each claim folds, asks the
  fence which rules the claim breaks against the gate its prefix left. So a
  finding exists exactly where the current fence would refuse the event:
  restaurant device, Dispatch and role keys, and dispatcher, procurement route
  and operator keys alike, although the name predates that scope.

  A finding stays open while any binding it names still holds at the head
  (`KeyFence.live?/4`): the seed sat with two holders, so it closes only once
  it is retired from all of them. Each open finding lists the remediation for
  each live binding's class. The result is tied to an exact global sequence
  and hash. `CoopSubstrate.ReleaseTasks.audit_keys/1` runs it without the
  appender (docs/architecture/restaurant-key-collision-audit.md).
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.{KeyFence, Log}
  alias CoopSubstrate.Projections.AdmissionGate
  alias CoopSubstrate.Protocol.Envelope

  @revocations ~w(RestaurantDeviceRevokedV1 RoleKeyRevoked)
  @identity ~w(merchant_id tenant_id role cooperative_id operator_id dispatcher_id)a

  @reenroll_slot "Enroll the slot with ProcurementHost.ReleaseTasks.enroll at its next " <>
                   "expected_version, inactive or on a fresh key; the fence refuses neither."

  @remediation %{
    restaurant_device:
      "Revoke the grant with restaurant.manage revoke-device, then enroll a new key ID with " <>
        "a new seed.",
    restaurant_dispatch:
      "Revoke the grant with restaurant.manage revoke-device, then grant-dispatch a new key " <>
        "ID with a new seed file on the Dispatch machine.",
    governance_key:
      "Declare a replacement governance key, then revoke this one (RoleKeyRevoked) from an " <>
        "administrator browser or with coop.owner.succeed, never the chapter's last one. Its " <>
        "seed has been on another machine: rotate it even once the other binding is revoked.",
    role_key: "No shipped command revokes this role key: governance signs its RoleKeyRevoked.",
    dispatcher: "No ledger revocation exists: retire the seed off the ledger; this stays open.",
    procurement_route: @reenroll_slot,
    procurement_operator: @reenroll_slot
  }

  @doc "Audit the prefix at the appender's current head."
  def scan, do: scan(Log.head())

  @doc "Repeat an audit at a captured Log head (using its binary global hash)."
  def scan(head) do
    with {:ok, audit} <- Log.replay_verified(__MODULE__, head), do: {:ok, report(audit, head)}
  end

  @doc "The report of a folded audit at `head`."
  def report(audit, head) do
    findings = for finding <- Enum.reverse(audit.findings), do: at_head(finding, audit)

    %{
      schema: "restaurant-key-collision-audit.v2",
      as_of: %{global_seq: head.global_seq, global_hash: hex(head.global_hash)},
      historical_violations: findings,
      violation_count: length(findings),
      open_count: Enum.count(findings, & &1.open)
    }
  end

  @doc false
  @impl true
  def init, do: %{gate: AdmissionGate.init(), refs: %{}, revocations: %{}, findings: []}

  @doc false
  @impl true
  # Judge against the gate the event's prefix left, as the append gate does,
  # then apply the boot fold, which is total on any ledger that boots.
  def handle_event(%Envelope{} = event, audit) do
    audit = audit |> judge(event) |> note_revocation(event)
    %{audit | gate: AdmissionGate.handle_event(event, audit.gate)}
  end

  defp judge(audit, event),
    do: if(KeyFence.holder(event), do: claim(audit, event), else: audit)

  # One finding per rule a claim breaks, with every earlier binding it breaks
  # it against. The claim's binding then replaces any earlier event of the
  # same holding, so a re-declared role or a re-sent slot is its latest event.
  defp claim(audit, %Envelope{chapter_id: chapter} = event) do
    {:bytes, pubkey} = event.payload["pubkey"]
    held = KeyFence.witness(event)
    ref = event |> event_ref() |> Map.put(:class, class(event))

    findings =
      for [{rule, _} | _] = broken <-
            Enum.chunk_by(KeyFence.conflicts(event, audit.gate), &elem(&1, 0)) do
        earlier =
          for {_, other} <- broken, do: {other, Map.fetch!(audit.refs, {chapter, pubkey, other})}

        %{
          rule: rule,
          pubkey: pubkey,
          event: {held, ref},
          earlier: Enum.sort_by(earlier, &elem(&1, 1).global_seq)
        }
      end

    %{
      audit
      | refs: Map.put(audit.refs, {chapter, pubkey, held}, ref),
        findings: Enum.reverse(findings, audit.findings)
    }
  end

  # Revoked grants keep counting and revoked role keys do not, as the fence
  # counts them; either way the binding's event records its revocation.
  defp note_revocation(audit, %Envelope{type: type, chapter_id: chapter} = event)
       when type in @revocations do
    {held, pubkey} = revoked(audit.gate, event)

    case audit.refs[{chapter, pubkey, held}] do
      nil -> audit
      ref -> put_in(audit, [:revocations, ref.global_seq], event_ref(event))
    end
  end

  defp note_revocation(audit, _event), do: audit

  defp revoked(gate, %{type: "RoleKeyRevoked", chapter_id: chapter, payload: p}) do
    pubkey = get_in(gate.role_keys, [{chapter, p["role"]}, p["key_id"]])
    {{:role, p["role"], p["key_id"]}, pubkey}
  end

  defp revoked(gate, %{chapter_id: chapter, payload: p}) do
    grant = gate.restaurant.grants[{chapter, p["merchant_id"], p["key_id"]}]
    {{:grant, p["merchant_id"], p["key_id"]}, grant[:pubkey]}
  end

  defp class(%{type: "RestaurantDeviceGrantedV1"}), do: :restaurant_device
  defp class(%{type: "RestaurantDispatchGrantedV1"}), do: :restaurant_dispatch
  defp class(%{type: "RoleKeyDeclared", payload: %{"role" => "governance"}}), do: :governance_key
  defp class(%{type: "RoleKeyDeclared"}), do: :role_key
  defp class(%{type: "DispatchDispatcherGrantedV1"}), do: :dispatcher
  defp class(%{type: "ProcurementDispatchRouteV1"}), do: :procurement_route
  defp class(%{type: "ProcurementOperatorGrantedV1"}), do: :procurement_operator

  defp event_ref(event) do
    {:ok, hash} = Envelope.event_hash(event)

    ids =
      for field <- @identity,
          value = event.payload[Atom.to_string(field)],
          into: %{},
          do: {field, value}

    Map.merge(ids, %{
      event_id: event.event_id,
      event_hash: hex(hash),
      global_seq: event.global_seq,
      stream_id: event.stream_id,
      stream_seq: event.stream_seq,
      type: event.type,
      chapter_id: event.chapter_id,
      key_id: event.payload["key_id"]
    })
  end

  defp at_head(%{rule: rule, pubkey: pubkey} = finding, audit) do
    refs =
      for {held, ref} <- [finding.event | finding.earlier] do
        Map.merge(ref, %{
          revoked_in: audit.revocations[ref.global_seq],
          active_at_head: KeyFence.live?(audit.gate, ref.chapter_id, pubkey, held)
        })
      end

    live = Enum.filter(refs, & &1.active_at_head)

    %{
      rule: rule,
      refusal: KeyFence.refusal(rule),
      pubkey_sha256: hex(:crypto.hash(:sha256, pubkey)),
      event: hd(refs),
      earlier_events: tl(refs),
      open: live != [],
      remediation: Map.new(live, &{&1.class, Map.fetch!(@remediation, &1.class)})
    }
  end

  defp hex(nil), do: nil
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
