defmodule CoopSubstrate.CommercialAdmissionTest do
  @moduledoc "Signed PostgreSQL acceptance for inert, source-reserving admission only."
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.{Canonical, CommercialAdmission, Log}
  alias CoopSubstrate.Projections.{AdmissionGate, Membership}
  alias CoopSubstrate.Protocol.Envelope
  alias BizKit.Cluster.Peers

  @chapter "chapter-genesis"

  setup do
    actors = %{
      alice: new_member("member"),
      bob: new_member("member"),
      carol: new_member("member"),
      gov: new_member("governance")
    }

    for {id, key} <- [{"M-alice", :alice}, {"M-bob", :bob}, {"M-carol", :carol}] do
      actor = actors[key]

      {:ok, [_]} =
        Log.append(signed_event(actor, "MemberRegistered", registration_payload(id, actor)))
    end

    actors
  end

  defp as_role(actor, role), do: %{actor | signer: %{actor.signer | role: role}}

  defp declaration(signer, owner) do
    signed_event(signer, "RoleKeyDeclared", %{
      "role" => "governance",
      "key_id" => owner.signer.key_id,
      "pubkey" => {:bytes, owner.signer.pubkey}
    })
  end

  defp revocation(signer, owner) do
    signed_event(signer, "RoleKeyRevoked", %{
      "role" => "governance",
      "key_id" => owner.signer.key_id
    })
  end

  defp activation(ctx, attrs \\ %{}) do
    authority = Log.gate().commercial_admission.governance[{@chapter, ctx.gov.signer.key_id}]

    binding =
      if authority,
        do: %{
          "governance_event_id" => authority.event_id,
          "governance_event_hash" => {:bytes, authority.event_hash}
        },
        else: %{
          "governance_event_id" => "undeclared",
          "governance_event_hash" => {:bytes, <<0::256>>}
        }

    signed_event(
      ctx.gov,
      CommercialAdmission.activation_type(),
      Map.merge(
        Map.merge(%{"profile" => CommercialAdmission.profile(), "version" => 2}, binding),
        attrs
      )
    )
  end

  defp source_event(ctx, id, direction, amount, currency \\ "USD") do
    {debtor, creditor, debtor_id, creditor_id} =
      case direction do
        :ab -> {ctx.alice, ctx.bob, "M-alice", "M-bob"}
        :ba -> {ctx.bob, ctx.alice, "M-bob", "M-alice"}
      end

    multi_signed_event(
      [as_role(debtor, "debtor"), as_role(creditor, "creditor")],
      "ObligationRecorded",
      %{
        "obligation_id" => id,
        "debtor_id" => debtor_id,
        "creditor_id" => creditor_id,
        "amount_minor" => amount,
        "denomination" => currency
      }
    )
  end

  defp seed!(ctx) do
    {:ok, sources} =
      Log.append([
        source_event(ctx, "OB-1", :ab, 100),
        source_event(ctx, "OB-2", :ba, 60)
      ])

    Map.put(ctx, :sources, sources)
  end

  defp protected!(ctx) do
    {:ok, [authority]} = Log.append(declaration(ctx.gov, ctx.gov))
    ctx = seed!(ctx)
    {:ok, [profile]} = Log.append(activation(ctx))
    Map.merge(ctx, %{authority: authority, profile: profile})
  end

  # Expected references are computed independently from the actual committed
  # source envelopes, not copied from the new provenance projection.
  defp source_reference(env) do
    {:ok, hash} = Envelope.event_hash(env)

    Map.merge(env.payload, %{
      "original_event_id" => env.event_id,
      "original_event_hash" => {:bytes, hash},
      "source_revision" => 0,
      "latest_event_id" => env.event_id,
      "latest_event_hash" => {:bytes, hash}
    })
  end

  defp payload(ctx, id \\ "INTENT-1") do
    sources = Enum.map(ctx.sources, &source_reference/1) |> Enum.sort_by(& &1["obligation_id"])
    {:ok, digest} = Canonical.hash(sources)
    {:ok, profile_hash} = Envelope.event_hash(ctx.profile)
    {:ok, authority_hash} = Envelope.event_hash(ctx.authority)

    %{
      "profile" => CommercialAdmission.profile(),
      "version" => 2,
      "profile_event_id" => ctx.profile.event_id,
      "profile_event_hash" => {:bytes, profile_hash},
      "intent_id" => id,
      "party_a" => "M-alice",
      "party_b" => "M-bob",
      "party_a_key_revision" => 0,
      "party_b_key_revision" => 0,
      "governance_event_id" => ctx.authority.event_id,
      "governance_event_hash" => {:bytes, authority_hash},
      "denomination" => "USD",
      "sources" => sources,
      "source_terms_digest" => {:bytes, digest},
      "a_to_b" => 100,
      "b_to_a" => 60,
      "setoff" => 60
    }
  end

  defp intent(ctx, p) do
    multi_signed_event(
      [as_role(ctx.alice, "party_a"), as_role(ctx.bob, "party_b"), ctx.gov],
      CommercialAdmission.reservation_type(),
      p
    )
  end

  defp change_source(p, field, value) do
    [first | rest] = p["sources"]
    sources = [Map.put(first, field, value) | rest]
    {:ok, digest} = Canonical.hash(sources)
    %{p | "sources" => sources, "source_terms_digest" => {:bytes, digest}}
  end

  defp legacy_netting(ctx) do
    multi_signed_event(
      [as_role(ctx.alice, "party_a"), as_role(ctx.bob, "party_b")],
      "NettingExecuted",
      %{
        "party_a" => "M-alice",
        "party_b" => "M-bob",
        "denomination" => "USD",
        "a_to_b" => 100,
        "b_to_a" => 60,
        "setoff" => 60,
        "residual_obligation_id" => "RES-1",
        "net_debtor" => "M-alice",
        "net_creditor" => "M-bob",
        "net_minor" => 40
      }
    )
  end

  defp discharge(ctx) do
    multi_signed_event(
      [as_role(ctx.alice, "debtor"), as_role(ctx.bob, "creditor")],
      "ObligationDischarged",
      %{"obligation_id" => "OB-1"}
    )
  end

  defp assign(from, to, debtor) do
    multi_signed_event(
      [as_role(from, "assignor"), as_role(to, "assignee")],
      "ObligationAssigned",
      %{"obligation_id" => "OB-1", "new_debtor_id" => debtor}
    )
  end

  defp legacy_intent(ctx) do
    rows = Enum.map(ctx.sources, & &1.payload)
    {:ok, digest} = Canonical.hash(rows)

    multi_signed_event(
      [as_role(ctx.alice, "party_a"), as_role(ctx.bob, "party_b")],
      "CommercialSetoffIntentRecordedV1",
      %{
        "intent_id" => "V1-1",
        "party_a" => "M-alice",
        "party_b" => "M-bob",
        "denomination" => "USD",
        "sources" => rows,
        "source_terms_digest" => {:bytes, digest},
        "a_to_b" => 100,
        "b_to_a" => 60,
        "setoff" => 60
      }
    )
  end

  defp reject!(envs, reason, index \\ 0) do
    head = Log.head()
    gate = Log.gate()
    assert {:error, {:reject, ^index, ^reason}} = Log.append(envs)
    assert Log.head() == head
    assert Log.gate() == gate
  end

  test "profile requires declared current governance and cannot downgrade", ctx do
    reject!(activation(ctx), :current_commercial_governance_required)
    {:ok, [_]} = Log.append(declaration(ctx.gov, ctx.gov))
    reject!(activation(ctx, %{"version" => 99}), :unsupported_commercial_profile)
    reject!(activation(ctx, %{"profile" => "legacy"}), :unsupported_commercial_profile)
    {:ok, [_]} = Log.append(activation(ctx))
    reject!(activation(ctx), :commercial_profile_already_activated)
    reject!(activation(ctx, %{"version" => 1}), :unsupported_commercial_profile)
    before = Log.gate().commercial_admission
    restart_log()
    assert Log.gate().commercial_admission == before
  end

  test "protected chapter blocks all four new legacy paths without caller profile flags", ctx do
    ctx = protected!(ctx)

    for env <- [
          legacy_netting(ctx),
          discharge(ctx),
          assign(ctx.alice, ctx.carol, "M-carol"),
          legacy_intent(ctx)
        ] do
      reject!(env, {:legacy_commercial_event_disabled, env.type})
    end

    assert Enum.all?(Log.gate().obligations, fn {_, ob} -> ob.open end)
    assert Log.gate().commercial_admission.reservations == %{}
  end

  test "an activation signed before governance revocation cannot survive redeclaration", ctx do
    {:ok, [_]} = Log.append(declaration(ctx.gov, ctx.gov))
    other = new_member("governance")
    {:ok, [_]} = Log.append(declaration(ctx.gov, other))
    pending = activation(ctx)
    {:ok, [_]} = Log.append(revocation(other, ctx.gov))
    {:ok, [_]} = Log.append(declaration(other, ctx.gov))
    reject!(pending, :stale_commercial_governance_epoch)
    assert Log.gate().commercial_admission.profiles == %{}
    assert {:ok, [_]} = Log.append(activation(ctx))
  end

  test "activation then legacy netting in one batch rolls back the activation too", ctx do
    ctx = seed!(ctx)
    {:ok, [_]} = Log.append(declaration(ctx.gov, ctx.gov))

    reject!(
      [activation(ctx), legacy_netting(ctx)],
      {:legacy_commercial_event_disabled, "NettingExecuted"},
      1
    )

    assert Log.gate().commercial_admission.profiles == %{}
    assert {:ok, [_]} = Log.append(legacy_netting(ctx))
  end

  test "historical V1 and legacy netting replay unchanged after protection", ctx do
    ctx = seed!(ctx)
    {:ok, [v1]} = Log.append(legacy_intent(ctx))
    {:ok, [old_netting]} = Log.append(legacy_netting(ctx))
    {:ok, old_membership} = Log.replay(Membership)
    {:ok, [_]} = Log.append(declaration(ctx.gov, ctx.gov))
    {:ok, [_]} = Log.append(activation(ctx))
    {:ok, all_before} = Log.read_all()
    restart_log()
    assert {:ok, ^all_before} = Log.read_all()
    {:ok, replayed} = Log.replay(Membership)
    assert replayed.obligations == old_membership.obligations
    assert replayed.commercial_setoff_intents == old_membership.commercial_setoff_intents
    assert v1 in all_before and old_netting in all_before
    refute Log.gate().commercial_admission.sources[{@chapter, "RES-1"}].original_only
    reject!(legacy_netting(ctx), {:legacy_commercial_event_disabled, "NettingExecuted"})
    assert :ok = Log.verify_chains()
  end

  test "full committed hashes are reserved once while all obligations and financial state stay open",
       ctx do
    ctx = protected!(ctx)
    p = payload(ctx)

    assert {:ok, ^p} =
             CommercialAdmission.prepare(
               Log.gate(),
               @chapter,
               "INTENT-1",
               {"M-alice", "M-bob"},
               "USD",
               ctx.gov.signer.key_id
             )

    before = Log.gate()
    request = intent(ctx, p)
    assert {:ok, [accepted]} = Log.append(request)
    after_gate = Log.gate()
    assert after_gate.obligations == before.obligations
    assert after_gate.balances == before.balances
    assert after_gate.commercial_setoff_intents == before.commercial_setoff_intents
    row = after_gate.commercial_admission.intents[{@chapter, "INTENT-1"}]
    assert row.status == :reserved_proposal_not_discharge
    assert row.contractual_authority == :unverified

    assert row.accounting_recognition == :none and row.discharge == :none and
             row.settlement == :none

    assert row.event == accepted

    for source <- ctx.sources do
      {:ok, hash} = Envelope.event_hash(source)

      provenance =
        after_gate.commercial_admission.sources[{@chapter, source.payload["obligation_id"]}]

      assert provenance.original_event_hash == hash
      assert provenance.original_event_id == source.event_id
      assert provenance.revision == 0

      assert after_gate.commercial_admission.reservations[
               {@chapter, source.payload["obligation_id"]}
             ] ==
               {@chapter, "INTENT-1"}
    end

    assert :ok = Log.verify_chains()
  end

  test "identical-total substituted source, full hashes, revisions and order are bound", ctx do
    ctx = protected!(ctx)
    p = payload(ctx)

    for {field, value} <- [
          {"obligation_id", "OB-identical-total"},
          {"original_event_id", CoopSubstrate.ULID.generate()},
          {"original_event_hash", {:bytes, :crypto.hash(:sha256, "other-source")}},
          {"source_revision", 1},
          {"latest_event_id", CoopSubstrate.ULID.generate()},
          {"latest_event_hash", {:bytes, :crypto.hash(:sha256, "changed-revision")}}
        ] do
      reject!(intent(ctx, change_source(p, field, value)), :commercial_source_binding_mismatch)
    end

    for rows <- [
          Enum.reverse(p["sources"]),
          [hd(p["sources"])],
          [hd(p["sources"]), hd(p["sources"])]
        ] do
      reject!(intent(ctx, %{p | "sources" => rows}), :commercial_source_binding_mismatch)
    end

    reject!(
      intent(ctx, %{p | "source_terms_digest" => {:bytes, <<0::256>>}}),
      :commercial_source_digest_mismatch
    )
  end

  test "an unsigned-core hash is not a full source record hash", ctx do
    ctx = protected!(ctx)
    source = hd(ctx.sources)
    {:ok, signed_core_hash} = Canonical.hash(Envelope.signed_core_term(source))
    {:ok, record_hash} = Envelope.event_hash(source)
    refute signed_core_hash == record_hash

    reject!(
      intent(ctx, change_source(payload(ctx), "original_event_hash", {:bytes, signed_core_hash})),
      :commercial_source_binding_mismatch
    )
  end

  test "assignment out and back cannot restore original-only eligibility", ctx do
    ctx = seed!(ctx)
    {:ok, [authority]} = Log.append(declaration(ctx.gov, ctx.gov))
    {:ok, [_]} = Log.append(assign(ctx.alice, ctx.carol, "M-carol"))
    {:ok, [back]} = Log.append(assign(ctx.carol, ctx.alice, "M-alice"))
    {:ok, [profile]} = Log.append(activation(ctx))
    ctx = Map.merge(ctx, %{authority: authority, profile: profile})
    assert Log.gate().obligations[{@chapter, "OB-1"}].debtor_id == "M-alice"
    row = Log.gate().commercial_admission.sources[{@chapter, "OB-1"}]
    assert row.revision == 2 and row.latest_event_id == back.event_id
    refute row.original_only
    reject!(intent(ctx, payload(ctx)), :unsupported_commercial_source_lineage)

    assert {:error, :unsupported_commercial_source_lineage} =
             CommercialAdmission.prepare(
               Log.gate(),
               @chapter,
               "INTENT-1",
               {"M-alice", "M-bob"},
               "USD",
               ctx.gov.signer.key_id
             )

    restart_log()
    assert Log.gate().commercial_admission.sources[{@chapter, "OB-1"}] == row
  end

  test "missing signatures, unknown profile and stale activation cannot authorize V2", ctx do
    ctx = protected!(ctx)
    request = intent(ctx, payload(ctx))

    reject!(
      %{request | sigs: Map.delete(request.sigs, ctx.gov.signer.key_id)},
      {:missing_signature, ctx.gov.signer.key_id}
    )

    reject!(intent(ctx, %{payload(ctx) | "version" => 1}), :unsupported_commercial_profile)
    reject!(intent(ctx, %{payload(ctx) | "profile" => "legacy"}), :unsupported_commercial_profile)

    reject!(
      intent(ctx, %{payload(ctx) | "profile_event_hash" => {:bytes, <<0::256>>}}),
      :commercial_profile_binding_mismatch
    )
  end

  test "current member key revision is checked even after the same key is restored", ctx do
    ctx = protected!(ctx)
    request = intent(ctx, payload(ctx))
    replacement = new_member("member")

    for {old, new} <- [{ctx.bob, replacement}, {replacement, ctx.bob}] do
      {:ok, [_]} =
        Log.append(
          signed_event(as_role(old, "author"), "KeyRotated", %{
            "member_id" => "M-bob",
            "old_key_id" => old.signer.key_id,
            "new_key_id" => new.signer.key_id,
            "new_pubkey" => {:bytes, new.signer.pubkey}
          })
        )
    end

    reject!(request, {:stale_commercial_party_authority, "party_b"})
    assert Log.gate().commercial_admission.member_revisions[{@chapter, "M-bob"}] == 2
  end

  test "revocation ordered before admission denies the prepared proposal", ctx do
    ctx = protected!(ctx)
    other = new_member("governance")
    {:ok, [_]} = Log.append(declaration(ctx.gov, other))
    request = intent(ctx, payload(ctx))

    reject!(
      [revocation(other, ctx.gov), request],
      {:role_key_not_declared, "governance", ctx.gov.signer.key_id},
      1
    )

    assert Log.gate().commercial_admission.governance[{@chapter, ctx.gov.signer.key_id}].active
    {:ok, [_]} = Log.append(revocation(other, ctx.gov))
    reject!(request, {:role_key_not_declared, "governance", ctx.gov.signer.key_id})
  end

  test "revoking and redeclaring identical governance key cannot resurrect prepared consent",
       ctx do
    ctx = protected!(ctx)
    other = new_member("governance")
    {:ok, [_]} = Log.append(declaration(ctx.gov, other))
    request = intent(ctx, payload(ctx))
    {:ok, [_]} = Log.append(revocation(other, ctx.gov))
    {:ok, [_]} = Log.append(declaration(other, ctx.gov))
    reject!(request, :stale_commercial_governance_epoch)
    restart_log()
    reject!(request, :stale_commercial_governance_epoch)
  end

  test "competing intents in one atomic batch leave no partial reservation", ctx do
    ctx = protected!(ctx)
    first = intent(ctx, payload(ctx))
    second = intent(ctx, payload(ctx, "INTENT-2"))
    reject!([first, second], :commercial_source_already_reserved, 1)
    assert Log.gate().commercial_admission.intents == %{}
    assert Log.gate().commercial_admission.reservations == %{}
    assert {:ok, [_]} = Log.append(first)
    reject!(second, :commercial_source_already_reserved)
    reject!(intent(ctx, payload(ctx)), :commercial_intent_replayed)
  end

  test "concurrent independent callers prepared at one head admit exactly one proposal", ctx do
    ctx = protected!(ctx)
    Peers.distribute!()
    {_, peer} = Peers.start!()
    Peers.mesh!([peer])
    requests = [intent(ctx, payload(ctx)), intent(ctx, payload(ctx, "INTENT-2"))]
    before = Log.head()
    owner = self()

    tasks =
      Enum.zip(requests, [node(), peer])
      |> Enum.map(fn {request, client_node} ->
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :append -> :erpc.call(client_node, Log, :append, [request])
          end
        end)
      end)

    for _ <- tasks do
      assert_receive {:ready, _}
    end

    Enum.each(tasks, &send(&1.pid, :append))
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, [_]}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, {:reject, 0, :commercial_source_already_reserved}}, &1)
           ) == 1

    assert Log.head().global_seq == before.global_seq + 1
    assert map_size(Log.gate().commercial_admission.intents) == 1
    assert map_size(Log.gate().commercial_admission.reservations) == 2
  end

  test "two independent appenders cannot commit overlapping reservations at the same version",
       ctx do
    ctx = protected!(ctx)
    first = intent(ctx, payload(ctx))
    second = intent(ctx, payload(ctx, "INTENT-2"))
    {:ok, rival} = Log.start_link(name: :commercial_rival_appender)
    Process.unlink(rival)
    on_exit(fn -> if Process.alive?(rival), do: GenServer.stop(rival) end)
    before = Log.head()
    old_server = GenServer.whereis(Log.server())
    assert {:ok, [accepted]} = Log.append(first, rival)
    assert {:error, {:store_append_failed, :wrong_expected_version}} = Log.append(second)
    await(fn -> GenServer.whereis(Log.server()) not in [nil, old_server] end)
    assert Log.head().global_seq == before.global_seq + 1
    assert Log.head().global_seq == accepted.global_seq
    reject!(second, :commercial_source_already_reserved)
    assert map_size(Log.gate().commercial_admission.intents) == 1
    assert :ok = Log.verify_chains()
  end

  test "lost-reply retry and restart recover the identical receipt and all reservations", ctx do
    ctx = protected!(ctx)
    request = intent(ctx, payload(ctx))
    assert {:ok, [accepted]} = Log.append(request)
    head = Log.head()
    gate = Log.gate()
    restart_log()
    assert Log.gate() == gate
    assert {:ok, ^gate} = Log.replay(AdmissionGate)
    assert {:ok, [^accepted]} = Log.append(request)
    assert Log.head() == head
    reject!(intent(ctx, payload(ctx, "INTENT-2")), :commercial_source_already_reserved)
    reject!(legacy_netting(ctx), {:legacy_commercial_event_disabled, "NettingExecuted"})
  end

  test "process death after commit reconstructs the profile, reservation and exact receipt",
       ctx do
    ctx = protected!(ctx)
    request = intent(ctx, payload(ctx))
    assert {:ok, [accepted]} = Log.append(request)
    before = Log.gate()
    head = Log.head()
    old_server = GenServer.whereis(Log.server())
    Process.exit(old_server, :kill)
    await(fn -> GenServer.whereis(Log.server()) not in [nil, old_server] end)
    assert Log.gate() == before
    assert Log.head() == head
    assert {:ok, [^accepted]} = Log.append(request)
    reject!(intent(ctx, payload(ctx, "INTENT-2")), :commercial_source_already_reserved)
    assert :ok = Log.verify_chains()
  end

  test "historical exact retry remains a receipt after authority is revoked", ctx do
    ctx = protected!(ctx)
    other = new_member("governance")
    {:ok, [_]} = Log.append(declaration(ctx.gov, other))
    request = intent(ctx, payload(ctx))
    {:ok, [accepted]} = Log.append(request)
    {:ok, [_]} = Log.append(revocation(other, ctx.gov))
    head = Log.head()
    restart_log()
    assert {:ok, [^accepted]} = Log.append(request)
    assert Log.head() == head

    reject!(
      intent(ctx, payload(ctx, "INTENT-2")),
      {:role_key_not_declared, "governance", ctx.gov.signer.key_id}
    )
  end

  test "a new source in a failing batch does not survive through tentative full hashes", ctx do
    ctx = protected!(ctx)
    extra = source_event(ctx, "OB-3", :ab, 20)
    stale = intent(ctx, payload(ctx))
    reject!([extra, stale], :commercial_source_binding_mismatch, 1)
    refute Map.has_key?(Log.gate().obligations, {@chapter, "OB-3"})
    refute Map.has_key?(Log.gate().commercial_admission.sources, {@chapter, "OB-3"})
    assert {:ok, [_]} = Log.append(stale)
  end

  test "a same-batch original source has identical validation, committed and replay hashes",
       ctx do
    ctx = protected!(ctx)
    original = source_event(ctx, "OB-3", :ab, 20)
    head = Log.head()
    {:ok, stream} = Envelope.stream_id(original)

    predicted =
      Envelope.with_log_assignment(original, %{
        stream_id: stream,
        stream_seq: 1,
        prev_stream_hash: nil,
        global_seq: head.global_seq + 1,
        prev_global_hash: head.global_hash
      })

    p = payload(%{ctx | sources: ctx.sources ++ [predicted]}) |> Map.put("a_to_b", 120)
    request = intent(ctx, p)
    assert {:ok, [^predicted, _]} = Log.append([original, request])
    gate = Log.gate()
    {:ok, expected_hash} = Envelope.event_hash(predicted)

    assert gate.commercial_admission.sources[{@chapter, "OB-3"}].original_event_hash ==
             expected_hash

    assert map_size(gate.commercial_admission.reservations) == 3
    restart_log()
    assert Log.gate() == gate
    assert {:ok, ^gate} = Log.replay(AdmissionGate)
    assert :ok = Log.verify_chains()
  end

  test "changed payload under an accepted event ID never obtains another receipt", ctx do
    ctx = protected!(ctx)
    request = intent(ctx, payload(ctx))
    assert {:ok, [_]} = Log.append(request)
    changed = intent(ctx, payload(ctx, "INTENT-2"))
    changed = %{changed | event_id: request.event_id, sigs: %{}}

    changed =
      Enum.reduce([ctx.alice, ctx.bob, ctx.gov], changed, fn actor, env ->
        {:ok, signed} = Envelope.sign(env, actor.signer.key_id, actor.seed)
        signed
      end)

    head = Log.head()
    assert {:error, :commercial_event_id_reused} = Log.append(changed)
    assert Log.head() == head
    restart_log()
    assert {:error, :commercial_event_id_reused} = Log.append(changed)
    assert Log.head() == head
  end

  test "V2 cannot use a proposed activation that is absent from the authoritative chapter", ctx do
    {:ok, [authority]} = Log.append(declaration(ctx.gov, ctx.gov))
    ctx = seed!(ctx)
    profile = activation(ctx)
    # A caller-created profile reference is not a recorded activation.
    ctx = Map.merge(ctx, %{authority: authority, profile: profile})
    reject!(intent(ctx, payload(ctx)), :commercial_profile_not_active)
  end

  test "repeated signer roles are refused by the protected profile", ctx do
    ctx = protected!(ctx)
    extra = new_member("party_a")

    request =
      multi_signed_event(
        [as_role(ctx.alice, "party_a"), as_role(ctx.bob, "party_b"), ctx.gov, extra],
        CommercialAdmission.reservation_type(),
        payload(ctx)
      )

    reject!(request, :invalid_commercial_signer_set)
  end

  test "mixed currency and one-way positions cannot acquire a reservation", ctx do
    {:ok, [authority]} = Log.append(declaration(ctx.gov, ctx.gov))

    {:ok, sources} =
      Log.append([
        source_event(ctx, "OB-1", :ab, 100),
        source_event(ctx, "OB-2", :ba, 60, "EUR")
      ])

    {:ok, [profile]} = Log.append(activation(ctx))
    ctx = Map.merge(ctx, %{authority: authority, profile: profile, sources: sources})
    reject!(intent(ctx, payload(ctx)), :invalid_commercial_source_count)
    assert Log.gate().commercial_admission.reservations == %{}
  end

  test "unprotected chapter keeps its prior legacy admission semantics", ctx do
    ctx = seed!(ctx)
    assert {:ok, [_]} = Log.append(legacy_netting(ctx))
    refute Log.gate().obligations[{@chapter, "OB-1"}].open
    assert Log.gate().obligations[{@chapter, "RES-1"}].open
  end

  defp await(fun, remaining \\ 200) do
    cond do
      fun.() ->
        :ok

      remaining > 0 ->
        Process.sleep(10)
        await(fun, remaining - 1)

      true ->
        flunk("canonical appender did not recover")
    end
  end
end
