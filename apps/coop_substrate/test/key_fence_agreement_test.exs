defmodule CoopSubstrate.KeyFenceAgreementTest do
  @moduledoc """
  P2: the key audit is the chapter key fence replayed. Over generated
  histories an appender without the fence could have committed, the audit
  finds a collision at exactly the positions where the append gate refuses
  with a fence refusal, and its first finding there names the rule that
  refusal comes from. A history the fence admitted audits clean. Pure: no
  Log, no database.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import CoopSubstrate.LogCase, only: [new_member: 0, new_member: 1, signed_event: 4]

  alias CoopSubstrate.{Constants, KeyFence, Procurement, ProcurementDispatch}
  alias CoopSubstrate.{ProcurementTestClock, RestaurantKeyAudit}
  alias CoopSubstrate.Projections.AdmissionGate
  alias CoopSubstrate.Protocol.{Envelope, Validity}

  @chapters ~w(chapter-genesis chapter-two)
  @tenants ~w(11111111-1111-1111-1111-111111111111 22222222-2222-2222-2222-222222222222)
  @fence [{:error, :key_not_separate}, {:error, :restaurant_key_already_granted}]
  @now 1_800_000_000_000

  setup do
    ProcurementTestClock.set(@now)
    :ok = Procurement.register_types!()
  end

  property "P2: the audit finds a collision exactly where the fence refuses" do
    pool = pool()
    {:ok, seen} = Agent.start_link(fn -> MapSet.new() end)

    check all(intents <- list_of(intent(), max_length: 30), max_runs: 200) do
      history = history(intents, pool, &(&1 in [:ok | @fence]))
      findings = audit(history).historical_violations
      rules = Enum.group_by(findings, & &1.event.global_seq, & &1.rule)

      refused =
        for {env, verdict} <- history, verdict != :ok, into: %{}, do: {env.global_seq, verdict}

      assert Enum.sort(Map.keys(rules)) == Enum.sort(Map.keys(refused))

      for {position, [rule | _]} <- rules,
          do: assert(refused[position] == {:error, KeyFence.refusal(rule)})

      Agent.update(seen, &MapSet.union(&1, MapSet.new(findings, fn finding -> finding.rule end)))

      assert audit(history(intents, pool, &(&1 == :ok))).violation_count == 0
    end

    assert MapSet.subset?(MapSet.new(KeyFence.rules()), Agent.get(seen, & &1))
  end

  defp audit(history) do
    events = for {env, _verdict} <- history, do: env
    audit = Enum.reduce(events, RestaurantKeyAudit.init(), &RestaurantKeyAudit.handle_event/2)
    RestaurantKeyAudit.report(audit, %{global_seq: length(events), global_hash: nil})
  end

  # Each chapter's governance key is declared first; chapter-genesis's is one
  # of the four keys every claim draws from.
  defp pool do
    govs = Map.new(@chapters, &{&1, new_member("governance")})
    gov = govs["chapter-genesis"]

    genesis =
      for {ch, g} <- govs,
          do: {:event, declaration(govs, ch, g.signer.key_id, pubkey(g), "governance")}

    %{
      govs: govs,
      genesis: genesis,
      keys: Enum.map([gov | for(_ <- 1..3, do: new_member())], &pubkey/1)
    }
  end

  defp intent do
    chapter = member_of(@chapters)
    key = integer(0..3)
    tenant = member_of(@tenants)
    active = frequency([{3, constant(true)}, {1, constant(false)}])

    frequency([
      {1, tuple({constant(:role), chapter, key, member_of(Constants.declarable_roles())})},
      {1, tuple({constant(:revoke_role), chapter, integer(0..7)})},
      {1, tuple({constant(:device), chapter, key, member_of(~w(m1 m2))})},
      {2, tuple({constant(:dispatch), chapter, key, member_of(~w(m1 m2)), tenant})},
      {1, tuple({constant(:revoke_grant), chapter, integer(0..7)})},
      {1, tuple({constant(:dispatcher), chapter, key, tenant})},
      {1, tuple({constant(:route), chapter, key, member_of(~w(c1 c2)), active})},
      {2,
       tuple(
         {constant(:operator), chapter, key, member_of(~w(c1 c2)), member_of(~w(o1 o2)), active}
       )}
    ])
  end

  # The genesis, then each intent as a signed event against the gate the kept
  # events leave, positioned as the Log assigns it and judged as the append
  # gate judges it: `[{event, verdict}]`, kept where `keep?` accepts the
  # verdict. Without the fence, its refusals would have been committed.
  defp history(intents, pool, keep?) do
    (pool.genesis ++ intents)
    |> Enum.with_index()
    |> Enum.reduce({[], AdmissionGate.init()}, fn {intent, i}, {kept, gate} ->
      with %Envelope{} = env <- event(intent, "k#{i}", gate, pool),
           env = position(env, kept),
           verdict = judge(env, gate),
           true <- keep?.(verdict) do
        {[{env, verdict} | kept], AdmissionGate.handle_event(env, gate)}
      else
        _ -> {kept, gate}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp judge(env, gate),
    do: with(:ok <- Procurement.live_check(env, gate), do: Validity.check(env, gate))

  defp position(env, kept) do
    {:ok, stream} = Envelope.stream_id(env)

    Envelope.with_log_assignment(env, %{
      stream_id: stream,
      stream_seq: Enum.count(kept, fn {e, _} -> e.stream_id == stream end) + 1,
      global_seq: length(kept) + 1,
      prev_stream_hash: nil,
      prev_global_hash: nil
    })
  end

  defp event({:event, env}, _id, _gate, _pool), do: env

  defp event({:role, ch, k, role}, id, _gate, pool),
    do: declaration(pool.govs, ch, id, key(pool, k), role)

  defp event({:device, ch, k, merchant}, id, _gate, pool) do
    sign(pool.govs, ch, "RestaurantDeviceGrantedV1", %{
      "merchant_id" => merchant,
      "device_id" => id,
      "key_id" => id,
      "pubkey" => key(pool, k),
      "actor" => "staff",
      "actions" => ["accept"]
    })
  end

  defp event({:dispatch, ch, k, merchant, tenant}, id, _gate, pool) do
    sign(pool.govs, ch, "RestaurantDispatchGrantedV1", %{
      "merchant_id" => merchant,
      "tenant_id" => tenant,
      "key_id" => id,
      "pubkey" => key(pool, k)
    })
  end

  defp event({:dispatcher, ch, k, tenant}, id, _gate, pool) do
    sign(pool.govs, ch, "DispatchDispatcherGrantedV1", %{
      "tenant_id" => tenant,
      "dispatcher_id" => id,
      "key_id" => id,
      "pubkey" => key(pool, k)
    })
  end

  defp event({:route, ch, k, coop, active}, _id, gate, pool) do
    current = ProcurementDispatch.route(Procurement.state(gate), ch, coop)

    sign(pool.govs, ch, "ProcurementDispatchRouteV1", %{
      "cooperative_id" => coop,
      "tenant_id" => hd(@tenants),
      "site" => "North dock",
      "key_id" => "route-" <> coop,
      "pubkey" => key(pool, k),
      "active" => active,
      "expected_version" => if(current, do: current.version, else: 0)
    })
  end

  defp event({:operator, ch, k, coop, op, active}, _id, gate, pool) do
    current = Procurement.state(gate).grants[{ch, coop, op}]

    sign(pool.govs, ch, "ProcurementOperatorGrantedV1", %{
      "cooperative_id" => coop,
      "operator_id" => op,
      "key_id" => "operator-" <> op,
      "pubkey" => key(pool, k),
      "active" => active,
      "expires_at_ms" => @now + 3_600_000,
      "expected_version" => if(current, do: current.version, else: 0)
    })
  end

  # A revocation picks one of the chapter's current role keys, never genesis.
  defp event({:revoke_role, ch, n}, _id, gate, pool) do
    genesis = pool.govs[ch].signer.key_id

    declared =
      for {{^ch, role}, ids} <- gate.role_keys,
          key_id <- Map.keys(ids),
          key_id != genesis,
          do: {role, key_id}

    with {role, key_id} <- pick(declared, n),
         do: sign(pool.govs, ch, "RoleKeyRevoked", %{"role" => role, "key_id" => key_id})
  end

  defp event({:revoke_grant, ch, n}, _id, gate, pool) do
    active =
      for {{^ch, merchant, key_id}, grant} <- gate.restaurant.grants,
          not Map.get(grant, :revoked, false),
          do: {merchant, key_id}

    with {merchant, key_id} <- pick(active, n),
         do:
           sign(pool.govs, ch, "RestaurantDeviceRevokedV1", %{
             "merchant_id" => merchant,
             "key_id" => key_id
           })
  end

  defp pick([], _n), do: nil
  defp pick(choices, n), do: Enum.at(Enum.sort(choices), rem(n, length(choices)))

  defp declaration(govs, ch, key_id, pubkey, role),
    do:
      sign(govs, ch, "RoleKeyDeclared", %{"role" => role, "key_id" => key_id, "pubkey" => pubkey})

  defp key(pool, k), do: Enum.at(pool.keys, k)
  defp pubkey(member), do: {:bytes, member.signer.pubkey}

  defp sign(govs, ch, type, payload),
    do: signed_event(govs[ch], type, payload, chapter_id: ch, timestamp_ms: @now)
end
