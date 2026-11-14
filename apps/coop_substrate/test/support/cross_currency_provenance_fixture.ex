defmodule CoopSubstrate.CrossCurrencyProvenanceFixture do
  @moduledoc """
  TEST ONLY: a bounded bridge from the real signed local log to inert consent.

  This fixture independently derives original source hashes and current member
  keys from at most 64 authenticated records. Its detached steward attestations
  are synthetic corporate-review inputs, not an implemented corporate-authority
  service. A registered steward key establishes neither corporate appointment
  nor legal permission. No production event schema or admission is extended.

  The caller pins a fixture governance root independently of the consent proof.
  Head equality detects intervening appends; it is not a durable reservation,
  distributed freshness guarantee, or protection against a later append.
  """

  alias BarterCore.CrossCurrencyConsent, as: Consent
  alias CoopSubstrate.{Canonical, CommercialSourceLineage, Crypto, Log, SignedConsumerSource}
  alias CoopSubstrate.Projections.AdmissionGate
  alias CoopSubstrate.Protocol.{Envelope, Validity}

  @max_events 64
  @history_types ~w(RoleKeyDeclared RoleKeyRevoked MemberRegistered KeyRotated EntityRegistered ObligationRecorded ObligationAssigned ObligationDischarged)
  @grant_schema "bizkit.test.cross-currency-corporate-grant.v1"
  @grant_domain "biz-kit/test-fixture/cross-currency-corporate-grant/v1\0"
  @grant_fields ~w(chapter_id consent_commitment expires_at_ms issuer_event_hash issuer_event_id issuer_key_id issuer_pubkey issuer_role member_key_id member_pubkey member_revision not_before_ms principal record_ref schema)

  @doc "Fresh bounded signed-history snapshot; opts must pin trusted_governance."
  def snapshot(plan, chapter, now, opts) do
    safely(fn ->
      with :ok <- request_shape(plan, chapter, now, opts),
           {:ok, head, events, gate} <- capture(chapter, opts),
           {:ok, inputs} <- source_inputs(plan, chapter, events, gate),
           {:ok, _proof} <-
             Consent.prepare(plan, chapter, inputs.source_hashes, inputs.members, now),
           :ok <- after_capture(opts),
           :ok <- unchanged_head(head) do
        {:ok,
         Map.merge(inputs, %{
           chapter_id: chapter,
           observed_head: head,
           event_count: length(events),
           gate: gate,
           steward_declarations: steward_declarations(events, chapter),
           evidence_class: :synthetic_fixture_using_signed_local_history,
           actual_corporate_authority: :unverified
         })}
      end
    end)
  end

  @doc "Prepare a consent using only the freshly derived fixture source inputs."
  def prepare(plan, chapter, now, opts) do
    with {:ok, snapshot} <- snapshot(plan, chapter, now, opts),
         {:ok, proof} <-
           Consent.prepare(plan, chapter, snapshot.source_hashes, snapshot.members, now) do
      {:ok, proof, snapshot}
    end
  end

  @doc """
  Sign a detached SYNTHETIC grant using an explicitly supplied test actor.
  The actor is the LogCase shape %{signer: %{key_id:, pubkey:}, seed: seed}.
  No key is obtained from application configuration or a production key store.
  """
  def issue_grant(snapshot, proof, principal, issuer, now, expires) do
    safely(fn ->
      with true <- is_map(snapshot) and is_map(proof) and is_binary(principal),
           true <- is_integer(now) and now >= 0 and is_integer(expires) and expires > now,
           %{key_id: key_id, pubkey: pubkey} <- snapshot.members[principal],
           revision when is_integer(revision) and revision >= 0 <-
             snapshot.member_revisions[principal],
           %{signer: %{key_id: issuer_id, pubkey: issuer_pubkey}, seed: <<_::256>> = seed} <-
             issuer,
           %{event_id: event_id, event_hash: event_hash, pubkey: ^issuer_pubkey} <-
             snapshot.steward_declarations[issuer_id],
           ^issuer_pubkey <- Crypto.pubkey_from_seed(seed),
           <<_::256>> = commitment <- proof.commitment,
           true <- proof.chapter_id == snapshot.chapter_id do
        body = %{
          "schema" => @grant_schema,
          "chapter_id" => snapshot.chapter_id,
          "principal" => principal,
          "consent_commitment" => {:bytes, commitment},
          "member_key_id" => key_id,
          "member_pubkey" => {:bytes, pubkey},
          "member_revision" => revision,
          "issuer_role" => "steward",
          "issuer_key_id" => issuer_id,
          "issuer_pubkey" => {:bytes, issuer_pubkey},
          "issuer_event_id" => event_id,
          "issuer_event_hash" => {:bytes, event_hash},
          "not_before_ms" => now,
          "expires_at_ms" => expires,
          "record_ref" => "fixture://corporate-grant/" <> principal
        }

        with {:ok, encoded} <- Canonical.encode(body) do
          {:ok, %{body: body, signature: Crypto.sign(@grant_domain <> encoded, seed)}}
        end
      else
        _ -> {:error, :invalid_synthetic_grant_request}
      end
    end)
  end

  @doc "Read-only provenance, synthetic-grant, and cryptographic-consent verification."
  def verify(proof, plan, chapter, signatures, grants, now, opts) do
    safely(fn ->
      with {:ok, snapshot} <- snapshot(plan, chapter, now, opts),
           {:ok, cryptographic} <-
             Consent.verify(
               proof,
               plan,
               chapter,
               snapshot.source_hashes,
               snapshot.members,
               signatures,
               now
             ),
           :ok <- verify_grants(snapshot, proof, grants, now),
           :ok <- unchanged_head(snapshot.observed_head) do
        {:ok,
         Map.merge(cryptographic, %{
           fixture_evidence: %{
             evidence_class: :synthetic_fixture_using_signed_local_history,
             source_history: :authenticated_local_test_prefix,
             observed_head: snapshot.observed_head,
             event_count: snapshot.event_count,
             sources: snapshot.sources,
             synthetic_grants: :checked_against_fixture_policy,
             actual_corporate_authority: :unverified,
             real_world_invoice_validity: :unverified,
             source_eligibility_and_expiry: :host_assertions,
             legal_classification: :undetermined
           },
           discharge: :not_executed,
           accounting_posting: :none,
           source_reservation: :none
         })}
      end
    end)
  end

  defp request_shape(plan, chapter, now, opts) do
    valid =
      is_map(plan) and is_binary(chapter) and byte_size(chapter) in 1..256 and
        String.valid?(chapter) and is_integer(now) and now >= 0 and
        is_list(opts) and Keyword.keyword?(opts) and
        Enum.all?(Keyword.keys(opts), &(&1 in [:trusted_governance, :after_capture])) and
        length(Enum.uniq(Keyword.keys(opts))) == length(opts)

    if valid and valid_root?(Keyword.get(opts, :trusted_governance)) and
         (not Keyword.has_key?(opts, :after_capture) or
            is_function(Keyword.get(opts, :after_capture), 0)),
       do: :ok,
       else: {:error, :invalid_fixture_request}
  end

  defp valid_root?(%{key_id: key, pubkey: <<_::256>>} = root),
    do: is_binary(key) and byte_size(key) in 1..256 and map_size(root) == 2

  defp valid_root?(_), do: false

  defp capture(chapter, opts) do
    head = Log.head()

    with %{global_seq: count, global_hash: <<_::256>>} when count in 1..@max_events <- head,
         {:ok, ^count} <- SignedConsumerSource.verified_head(),
         {:ok, events} when is_list(events) and length(events) == count <-
           SignedConsumerSource.read_page(1, count),
         :ok <- pinned_genesis(events, chapter, Keyword.fetch!(opts, :trusted_governance)),
         {:ok, gate, last_hash} <- replay(events),
         true <- last_hash == head.global_hash,
         true <- gate == Log.gate(),
         :ok <- unchanged_head(head) do
      {:ok, head, events, gate}
    else
      %{global_seq: count} when is_integer(count) and count > @max_events ->
        {:error, :fixture_history_limit_exceeded}

      {:error, _} = error ->
        error

      _ ->
        {:error, :unverified_fixture_history}
    end
  end

  defp pinned_genesis(events, chapter, trusted) do
    genesis =
      Enum.find(events, fn
        %Envelope{
          chapter_id: ^chapter,
          type: "RoleKeyDeclared",
          payload: %{"role" => "governance"}
        } ->
          true

        _ ->
          false
      end)

    case genesis do
      %Envelope{payload: %{"key_id" => key_id, "pubkey" => {:bytes, pubkey}}}
      when key_id == trusted.key_id and pubkey == trusted.pubkey ->
        :ok

      _ ->
        {:error, :fixture_governance_root_mismatch}
    end
  end

  defp replay(events) do
    events
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, AdmissionGate.init(), nil, %{}}, fn
      {%Envelope{type: type} = env, seq}, {:ok, gate, previous_hash, streams}
      when type in @history_types ->
        {previous_seq, previous_stream_hash} = Map.get(streams, env.stream_id, {0, nil})

        with :ok <- Envelope.verify(env),
             {:ok, stream_id} <- Envelope.stream_id(env),
             true <- env.stream_id == stream_id and env.global_seq == seq,
             true <- env.prev_global_hash == previous_hash,
             true <- env.stream_seq == previous_seq + 1,
             true <- env.prev_stream_hash == previous_stream_hash,
             :ok <- Validity.check(env, gate),
             {:ok, hash} <- Envelope.event_hash(env) do
          {:cont,
           {:ok, AdmissionGate.handle_event(env, gate), hash,
            Map.put(streams, stream_id, {env.stream_seq, hash})}}
        else
          _ -> {:halt, {:error, :unverified_fixture_history}}
        end

      _, _ ->
        {:halt, {:error, :unsupported_fixture_history}}
    end)
    |> case do
      {:ok, gate, hash, _streams} -> {:ok, gate, hash}
      error -> error
    end
  end

  defp source_inputs(%{a_to_b: a, b_to_a: b}, chapter, events, gate)
       when is_map(a) and is_map(b) do
    with {:ok, first} <- source(a, chapter, events, gate),
         {:ok, second} <- source(b, chapter, events, gate),
         true <- a.id != b.id and a.debtor != b.debtor,
         {:ok, members, revisions} <- members([a.debtor, b.debtor], chapter, gate) do
      {:ok,
       %{
         source_hashes: %{a.id => first.source_event_hash, b.id => second.source_event_hash},
         sources: %{a.id => first, b.id => second},
         members: members,
         member_revisions: revisions
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_fixture_sources}
    end
  end

  defp source_inputs(_, _, _, _), do: {:error, :invalid_fixture_sources}

  defp source(%{id: id, revision: revision} = supplied, chapter, events, gate) do
    originals =
      Enum.filter(events, fn
        %Envelope{chapter_id: ^chapter, type: "ObligationRecorded", payload: p} ->
          p["obligation_id"] == id

        _ ->
          false
      end)

    with [event] <- originals,
         true <- CommercialSourceLineage.original_only?(gate, chapter, id),
         %{source_revision: ^revision, original_signed_core_digest: signed_digest} <-
           gate.commercial_source_lineage[{chapter, id}],
         true <- revision == 1 and event.stream_seq == 1,
         %{open: true} = row <- gate.obligations[{chapter, id}],
         true <- source_matches?(supplied, row, event.payload),
         false <- Map.has_key?(gate.commercial_admission.reservations, {chapter, id}),
         {:ok, source_hash} <- SignedConsumerSource.event_digest(event),
         {:ok, core_bytes} <- Envelope.signing_bytes(event),
         true <- :crypto.hash(:sha256, core_bytes) == signed_digest do
      {:ok,
       %{
         event_id: event.event_id,
         source_event_hash: source_hash,
         signed_core_digest: signed_digest,
         revision: revision
       }}
    else
      _ -> {:error, {:fixture_source_mismatch, id}}
    end
  end

  defp source(_, _, _, _), do: {:error, :invalid_fixture_sources}

  defp source_matches?(supplied, row, payload) do
    cited = %{
      "debtor_id" => Map.get(supplied, :debtor),
      "creditor_id" => Map.get(supplied, :creditor),
      "amount_minor" => Map.get(supplied, :amount_minor),
      "denomination" => Map.get(supplied, :currency)
    }

    current = %{
      "debtor_id" => row.debtor_id,
      "creditor_id" => row.creditor_id,
      "amount_minor" => row.amount_minor,
      "denomination" => row.denomination
    }

    cited == current and cited == Map.take(payload, Map.keys(cited))
  end

  defp members(principals, chapter, gate) do
    Enum.reduce_while(principals, {:ok, %{}, %{}}, fn principal, {:ok, keys, epochs} ->
      with %{key_id: key_id, pubkey: <<_::256>> = pubkey} <- gate.members[{chapter, principal}],
           revision when is_integer(revision) and revision >= 0 <-
             gate.commercial_admission.member_revisions[{chapter, principal}] do
        {:cont,
         {:ok, Map.put(keys, principal, %{key_id: key_id, pubkey: pubkey}),
          Map.put(epochs, principal, revision)}}
      else
        _ -> {:halt, {:error, {:fixture_member_unavailable, principal}}}
      end
    end)
  end

  defp steward_declarations(events, chapter) do
    Enum.reduce(events, %{}, fn
      %Envelope{
        chapter_id: ^chapter,
        type: "RoleKeyDeclared",
        payload: %{"role" => "steward", "key_id" => key, "pubkey" => {:bytes, pubkey}}
      } = event,
      records ->
        {:ok, hash} = Envelope.event_hash(event)
        Map.put(records, key, %{pubkey: pubkey, event_id: event.event_id, event_hash: hash})

      %Envelope{
        chapter_id: ^chapter,
        type: "RoleKeyRevoked",
        payload: %{"role" => "steward", "key_id" => key}
      },
      records ->
        Map.delete(records, key)

      _, records ->
        records
    end)
  end

  defp verify_grants(snapshot, proof, grants, now) when is_map(grants) do
    principals = snapshot.members |> Map.keys() |> Enum.sort()

    if Enum.sort(Map.keys(grants)) == principals do
      result =
        Enum.reduce_while(principals, {:ok, []}, fn principal, {:ok, issuers} ->
          case verify_grant(snapshot, proof, principal, grants[principal], now) do
            {:ok, issuer_pubkey} -> {:cont, {:ok, [issuer_pubkey | issuers]}}
            error -> {:halt, error}
          end
        end)

      with {:ok, issuers} <- result do
        keys = issuers ++ Enum.map(snapshot.members, fn {_, member} -> member.pubkey end)

        if length(keys) == 4 and length(Enum.uniq(keys)) == 4,
          do: :ok,
          else: {:error, :nonindependent_fixture_reviewers}
      end
    else
      {:error, :two_synthetic_grants_required}
    end
  end

  defp verify_grants(_, _, _, _), do: {:error, :two_synthetic_grants_required}

  defp verify_grant(snapshot, proof, principal, %{body: body, signature: sig} = grant, now)
       when is_map(body) and is_binary(sig) and byte_size(sig) == 64 and map_size(grant) == 2 do
    with true <- Enum.sort(Map.keys(body)) == @grant_fields,
         true <- body["schema"] == @grant_schema and body["issuer_role"] == "steward",
         {:bytes, <<_::256>> = issuer_pubkey} <- body["issuer_pubkey"],
         %{pubkey: ^issuer_pubkey} = issuer <-
           snapshot.steward_declarations[body["issuer_key_id"]],
         ^issuer_pubkey <-
           get_in(snapshot.gate.role_keys, [
             {snapshot.chapter_id, "steward"},
             body["issuer_key_id"]
           ]),
         {:ok, encoded} <- Canonical.encode(body),
         true <- Crypto.verify(@grant_domain <> encoded, sig, issuer_pubkey),
         :ok <- grant_binding(snapshot, proof, principal, body, issuer),
         :ok <- grant_time(body, now) do
      {:ok, issuer_pubkey}
    else
      {:error, _} = error -> error
      _ -> {:error, {:invalid_or_inactive_synthetic_grant, principal}}
    end
  end

  defp verify_grant(_, _, principal, _, _),
    do: {:error, {:invalid_or_inactive_synthetic_grant, principal}}

  defp grant_binding(snapshot, proof, principal, body, issuer) do
    member = snapshot.members[principal]

    if body["chapter_id"] == snapshot.chapter_id and body["principal"] == principal and
         body["consent_commitment"] == {:bytes, proof.commitment} and
         body["member_key_id"] == member.key_id and
         body["member_pubkey"] == {:bytes, member.pubkey} and
         body["member_revision"] == snapshot.member_revisions[principal] and
         body["issuer_event_id"] == issuer.event_id and
         body["issuer_event_hash"] == {:bytes, issuer.event_hash} and
         body["record_ref"] == "fixture://corporate-grant/" <> principal,
       do: :ok,
       else: {:error, {:stale_synthetic_grant, principal}}
  end

  defp grant_time(body, now) do
    starts = body["not_before_ms"]
    expires = body["expires_at_ms"]

    if is_integer(starts) and starts >= 0 and is_integer(expires) and starts < expires and
         starts <= now and now < expires,
       do: :ok,
       else: {:error, :synthetic_grant_outside_validity_window}
  end

  defp after_capture(opts) do
    case Keyword.get(opts, :after_capture) do
      nil ->
        :ok

      callback ->
        callback.()
        :ok
    end
  end

  defp unchanged_head(head) do
    if Log.head() == head, do: :ok, else: {:error, :concurrent_ledger_change}
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> {:error, :fixture_verification_unavailable}
  catch
    :exit, _ -> {:error, :fixture_verification_unavailable}
    :throw, _ -> {:error, :fixture_verification_unavailable}
  end
end
