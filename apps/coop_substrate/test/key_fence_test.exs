defmodule CoopSubstrate.KeyFenceTest do
  @moduledoc """
  The chapter key fence at the append gate and at Commands preflight. Within a
  chapter, no restaurant grant holds a declared role key, and no role key is
  declared on a key the chapter ever granted, revoked or not. A revoked role
  key is forgotten, so it may be granted later. A dispatcher, a procurement
  route and the procurement operators each hold their keys alone: a route
  serves one cooperative, an operator key may serve several, and a procurement
  version claims its key only while active. Another chapter's keys never
  count, and a domain refusal comes before the fence's.
  """
  use CoopSubstrate.LogCase, async: false
  use ExUnitProperties

  alias CoopSubstrate.{Canonical, Commands, Constants, KeyFence, Log}
  alias CoopSubstrate.{Procurement, ProcurementDispatch, ProcurementTestClock}
  alias CoopSubstrate.Projections.{AdmissionGate, Membership}
  alias CoopSubstrate.Protocol.{Envelope, Validity}
  alias DispatchCore.Admission, as: Dispatch

  @ch "chapter-genesis"
  @other "chapter-two"
  @tenant "11111111-1111-1111-1111-111111111111"
  @other_tenant "22222222-2222-2222-2222-222222222222"
  @now 1_800_000_000_000

  setup do
    ProcurementTestClock.set(@now)
    gov = new_member("governance")
    {:ok, _} = Log.append(declare(gov, "governance", gov.signer.key_id, gov))
    {:ok, gov: gov}
  end

  defp declare(gov, role, key_id, key, chapter \\ @ch),
    do:
      signed_event(
        gov,
        "RoleKeyDeclared",
        %{"role" => role, "key_id" => key_id, "pubkey" => {:bytes, key.signer.pubkey}},
        chapter_id: chapter
      )

  defp device_payload(merchant, key_id, key),
    do: %{
      "merchant_id" => merchant,
      "device_id" => "device-" <> key_id,
      "key_id" => key_id,
      "pubkey" => {:bytes, key.signer.pubkey},
      "actor" => "staff",
      "actions" => ["accept"]
    }

  defp device(gov, merchant, key_id, key, chapter \\ @ch),
    do:
      signed_event(gov, "RestaurantDeviceGrantedV1", device_payload(merchant, key_id, key),
        chapter_id: chapter
      )

  defp revoke_device(gov, merchant, key_id, chapter \\ @ch),
    do:
      signed_event(
        gov,
        "RestaurantDeviceRevokedV1",
        %{"merchant_id" => merchant, "key_id" => key_id},
        chapter_id: chapter
      )

  defp revoke_role(gov, role, key_id, chapter \\ @ch),
    do:
      signed_event(gov, "RoleKeyRevoked", %{"role" => role, "key_id" => key_id},
        chapter_id: chapter
      )

  defp dispatch(gov, merchant, key_id, key, chapter \\ @ch, tenant \\ @tenant),
    do:
      signed_event(
        gov,
        "RestaurantDispatchGrantedV1",
        %{
          "merchant_id" => merchant,
          "tenant_id" => tenant,
          "key_id" => key_id,
          "pubkey" => {:bytes, key.signer.pubkey}
        },
        chapter_id: chapter
      )

  defp dispatcher(gov, tenant, key_id, key, chapter \\ @ch),
    do:
      signed_event(
        gov,
        "DispatchDispatcherGrantedV1",
        %{
          "tenant_id" => tenant,
          "dispatcher_id" => "dispatcher-" <> key_id,
          "key_id" => key_id,
          "pubkey" => {:bytes, key.signer.pubkey}
        },
        chapter_id: chapter
      )

  # A cooperative's next Dispatch route version, read from the gate as the
  # offline enrollment reads it. `opts`: chapter, gate, active, site.
  defp route(gov, coop, key, opts \\ []) do
    chapter = Keyword.get(opts, :chapter, @ch)
    gate = Keyword.get_lazy(opts, :gate, &Log.gate/0)
    current = ProcurementDispatch.route(Procurement.state(gate), chapter, coop)

    procurement(gov, "ProcurementDispatchRouteV1", chapter, %{
      "cooperative_id" => coop,
      "tenant_id" => @tenant,
      "site" => Keyword.get(opts, :site, "North dock"),
      "key_id" => "route-" <> coop,
      "pubkey" => {:bytes, key.signer.pubkey},
      "active" => Keyword.get(opts, :active, true),
      "expected_version" => if(current, do: current.version, else: 0)
    })
  end

  # An operator slot's next grant version, as `route/4` reads a route's.
  defp operator(gov, coop, operator_id, key, opts \\ []) do
    chapter = Keyword.get(opts, :chapter, @ch)
    gate = Keyword.get_lazy(opts, :gate, &Log.gate/0)
    current = Procurement.state(gate).grants[{chapter, coop, operator_id}]

    procurement(gov, "ProcurementOperatorGrantedV1", chapter, %{
      "cooperative_id" => coop,
      "operator_id" => operator_id,
      "key_id" => "operator-" <> operator_id,
      "pubkey" => {:bytes, key.signer.pubkey},
      "active" => Keyword.get(opts, :active, true),
      "expires_at_ms" => @now + 3_600_000,
      "expected_version" => if(current, do: current.version, else: 0)
    })
  end

  defp procurement(gov, type, chapter, payload),
    do: signed_event(gov, type, payload, chapter_id: chapter, timestamp_ms: @now)

  # One key of each class in the chapter besides governance: a device, a
  # restaurant Dispatch key, a dispatcher, and cooperative c1's route and
  # operator.
  defp base(gov) do
    k = Map.new(~w(device dispatch dispatcher route operator)a, &{&1, new_member()})

    for claim <- [
          device(gov, "shop", "pos", k.device),
          dispatch(gov, "shop", "courier", k.dispatch),
          dispatcher(gov, @tenant, "x1", k.dispatcher),
          route(gov, "c1", k.route),
          operator(gov, "c1", "o1", k.operator)
        ],
        do: {:ok, [_]} = Log.append(claim)

    Map.put(k, :gov, gov)
  end

  # Test-only: what an appender without the fence committed. The record goes
  # straight to the EventStore of an existing stream, past validity, chained
  # like any other.
  defp persist_unchecked!(event) do
    head = Log.head()
    {:ok, stream} = Envelope.stream_id(event)
    {:ok, prior} = Log.read_stream(stream)
    last = List.last(prior)
    {:ok, previous_hash} = Envelope.event_hash(last)

    assigned =
      Envelope.with_log_assignment(event, %{
        stream_id: stream,
        stream_seq: last.stream_seq + 1,
        global_seq: head.global_seq + 1,
        prev_global_hash: head.global_hash,
        prev_stream_hash: previous_hash
      })

    {:ok, uuid} = CoopSubstrate.ULID.to_uuid(event.event_id)

    data = %EventStore.EventData{
      event_id: uuid,
      event_type: event.type,
      data: Canonical.encode!(Envelope.full_record_term(assigned)),
      metadata: nil
    }

    :ok = CoopSubstrate.EventStore.append_to_stream("ledger", head.global_seq, [data])
  end

  # A fresh key, declared in `role` under the key ID "k-<role>".
  defp declared(gov, role) do
    key = new_member()
    {:ok, _} = Log.append(declare(gov, role, "k-" <> role, key))
    key
  end

  defp refused(event, reason \\ :key_not_separate) do
    head = Log.head()
    assert Log.append(event) == {:error, {:reject, 0, reason}}, event.type
    assert Log.head() == head
  end

  test "a device grant on any declared role key appends nothing", %{gov: gov} do
    for role <- Constants.declarable_roles() do
      key = if role == "governance", do: gov, else: declared(gov, role)
      refused(device(gov, "shop", "board-" <> role, key))
    end
  end

  test "no key the chapter granted, revoked or not, is declared a role key", %{gov: gov} do
    active = new_member()
    revoked = new_member()

    {:ok, _} =
      Log.append([
        device(gov, "shop", "pos", active),
        device(gov, "shop", "old", revoked),
        revoke_device(gov, "shop", "old")
      ])

    for role <- Constants.declarable_roles(),
        key <- [active, revoked],
        do: refused(declare(gov, role, "k-" <> role, key))

    assert {:ok, _} = Log.append(declare(gov, "steward", "k-fresh", new_member()))
  end

  test "a revoked role key is forgotten: it may be granted, and is then never declared again",
       %{gov: gov} do
    steward = declared(gov, "steward")
    {:ok, _} = Log.append(revoke_role(gov, "steward", "k-steward"))

    assert {:ok, _} = Log.append(device(gov, "shop", "board", steward))
    refused(declare(gov, "steward", "k-again", steward))
  end

  test "role plus role breaks nothing: one key may serve several roles", %{gov: gov} do
    steward = declared(gov, "steward")

    assert {:ok, _} =
             Log.append([
               declare(gov, "checkpoint", "k-checkpoint", steward),
               declare(gov, "commercial_setoff_reviewer", "k-reviewer", gov)
             ])
  end

  test "another chapter's keys never count", %{gov: gov} do
    other_gov = new_member("governance")
    steward = declared(gov, "steward")
    board = new_member()

    {:ok, _} =
      Log.append([
        declare(other_gov, "governance", other_gov.signer.key_id, other_gov, @other),
        device(gov, "shop", "board", board)
      ])

    assert {:ok, _} =
             Log.append([
               device(other_gov, "shop", "board", steward, @other),
               device(other_gov, "deli", "gov", gov, @other),
               declare(other_gov, "checkpoint", "k-checkpoint", board, @other),
               device(gov, "deli", "other-gov", other_gov)
             ])
  end

  test "a domain refusal comes before the fence's", %{gov: gov} do
    steward = declared(gov, "steward")
    pos = new_member()

    {:ok, _} =
      Log.append([device(gov, "shop", "pos", pos), dispatcher(gov, @tenant, "x1", new_member())])

    refused(device(gov, "shop", "pos", steward), :restaurant_key_already_granted)
    refused(dispatcher(gov, @tenant, "x1", pos), :dispatcher_key_already_granted)

    refused(
      declare(gov, "steward", "k-steward", pos),
      {:role_key_already_declared, "steward", "k-steward"}
    )
  end

  test "names each holding a claim breaks against, and claims nothing else", %{gov: gov} do
    pos = new_member()

    {:ok, _} =
      Log.append([device(gov, "shop", "pos", pos), revoke_device(gov, "shop", "pos")])

    gate = Log.gate()

    assert KeyFence.holdings(gate, @ch, pos.signer.pubkey) ==
             [{:restaurant_core, {:grant, "shop", "pos"}}]

    assert KeyFence.holdings(gate, @ch, gov.signer.pubkey) ==
             [{:restaurant_core, {:role, "governance", gov.signer.key_id}}]

    assert KeyFence.holdings(gate, @other, pos.signer.pubkey) == []

    assert KeyFence.conflicts(declare(gov, "checkpoint", "k-checkpoint", pos), gate) ==
             [{:device_role_key_reuse, {:grant, "shop", "pos"}}]

    assert KeyFence.conflicts(device(gov, "deli", "board", gov), gate) ==
             [{:device_role_key_reuse, {:role, "governance", gov.signer.key_id}}]

    # As history from before the fence may hold: pos declared after its grant.
    # A claim at its merchant breaks both rules and is refused as separate.
    held = put_in(gate, [:role_keys, {@ch, "checkpoint"}], %{"k-pos" => pos.signer.pubkey})
    board = device(gov, "shop", "board", pos)

    assert KeyFence.conflicts(board, held) == [
             {:device_role_key_reuse, {:role, "checkpoint", "k-pos"}},
             {:merchant_key_reuse, {:grant, "shop", "pos"}}
           ]

    assert KeyFence.check(board, held) == {:error, :key_not_separate}

    # Its holder's own conflicts come first, then another holder's holdings.
    both = AdmissionGate.handle_event(dispatcher(gov, @tenant, "x1", pos), held)

    assert KeyFence.conflicts(board, both) == [
             {:device_role_key_reuse, {:role, "checkpoint", "k-pos"}},
             {:merchant_key_reuse, {:grant, "shop", "pos"}},
             {:holder_key_reuse, {:dispatcher, @tenant, "x1"}}
           ]

    assert KeyFence.holder(revoke_device(gov, "shop", "pos")) == nil
    assert KeyFence.conflicts(revoke_device(gov, "shop", "pos"), gate) == []
    assert KeyFence.conflicts(revoke_role(gov, "governance", gov.signer.key_id), gate) == []

    assert Map.new(KeyFence.rules(), &{&1, KeyFence.refusal(&1)}) == %{
             device_dispatch_key_reuse: :key_not_separate,
             device_role_key_reuse: :key_not_separate,
             dispatch_role_key_reuse: :key_not_separate,
             dispatch_cross_tenant_key_reuse: :key_not_separate,
             merchant_key_reuse: :restaurant_key_already_granted,
             holder_key_reuse: :key_not_separate
           }
  end

  test "Commands preflight refuses the claim before anyone signs", %{gov: gov} do
    steward = declared(gov, "steward")
    pos = new_member()
    {:ok, _} = Log.append(device(gov, "shop", "pos", pos))

    assert Commands.hold(
             :key_fence_test,
             @ch,
             "RestaurantDeviceGrantedV1",
             device_payload("shop", "board", steward),
             gov.signer
           ) == {:error, {:invalid, :key_not_separate}}

    assert Commands.hold(
             :key_fence_test,
             @ch,
             "RoleKeyDeclared",
             %{
               "role" => "checkpoint",
               "key_id" => "k-pos",
               "pubkey" => {:bytes, pos.signer.pubkey}
             },
             gov.signer
           ) == {:error, {:invalid, :key_not_separate}}
  end

  test "a dispatcher, route or operator key is no other holder's key", %{gov: gov} do
    k = base(gov)

    for claim <- [
          # A dispatcher pubkey is granted once per chapter, and to nothing else.
          dispatcher(gov, @tenant, "x2", k.gov),
          dispatcher(gov, @tenant, "x2", k.device),
          dispatcher(gov, @tenant, "x2", k.dispatch),
          dispatcher(gov, @other_tenant, "x1", k.dispatcher),
          dispatcher(gov, @tenant, "x2", k.dispatcher),
          dispatcher(gov, @tenant, "x2", k.route),
          dispatcher(gov, @tenant, "x2", k.operator),
          device(gov, "deli", "board", k.dispatcher),
          dispatch(gov, "deli", "courier", k.dispatcher),
          declare(gov, "steward", "k-steward", k.dispatcher),
          route(gov, "c2", k.dispatcher),
          operator(gov, "c2", "o2", k.dispatcher),
          # A route serves its own cooperative only.
          route(gov, "c2", k.operator),
          route(gov, "c2", k.gov),
          route(gov, "c2", k.device),
          route(gov, "c2", k.route),
          # An operator key is no route, role or restaurant key.
          operator(gov, "c2", "o2", k.route),
          operator(gov, "c2", "o2", k.gov),
          operator(gov, "c2", "o2", k.dispatch),
          device(gov, "deli", "board", k.operator)
        ],
        do: refused(claim)
  end

  test "names a dispatcher, route or operator holding by its slot", %{gov: gov} do
    k = base(gov)
    {:ok, _} = Log.append(route(gov, "c1", k.route, site: "South dock"))
    {:ok, _} = Log.append(operator(gov, "c1", "o2", k.operator))
    gate = Log.gate()
    dispatcher = {:dispatcher, @tenant, "x1"}
    operators = [{:operator, "c1", "o1"}, {:operator, "c1", "o2"}]

    assert KeyFence.holdings(gate, @ch, k.dispatcher.signer.pubkey) == [{dispatcher, dispatcher}]

    assert KeyFence.holdings(gate, @ch, k.route.signer.pubkey) ==
             [{{:procurement_route, "c1"}, {:route, "c1"}}]

    assert KeyFence.holdings(gate, @ch, k.operator.signer.pubkey) ==
             for(held <- operators, do: {:procurement_operator, held})

    assert KeyFence.conflicts(route(gov, "c2", k.operator), gate) ==
             for(held <- operators, do: {:holder_key_reuse, held})
  end

  test "a key rotated away keeps its holder", %{gov: gov} do
    k = base(gov)
    assert {:ok, _} = Log.append(route(gov, "c1", new_member()))

    refused(dispatcher(gov, @tenant, "x2", k.route))
    refused(operator(gov, "c2", "o2", k.route))
    refused(route(gov, "c2", k.route))
  end

  test "a slot's holder re-sends it, and one operator key serves several slots", %{gov: gov} do
    k = base(gov)

    for claim <- [
          fn -> route(gov, "c1", k.route) end,
          fn -> route(gov, "c1", k.route, site: "South dock") end,
          fn -> route(gov, "c1", new_member()) end,
          fn -> route(gov, "c1", k.route) end,
          fn -> operator(gov, "c1", "o1", k.operator) end,
          fn -> operator(gov, "c2", "o1", k.operator) end,
          fn -> operator(gov, "c1", "o2", k.operator) end,
          fn -> dispatch(gov, "deli", "courier", k.dispatch) end
        ],
        do: assert({:ok, [_]} = Log.append(claim.()))
  end

  test "another chapter's dispatcher, route and operator keys never count", %{gov: gov} do
    k = base(gov)
    other_gov = new_member("governance")

    {:ok, _} =
      Log.append(declare(other_gov, "governance", other_gov.signer.key_id, other_gov, @other))

    for claim <- [
          dispatcher(other_gov, @tenant, "x1", k.gov, @other),
          route(other_gov, "c1", k.device, chapter: @other),
          operator(other_gov, "c1", "o1", k.dispatch, chapter: @other),
          device(other_gov, "shop", "pos", k.dispatcher, @other),
          declare(other_gov, "steward", "k-steward", k.route, @other),
          dispatch(other_gov, "shop", "courier", k.operator, @other),
          dispatcher(gov, @tenant, "x2", other_gov)
        ],
        do: assert({:ok, [_]} = Log.append(claim))
  end

  test "a procurement version claims its key only while active", %{gov: gov} do
    shared = new_member()
    {:ok, _} = Log.append(operator(gov, "c1", "o1", shared))
    # Admitted before the fence: c1's route on its operator's key.
    persist_unchecked!(route(gov, "c1", shared))
    restart_log()

    # Deactivating either slot is never refused, and leaves both bindings counted.
    assert {:ok, _} = Log.append(route(gov, "c1", shared, active: false))
    assert {:ok, _} = Log.append(operator(gov, "c1", "o1", shared, active: false))
    refused(route(gov, "c1", shared))
    refused(operator(gov, "c1", "o1", shared))
    assert {:ok, _} = Log.append(route(gov, "c1", new_member()))
    assert {:ok, _} = Log.append(operator(gov, "c1", "o1", new_member()))

    # A key only ever enrolled inactive was never claimed, so it is free.
    {idle_route, idle_operator} = {new_member(), new_member()}
    {:ok, _} = Log.append(route(gov, "c2", idle_route, active: false))
    {:ok, _} = Log.append(operator(gov, "c3", "o3", idle_operator, active: false))
    assert {:ok, _} = Log.append(operator(gov, "c4", "o4", idle_route))
    assert {:ok, _} = Log.append(dispatcher(gov, @tenant, "x9", idle_operator))
  end

  test "a ledger already holding a dispatcher on a device key, or a route on an operator key, boots, replays it, and refuses the next claim",
       %{gov: gov} do
    k = base(gov)
    head = Log.head()
    # Admitted before the fence covered them.
    persist_unchecked!(dispatcher(gov, @tenant, "x2", k.device))
    restart_log()
    persist_unchecked!(route(gov, "c1", k.operator))
    restart_log()

    assert Log.head().global_seq == head.global_seq + 2
    gate = Log.gate()
    assert Dispatch.grants(gate.dispatch, @ch, k.device.signer.pubkey) == [{@tenant, "x2"}]
    route = ProcurementDispatch.route(Procurement.state(gate), @ch, "c1")
    assert route.pubkey == k.operator.signer.pubkey
    {:ok, replayed} = Log.replay(Membership)
    assert replayed.dispatch == gate.dispatch
    restart_log()
    assert Procurement.state(Log.gate()) == Procurement.state(gate)
    assert :ok = Log.verify_chains()

    refused(dispatcher(gov, @other_tenant, "x3", k.device))
    refused(route(gov, "c1", k.operator))
  end

  test "Commands preflight refuses a claim on another holder's key", %{gov: gov} do
    k = base(gov)

    for {type, claim} <- [
          {"RestaurantDispatchGrantedV1", dispatch(gov, "deli", "courier", k.dispatcher)},
          {"DispatchDispatcherGrantedV1", dispatcher(gov, @tenant, "x2", k.device)}
        ],
        do:
          assert(
            Commands.hold(:key_fence_test, @ch, type, claim.payload, gov.signer) ==
              {:error, {:invalid, :key_not_separate}}
          )
  end

  test "Procurement.key_events/3 keeps every route and operator version that bound a key",
       %{gov: gov} do
    first = new_member()
    second = new_member()
    other_gov = new_member("governance")

    {:ok, _} =
      Log.append(declare(other_gov, "governance", other_gov.signer.key_id, other_gov, @other))

    {:ok, [v1]} = Log.append(route(gov, "c1", first))
    {:ok, [v2]} = Log.append(route(gov, "c1", second))
    {:ok, [v3]} = Log.append(route(gov, "c1", first))
    {:ok, [v4]} = Log.append(route(gov, "c1", first, active: false))
    {:ok, [op]} = Log.append(operator(gov, "c1", "o1", other_gov))
    {:ok, [elsewhere]} = Log.append(route(other_gov, "c1", first, chapter: @other))
    state = Procurement.state(Log.gate())

    assert Procurement.key_events(state, @ch, first.signer.pubkey) == [v1, v3, v4]
    # Ledger order, not the order the gate's event map iterates in.
    reordered = %{state | events: %{"a" => v4, "b" => v3, "c" => v1}}
    assert Procurement.key_events(reordered, @ch, first.signer.pubkey) == [v1, v3, v4]
    assert Procurement.key_events(state, @ch, {:bytes, second.signer.pubkey}) == [v2]
    assert Procurement.key_events(state, @ch, other_gov.signer.pubkey) == [op]
    assert Procurement.key_events(state, @other, first.signer.pubkey) == [elsewhere]
    assert Procurement.key_events(state, @other, second.signer.pubkey) == []
  end

  # -- Properties: pure, against the gate fold the appender runs --------------

  property "P0: an admitted claim is listed among its key's holdings under its holder" do
    pool = pool()

    check all(intents <- list_of(intent(), max_length: 30), max_runs: 200) do
      for {env, _gate, :ok, next} <- judge(intents, pool), holder = KeyFence.holder(env) do
        holdings = KeyFence.holdings(next, env.chapter_id, env.payload["pubkey"])
        assert {holder, KeyFence.witness(env)} in holdings
      end
    end
  end

  property "P1: within a chapter, each admitted key has one holder; a refused claim still folds" do
    pool = pool()
    {:ok, seen} = Agent.start_link(fn -> MapSet.new() end)

    check all(intents <- list_of(intent(), max_length: 30), max_runs: 200) do
      steps = judge(intents, pool)
      admitted = for {env, _gate, :ok, _next} <- steps, do: env
      genesis = Enum.flat_map(pool.genesis, &bound/1)
      held = Enum.scan(admitted, genesis, &track/2)

      for bindings <- held, do: assert(one_holder?(bindings))

      for {env, before} <- Enum.zip(admitted, [genesis | held]),
          fact = shared(env, before),
          do: Agent.update(seen, &MapSet.put(&1, fact))

      for {env, gate, verdict, _next} <- steps do
        if KeyFence.holder(env) do
          # Key IDs are fresh, so the fence is all a claim can meet, and an
          # appender without it would have admitted the claim: it folds.
          assert verdict in [:ok, KeyFence.check(env, gate)]

          unless verdict == :ok do
            AdmissionGate.handle_event(env, gate)
            [{rule, _} | _] = KeyFence.conflicts(env, gate)
            Agent.update(seen, &MapSet.put(&1, rule))
          end
        else
          # A revocation or deactivation claims nothing, and the fence never refuses it.
          assert verdict == :ok, env.type
        end
      end
    end

    expected = MapSet.new([:operator_share, :dispatch_share | KeyFence.rules()])
    assert MapSet.subset?(expected, Agent.get(seen, & &1))
  end

  # Chapter a's governance key is one of the four keys every claim draws from.
  # `genesis` declares each chapter's governance key, before any intent.
  defp pool do
    gov = new_member("governance")
    govs = %{@ch => gov, @other => new_member("governance")}

    %{
      govs: govs,
      genesis: for({ch, g} <- govs, do: declare(g, "governance", g.signer.key_id, g, ch)),
      keys: [gov | for(_ <- 1..3, do: new_member())]
    }
  end

  defp intent do
    chapter = member_of([@ch, @other])
    key = integer(0..3)
    tenant = member_of([@tenant, @other_tenant])
    active = frequency([{3, constant(true)}, {1, constant(false)}])

    # Shares need two claims on one key: Dispatch grants and operators weigh double.
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

  # Each intent as a signed event against the gate the admitted ones before it
  # leave, judged as the append gate judges it: `{event, gate, verdict, next}`.
  defp judge(intents, pool) do
    intents
    |> Enum.with_index()
    |> Enum.flat_map_reduce(
      Enum.reduce(pool.genesis, AdmissionGate.init(), &AdmissionGate.handle_event/2),
      fn {intent, i}, gate ->
        case event(intent, "k#{i}", gate, pool) do
          nil ->
            {[], gate}

          env ->
            verdict = with :ok <- Procurement.live_check(env, gate), do: Validity.check(env, gate)
            next = if verdict == :ok, do: AdmissionGate.handle_event(env, gate), else: gate
            {[{env, gate, verdict, next}], next}
        end
      end
    )
    |> elem(0)
  end

  defp event({:role, ch, k, role}, id, _gate, pool),
    do: declare(pool.govs[ch], role, id, Enum.at(pool.keys, k), ch)

  defp event({:device, ch, k, merchant}, id, _gate, pool),
    do: device(pool.govs[ch], merchant, id, Enum.at(pool.keys, k), ch)

  defp event({:dispatch, ch, k, merchant, tenant}, id, _gate, pool),
    do: dispatch(pool.govs[ch], merchant, id, Enum.at(pool.keys, k), ch, tenant)

  defp event({:dispatcher, ch, k, tenant}, id, _gate, pool),
    do: dispatcher(pool.govs[ch], tenant, id, Enum.at(pool.keys, k), ch)

  defp event({:route, ch, k, coop, active}, _id, gate, pool),
    do: route(pool.govs[ch], coop, Enum.at(pool.keys, k), chapter: ch, gate: gate, active: active)

  defp event({:operator, ch, k, coop, op, active}, _id, gate, pool),
    do:
      operator(pool.govs[ch], coop, op, Enum.at(pool.keys, k),
        chapter: ch,
        gate: gate,
        active: active
      )

  # A revocation picks one of the chapter's current role keys, never genesis.
  defp event({:revoke_role, ch, n}, _id, gate, pool) do
    gov = pool.govs[ch]

    declared =
      for {{^ch, role}, ids} <- gate.role_keys,
          key_id <- Map.keys(ids),
          key_id != gov.signer.key_id,
          do: {role, key_id}

    with {role, key_id} <- pick(declared, n), do: revoke_role(gov, role, key_id, ch)
  end

  defp event({:revoke_grant, ch, n}, _id, gate, pool) do
    active =
      for {{^ch, merchant, key_id}, grant} <- gate.restaurant.grants,
          not Map.get(grant, :revoked, false),
          do: {merchant, key_id}

    with {merchant, key_id} <- pick(active, n),
         do: revoke_device(pool.govs[ch], merchant, key_id, ch)
  end

  defp pick([], _n), do: nil
  defp pick(choices, n), do: Enum.at(Enum.sort(choices), rem(n, length(choices)))

  # The test's own holder table, from the admitted events alone: role keys
  # while declared, grants and dispatchers forever, a procurement version only
  # when active. `{chapter, pubkey, holder, place}`.
  defp track(%{type: "RoleKeyRevoked", chapter_id: ch, payload: p}, held) do
    {role, key_id} = {p["role"], p["key_id"]}
    Enum.reject(held, &match?({^ch, _, :core, {:role, ^role, ^key_id}}, &1))
  end

  defp track(env, held), do: held ++ bound(env)

  defp bound(%{type: "RoleKeyDeclared", chapter_id: ch, payload: p}),
    do: [{ch, p["pubkey"], :core, {:role, p["role"], p["key_id"]}}]

  defp bound(%{type: type, chapter_id: ch, payload: p})
       when type in ~w(RestaurantDeviceGrantedV1 RestaurantDispatchGrantedV1),
       do: [{ch, p["pubkey"], :core, {type, p["merchant_id"]}}]

  defp bound(%{type: "DispatchDispatcherGrantedV1", chapter_id: ch, payload: p}),
    do: [{ch, p["pubkey"], {:dispatcher, p["tenant_id"], p["key_id"]}, nil}]

  defp bound(%{type: "ProcurementDispatchRouteV1", chapter_id: ch, payload: p}),
    do: if(p["active"], do: [{ch, p["pubkey"], {:route, p["cooperative_id"]}, nil}], else: [])

  defp bound(%{type: "ProcurementOperatorGrantedV1", chapter_id: ch, payload: p}),
    do: if(p["active"], do: [{ch, p["pubkey"], :operator, p["cooperative_id"]}], else: [])

  defp bound(_env), do: []

  defp one_holder?(held) do
    held
    |> Enum.group_by(fn {ch, key, _, _} -> {ch, key} end, fn {_, _, holder, _} -> holder end)
    |> Enum.all?(fn {_, holders} -> length(Enum.uniq(holders)) == 1 end)
  end

  # The legitimate shares the fence must keep admitting.
  defp shared(env, before) do
    case bound(env) do
      [{ch, key, :operator, coop}] ->
        if Enum.any?(before, &match?({^ch, ^key, :operator, other} when other != coop, &1)),
          do: :operator_share

      [{ch, key, :core, {"RestaurantDispatchGrantedV1" = type, merchant}}] ->
        if Enum.any?(
             before,
             &match?({^ch, ^key, :core, {^type, other}} when other != merchant, &1)
           ),
           do: :dispatch_share

      _ ->
        nil
    end
  end
end
