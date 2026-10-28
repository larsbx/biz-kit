Code.require_file("../../federation_service/test/support/helpers.exs", __DIR__)

defmodule CoopSubstrate.FederationAuthorityTest do
  use CoopSubstrate.LogCase, async: false
  alias CoopSubstrate.{FederationAuthority, Log}
  alias FederationService.{Store, SubscriptionAuthority}
  @actor "https://alpha.example/actors/shop"
  @peer "https://beta.example/actors/shop"
  @follow @peer <> "/activities/follow"
  @chapter "chapter-genesis"

  setup do
    gov = new_member("governance")
    {:ok, _} = Log.append(declaration(gov))
    {:ok, conn} = raw_conn()
    context = %{chapter_id: @chapter, local_actor: @actor, connection: conn, schema: "public"}
    now = System.system_time(:second)
    %{gov: gov, conn: conn, context: context, now: now}
  end

  defp declaration(gov) do
    signed_event(gov, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => gov.signer.key_id,
      "pubkey" => {:bytes, gov.signer.pubkey}
    })
  end

  defp activity(source, op \\ "accept") do
    @actor <>
      "/activities/subscription-" <>
      op <>
      "-" <>
      Base.encode16(:crypto.hash(:sha256, source), case: :lower)
  end

  defp grant(c, overrides \\ %{}, signer \\ nil) do
    signed_event(
      signer || c.gov,
      "FederationSubscriptionGrantedV1",
      Map.merge(
        %{
          "local_actor" => @actor,
          "follow_id" => @follow,
          "activity_id" => activity("decision"),
          "operation" => "accept",
          "scope" => "public_subscription_control",
          "not_before" => c.now - 1,
          "expires_at" => c.now + 3600
        },
        overrides
      )
    )
  end

  defp revoke(c, grant) do
    signed_event(c.gov, "FederationSubscriptionRevokedV1", %{"grant_event_id" => grant.event_id})
  end

  defp request(grant) do
    %{
      local_actor: @actor,
      follow_id: @follow,
      operation: :accept,
      receipt: grant.event_id,
      activity_id: activity("decision")
    }
  end

  defp run(c, grant, effect \\ fn -> :executed end) do
    FederationAuthority.port(c.context).(request(grant), effect)
  end

  test "admitted governance signature binds every intent field, scope, and current validity", c do
    env = grant(c)
    {:ok, _} = Log.append(env)
    assert {:ok, :executed} = run(c, env)
    gate = Log.gate()
    assert :ok = FederationAuthority.authorize(gate, c.context, request(env), c.now)

    for {field, bad} <- [
          local_actor: @peer,
          follow_id: @follow <> "-other",
          operation: :reject,
          receipt: "opaque-host-receipt",
          activity_id: activity("different")
        ] do
      assert {:error, :unverified_local_authority} =
               FederationAuthority.authorize(
                 gate,
                 c.context,
                 Map.put(request(env), field, bad),
                 c.now
               )
    end

    for now <- [c.now - 2, c.now + 3600] do
      assert {:error, :unverified_local_authority} =
               FederationAuthority.authorize(gate, c.context, request(env), now)
    end

    assert {:error, :unverified_local_authority} =
             FederationAuthority.authorize(
               gate,
               %{c.context | chapter_id: "foreign"},
               request(env),
               c.now
             )
  end

  test "undeclared self-signed governance, forged signatures, and widened scope never enter the ledger",
       c do
    stranger = new_member("governance")

    for env <- [
          grant(c, %{}, stranger),
          grant(c, %{"scope" => "payments"}),
          grant(c, %{"operation" => "follow"}),
          grant(c, %{"activity_id" => @peer <> "/activities/accept"})
        ] do
      assert {:error, _} = Log.append(env)
    end

    env = grant(c)
    forged = %{env | payload: Map.put(env.payload, "follow_id", @follow <> "-forged")}
    assert {:error, _} = Log.append(forged)
    assert Log.gate().federation_grants == %{}
  end

  test "revocation survives appender recovery and stale SQL-fenced appenders cannot execute", c do
    env = grant(c)
    {:ok, _} = Log.append(env)
    stale = start_supervised!({Log, name: :stale_federation_appender})
    {:ok, _} = Log.append(revoke(c, env))
    assert {:error, :unverified_local_authority} = run(c, env, fn -> flunk("revoked effect") end)
    context = Map.put(c.context, :server, stale)

    assert {:error, :unverified_local_authority} =
             FederationAuthority.port(context).(request(env), fn -> flunk("stale gate effect") end)

    restart_log()
    assert {:error, :unverified_local_authority} = run(c, env)
  end

  test "revoking and redeclaring an issuer key never resurrects its grants", c do
    env = grant(c)
    {:ok, _} = Log.append(env)
    other = new_member("governance")

    {:ok, _} =
      Log.append(
        signed_event(c.gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => other.signer.key_id,
          "pubkey" => {:bytes, other.signer.pubkey}
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(other, "RoleKeyRevoked", %{
          "role" => "governance",
          "key_id" => c.gov.signer.key_id
        })
      )

    {:ok, _} =
      Log.append(
        signed_event(other, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => c.gov.signer.key_id,
          "pubkey" => {:bytes, c.gov.signer.pubkey}
        })
      )

    restart_log()
    assert {:error, :unverified_local_authority} = run(c, env)
  end

  test "effect and revocation have a defined order and the ledger row is locked across sessions",
       c do
    env = grant(c)
    {:ok, _} = Log.append(env)
    parent = self()

    executing =
      Task.async(fn ->
        run(c, env, fn ->
          send(parent, {:entered, self()})

          receive do
            :release -> :executed
          after
            3000 -> flunk("test effect not released")
          end
        end)
      end)

    assert_receive {:entered, appender}, 2000
    {:ok, independent} = raw_conn()

    assert {:error, :lock_busy} =
             Postgrex.transaction(independent, fn conn ->
               case Postgrex.query(
                      conn,
                      "SELECT stream_id FROM streams WHERE stream_uuid = 'ledger' FOR UPDATE NOWAIT",
                      []
                    ) do
                 {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} ->
                   Postgrex.rollback(conn, :lock_busy)

                 other ->
                   flunk("ledger row was not locked: #{inspect(other)}")
               end
             end)

    revoking = Task.async(fn -> Log.append(revoke(c, env)) end)
    assert Task.yield(revoking, 20) == nil
    send(appender, :release)
    assert {:ok, :executed} = Task.await(executing)
    assert {:ok, _} = Task.await(revoking)
    assert {:error, :unverified_local_authority} = run(c, env)
  end

  test "native port journals the approved intent, then refuses it after revocation and store restart",
       c do
    dir = Path.join(System.tmp_dir!(), "native-federation-#{System.unique_integer([:positive])}")
    {:ok, store} = Store.start_link(directory: dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    config =
      FederationService.config!(
        actor: @actor,
        peers: [@peer],
        store: store,
        private_key: nil,
        subscription_authority: FederationAuthority.port(c.context)
      )

    {:ok, follow} = FederationCore.Subscriptions.follow(@peer, @actor, @follow)
    {:ok, :pending} = Store.call(store, {:subscription, {:receive, follow, @peer, @actor, c.now}})
    env = grant(c)
    {:ok, _} = Log.append(env)

    assert {:error, :unverified_local_authority} =
             FederationService.respond_follow(config, @follow, :accept, "different", env.event_id)

    head = Log.head()

    assert {:ok, :accepted} =
             FederationService.respond_follow(config, @follow, :accept, "decision", env.event_id)

    # Operational work never writes another business event.
    assert Log.head() == head
    [{id, row}] = Map.to_list(Store.call(store, :snapshot).subscription_outbox)
    assert id == activity("decision")

    assert {:ok, :delivery_candidate} =
             SubscriptionAuthority.run(config, @follow, :accept, env.event_id, id, fn ->
               :delivery_candidate
             end)

    {:ok, _} = Log.append(revoke(c, env))
    GenServer.stop(store)
    {:ok, restarted} = Store.start_link(directory: dir)
    config = %{config | store: restarted}

    assert {:error, :unverified_local_authority} =
             SubscriptionAuthority.run(config, @follow, :accept, env.event_id, id, fn ->
               flunk("revoked delivery")
             end)

    assert Store.call(restarted, :snapshot).subscription_outbox[id] == row
    GenServer.stop(restarted)
  end

  test "unavailable or misconfigured fence never invokes an effect", c do
    env = grant(c)
    {:ok, _} = Log.append(env)
    {:ok, dead} = raw_conn()
    GenServer.stop(dead)
    context = %{c.context | connection: dead}

    assert {:error, :unverified_local_authority} =
             FederationAuthority.port(context).(request(env), fn -> flunk("unfenced effect") end)

    assert_raise MatchError, fn ->
      FederationAuthority.port(%{c.context | schema: "public; DROP TABLE events"})
    end

    assert Process.alive?(GenServer.whereis(Log.server()))
  end

  test "future grants cannot use a caller-supplied clock to authorize early", c do
    env = grant(c, %{"not_before" => c.now + 3600, "expires_at" => c.now + 7200})
    {:ok, _} = Log.append(env)
    assert {:error, :unverified_local_authority} = run(c, env)
  end

  test "Reject and Undo grants remain confined to their exact native operation", c do
    dir = Path.join(System.tmp_dir!(), "native-operations-#{System.unique_integer([:positive])}")
    {:ok, store} = Store.start_link(directory: dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    config =
      FederationService.config!(
        actor: @actor,
        peers: [@peer],
        store: store,
        private_key: nil,
        subscription_authority: FederationAuthority.port(c.context)
      )

    {:ok, follow} = FederationCore.Subscriptions.follow(@peer, @actor, @follow)
    {:ok, :pending} = Store.call(store, {:subscription, {:receive, follow, @peer, @actor, c.now}})
    reject = grant(c, %{"operation" => "reject", "activity_id" => activity("decision", "reject")})
    {:ok, _} = Log.append(reject)

    assert {:error, :unverified_local_authority} =
             FederationService.respond_follow(
               config,
               @follow,
               :accept,
               "decision",
               reject.event_id
             )

    assert {:ok, :rejected} =
             FederationService.respond_follow(
               config,
               @follow,
               :reject,
               "decision",
               reject.event_id
             )

    assert {:ok, :begun} = FederationService.follow(config, @peer, "outgoing")
    {:ok, outgoing_id} = FederationService.subscription_activity_id(config, :follow, "outgoing")

    undo =
      grant(c, %{
        "operation" => "undo",
        "follow_id" => outgoing_id,
        "activity_id" => activity("decision", "undo")
      })

    {:ok, _} = Log.append(undo)

    assert {:ok, :withdrawn} =
             FederationService.undo_follow(config, outgoing_id, "decision", undo.event_id)

    assert Store.call(store, :snapshot).subscriptions[outgoing_id].status == :withdrawn
    GenServer.stop(store)
  end

  defp tls_nodes(c) do
    dir = FederationService.TestHelpers.temp()
    ca = FederationService.TestHelpers.certs(dir)

    ports =
      for _ <- 1..2 do
        {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
        {:ok, port} = :inet.port(socket)
        :gen_tcp.close(socket)
        port
      end

    network = [
      test_routes:
        Map.new(Enum.zip(["alpha.example", "beta.example"], ports), fn {host, port} ->
          {host, {{127, 0, 0, 1}, port}}
        end),
      test_cacerts: [ca]
    ]

    configs =
      for {host, port, actor, peer, store} <- [
            {"alpha.example", hd(ports), @actor, @peer, :native_alpha_store},
            {"beta.example", List.last(ports), @peer, @actor, :native_beta_store}
          ] do
        key = FederationService.TestHelpers.key()
        keyfile = dir <> "/#{host}.signing"

        File.write!(
          keyfile,
          :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
        )

        authority = FederationAuthority.port(%{c.context | local_actor: actor})

        opts = [
          actor: actor,
          peers: [peer],
          store_name: store,
          directory: dir <> "/" <> host,
          signing_keyfile: keyfile,
          certfile: dir <> "/#{host}.pem",
          keyfile: dir <> "/#{host}.key",
          port: port,
          network: network,
          worker: false,
          subscription_authority: authority
        ]

        start_supervised!(Supervisor.child_spec({FederationService.Node, opts}, id: host))

        FederationService.config!(
          actor: actor,
          peers: [peer],
          store: store,
          private_key: key,
          network: network,
          subscription_authority: authority
        )
      end

    on_exit(fn -> File.rm_rf!(dir) end)
    configs
  end

  for revoked <- [false, true] do
    @revoked revoked
    test "native signed TLS delivery revalidates current grant (revoked=#{revoked})", c do
      [alpha, beta] = tls_nodes(c)
      assert {:ok, :begun} = FederationService.follow(beta, @actor, "tls-follow")
      [follow_id] = Map.keys(Store.call(beta.store, :snapshot).subscriptions)
      FederationService.deliver_subscriptions(beta)
      assert Store.call(alpha.store, :snapshot).subscriptions[follow_id].status == :pending
      env = grant(c, %{"follow_id" => follow_id})
      {:ok, _} = Log.append(env)

      assert {:ok, :accepted} =
               FederationService.respond_follow(
                 alpha,
                 follow_id,
                 :accept,
                 "decision",
                 env.event_id
               )

      if @revoked, do: assert({:ok, _} = Log.append(revoke(c, env)))
      before = Log.head()
      FederationService.deliver_subscriptions(alpha)
      remote = Store.call(beta.store, :snapshot).subscriptions[follow_id]
      queued = Store.call(alpha.store, :snapshot).subscription_outbox[activity("decision")]
      assert Log.head() == before

      if @revoked do
        assert remote.status == :pending
        assert queued.status == :pending and queued.attempts == 0
      else
        assert remote.status == :accepted
        assert queued.status == :delivered
      end
    end
  end
end
