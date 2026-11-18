defmodule CoopSubstrate.CrossCurrencyAuthorityEvidenceTest do
  use CoopSubstrate.LogCase, async: false

  alias CoopSubstrate.CrossCurrencyAuthorityEvidence, as: Evidence
  alias CoopSubstrate.CrossCurrencySourceSnapshot, as: Snapshot
  alias CoopSubstrate.Log

  @chapter "chapter-genesis"
  @alice "https://alice.example/actors/merchant"
  @bob "https://bob.example/actors/merchant"
  @usd "https://alice.example/obligations/usd-1"
  @eur "https://bob.example/obligations/eur-1"
  @operator "fixture://operator"
  @activity :bilateral_cross_currency_contractual_setoff_review

  defmodule Provider do
    @behaviour Evidence

    @impl true
    def resolve_authority(_scope, _now), do: Process.get({__MODULE__, :authority})

    @impl true
    def resolve_regulatory(_subject, _now), do: Process.get({__MODULE__, :regulatory}).()

    def install(authority, regulatory) do
      Process.put({__MODULE__, :authority}, authority)
      Process.put({__MODULE__, :regulatory}, regulatory)
    end
  end

  setup do
    alice = register!(@alice)
    bob = register!(@bob)
    record!(alice, bob, @usd, @alice, @bob, 100, "USD")
    record!(bob, alice, @eur, @bob, @alice, 80, "EUR")
    {:ok, snapshot} = Snapshot.snapshot(@chapter, {@usd, @eur})

    scope = %{
      activity: @activity,
      chapter_id: @chapter,
      operator_ref: @operator,
      sources: snapshot.source_hashes
    }

    valid_until = System.system_time(:second) + 60

    parties = %{
      @alice => party(snapshot, scope, @alice, "US-DE", valid_until),
      @bob => party(snapshot, scope, @bob, "FR", valid_until)
    }

    regulatory = regulatory_fixture(scope, parties, valid_until)
    Provider.install({:ok, parties}, fn -> {:ok, regulatory} end)

    %{alice: alice, bob: bob, snapshot: snapshot, parties: parties, regulatory: regulatory}
  end

  test "returns evidence references for the complete scoped review without ledger effects", ctx do
    before = Log.head()

    assert {:ok, receipt} = review(ctx.snapshot)
    assert receipt.evidence_contract == :verified
    assert receipt.regulatory_result == :non_prohibited
    assert receipt.regulatory_evidence_refs.assessments == refs(ctx.regulatory.assessments)
    assert receipt.admission == :not_authorized
    assert receipt.observed_head == before
    assert Log.head() == before
    assert Log.gate().obligations[{@chapter, @usd}].open
    assert Log.gate().obligations[{@chapter, @eur}].open
    assert Log.gate().commercial_admission.reservations == %{}
  end

  test "unknown, revoked and expired grants fail closed", ctx do
    for {path, value, reason} <- [
          {[@alice, :agent, :status], :revoked, :revoked_authority},
          {[@alice, :grant, :status], :revoked, :revoked_authority},
          {[@alice, :grant, :status], :unknown, :invalid_authority_evidence},
          {[@alice, :grant, :valid_until], System.system_time(:second), :stale_authority_grant}
        ] do
      Provider.install({:ok, put_in(ctx.parties, path, value)}, fn ->
        flunk("authority must fail")
      end)

      assert {:error, ^reason} = review(ctx.snapshot)
    end

    Provider.install({:error, :unavailable}, fn -> flunk("authority must fail") end)
    assert {:error, :authority_evidence_unavailable} = review(ctx.snapshot)
  end

  test "a grant cannot be transplanted to another operator or agent key epoch", ctx do
    assert {:error, :authority_scope_mismatch} =
             Evidence.review(@chapter, ctx.snapshot.source_hashes, "fixture://other", Provider)

    rotated_agent = update_in(ctx.parties, [@alice, :agent, :key, :epoch], &(&1 + 1))
    Provider.install({:ok, rotated_agent}, fn -> flunk("authority must fail") end)
    assert {:error, :authority_scope_mismatch} = review(ctx.snapshot)
  end

  test "rotation away and back changes the local epoch and replay retains it", ctx do
    away = new_member("member")
    rotate!(@bob, ctx.bob, away)
    assert {:error, :stale_member_key_epoch} = review(ctx.snapshot)
    returned = rotate!(@bob, away, ctx.bob)

    restart_log()
    assert {:ok, current} = Snapshot.snapshot(@chapter, {@usd, @eur})
    assert current.source_hashes == ctx.snapshot.source_hashes
    assert current.members == ctx.snapshot.members
    assert current.member_key_epochs[@bob] == returned.global_seq
    assert current.member_key_epochs[@alice] == ctx.snapshot.member_key_epochs[@alice]
    assert {:error, :stale_member_key_epoch} = review(current)
  end

  test "the same amount and currency cannot substitute an original source", ctx do
    substitute = "https://bob.example/obligations/eur-2"
    record!(ctx.bob, ctx.alice, substitute, @bob, @alice, 80, "EUR")

    wrong_hashes =
      ctx.snapshot.source_hashes
      |> Map.delete(@eur)
      |> Map.put(substitute, ctx.snapshot.source_hashes[@eur])

    assert {:error, :stale_or_substituted_sources} =
             Evidence.review(@chapter, wrong_hashes, @operator, Provider)

    assert {:ok, distinct} = Snapshot.snapshot(@chapter, {@usd, substitute})
    assert {:error, :authority_scope_mismatch} = review(distinct)
  end

  test "missing or stale jurisdiction evidence, mismatched assessments and provider errors are undetermined",
       ctx do
    base = ctx.regulatory

    for regulatory <- [
          {:error, :unavailable},
          {:ok, put_in(base.jurisdictions.activity_jurisdictions, [])},
          {:ok, put_in(base.jurisdictions.valid_until, System.system_time(:second))},
          {:ok, update_in(base.jurisdictions.governing_law_by_source, &Map.delete(&1, @eur))},
          {:ok, update_in(base.assessments, &Map.delete(&1, "US-IL"))},
          {:ok, put_in(base.assessments["US-IL"].jurisdiction, "US-DE")},
          {:ok,
           put_in(
             ctx.regulatory.assessments["US-IL"].jurisdiction_evidence_ref,
             "fixture://old-coverage"
           )},
          {:ok,
           put_in(
             ctx.regulatory.assessments["US-IL"].subject.scope.operator_ref,
             "fixture://other"
           )}
        ] do
      Provider.install({:ok, ctx.parties}, fn -> regulatory end)

      assert {:ok, %{regulatory_result: :undetermined, admission: :not_authorized}} =
               review(ctx.snapshot)
    end
  end

  test "a current prohibition takes precedence over favorable and missing assessments", ctx do
    base = ctx.regulatory

    regulatory =
      put_in(base.assessments["FR"].decision, :prohibited)
      |> update_in([:assessments], &Map.delete(&1, "US-IL"))

    Provider.install({:ok, ctx.parties}, fn -> {:ok, regulatory} end)

    assert {:ok, %{regulatory_result: :prohibited, admission: :not_authorized}} =
             review(ctx.snapshot)
  end

  test "a signed source closure during evidence resolution discards the result", ctx do
    test_pid = self()

    review_task =
      Task.async(fn ->
        Provider.install({:ok, ctx.parties}, fn ->
          send(test_pid, :resolving_regulatory)

          receive do
            :resume -> {:ok, ctx.regulatory}
          after
            5_000 -> {:error, :test_timeout}
          end
        end)

        review(ctx.snapshot)
      end)

    assert_receive :resolving_regulatory, 5_000

    assert {:ok, [_]} =
             Log.append(
               multi_signed_event(
                 [role(ctx.bob, "debtor"), role(ctx.alice, "creditor")],
                 "ObligationDischarged",
                 %{"obligation_id" => @eur}
               )
             )

    send(review_task.pid, :resume)
    assert {:error, :concurrent_ledger_change} = Task.await(review_task)
    refute Log.gate().obligations[{@chapter, @eur}].open
  end

  defp review(snapshot),
    do: Evidence.review(@chapter, snapshot.source_hashes, @operator, Provider)

  defp refs(assessments),
    do:
      Map.new(assessments, fn {jurisdiction, assessment} ->
        {jurisdiction, assessment.evidence_ref}
      end)

  defp register!(id) do
    member = new_member("member")

    {:ok, [_]} =
      Log.append(signed_event(member, "MemberRegistered", registration_payload(id, member)))

    member
  end

  defp role(actor, name), do: %{actor | signer: %{actor.signer | role: name}}

  defp record!(debtor, creditor, id, debtor_id, creditor_id, amount, currency) do
    {:ok, [_]} =
      Log.append(
        multi_signed_event(
          [role(debtor, "debtor"), role(creditor, "creditor")],
          "ObligationRecorded",
          %{
            "obligation_id" => id,
            "debtor_id" => debtor_id,
            "creditor_id" => creditor_id,
            "amount_minor" => amount,
            "denomination" => currency
          }
        )
      )
  end

  defp rotate!(member_id, old, new) do
    {:ok, [event]} =
      Log.append(
        signed_event(role(old, "author"), "KeyRotated", %{
          "member_id" => member_id,
          "old_key_id" => old.signer.key_id,
          "new_key_id" => new.signer.key_id,
          "new_pubkey" => {:bytes, new.signer.pubkey}
        })
      )

    event
  end

  defp party(snapshot, scope, principal, jurisdiction, valid_until) do
    signer = new_member("agent").signer
    agent_key = %{key_id: signer.key_id, pubkey: signer.pubkey, epoch: 1}
    agent_id = "fixture://agent/" <> principal

    %{
      principal: %{
        registration: %{
          jurisdiction: jurisdiction,
          registry_ref: "fixture://registry/" <> jurisdiction,
          number: principal
        },
        evidence_ref: "fixture://principal/" <> principal
      },
      agent: %{
        id: agent_id,
        key: agent_key,
        status: :active,
        evidence_ref: "fixture://identity/" <> principal
      },
      grant: %{
        scope: scope,
        principal_id: principal,
        agent_id: agent_id,
        agent_key: agent_key,
        member_key:
          Map.put(snapshot.members[principal], :epoch, snapshot.member_key_epochs[principal]),
        id: "fixture://grant/" <> principal,
        revision: 1,
        issuer_ref: "fixture://corporate-authority/" <> principal,
        status: :active,
        valid_from: 0,
        valid_until: valid_until
      }
    }
  end

  defp regulatory_fixture(scope, parties, valid_until) do
    subject = %{
      scope: scope,
      principals: Map.new(parties, fn {id, party} -> {id, party.principal.registration} end)
    }

    coverage = %{
      subject: subject,
      governing_law_by_source: %{@usd => "US-NY", @eur => "FR"},
      operator_jurisdictions: ["US-IL"],
      activity_jurisdictions: ["US-IL", "FR"],
      evidence_ref: "fixture://jurisdiction-coverage",
      valid_from: 0,
      valid_until: valid_until
    }

    assessments =
      for jurisdiction <- ["US-DE", "US-IL", "US-NY", "FR"], into: %{} do
        {jurisdiction,
         %{
           subject: subject,
           jurisdiction: jurisdiction,
           jurisdiction_evidence_ref: coverage.evidence_ref,
           decision: :non_prohibited,
           issuer_ref: "fixture://reviewer/" <> jurisdiction,
           evidence_ref: "fixture://assessment/" <> jurisdiction,
           valid_from: 0,
           valid_until: valid_until
         }}
      end

    %{jurisdictions: coverage, assessments: assessments}
  end
end
