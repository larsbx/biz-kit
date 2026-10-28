defmodule CoopSubstrate.GroupBuys do
  @moduledoc """
  Seller-home group-buy authority over the ONE canonical business ledger.

  Governance pins seller keys. Sellers grant scoped, expiring access to independently registered member keys and
  sign immutable offers. Buyers sign upfront conditional consent; the seller
  countersigns its admission. Only the serialized Log can commit that event.
  BindingRound is reconstructed from those events, never federation input.

  Credentials here concern marketplace access, not cooperative membership.
  No event collects money, holds inventory, provides escrow or dispatches.
  All group-buy records are private; no public transport is installed.
  """
  alias CoopSubstrate.{Canonical, Log}
  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.GroupBuys.EscrowAdmission
  alias CoopSubstrate.GroupBuys.Stock
  alias GroupBuyCore.Escrow
  alias GroupBuyCore.BindingRound, as: Round

  @policy "binding-at-minimum;free-withdrawal-before-activation;expiry-before-activation;cash-independent.v1"
  @seller "GroupBuySellerAuthorizedV1"
  @member "GroupBuyMemberAuthorizedV1"
  @offer "GroupBuyOfferPostedV1"
  @close "GroupBuyOfferClosedV1"
  @consent "GroupBuyConsentV1"
  @accept "GroupBuyContractAdmittedV1"
  @read "GroupBuyPrivateReadV1"
  @escrow_provider "GroupBuyEscrowProviderPinnedV1"
  @escrow_evidence "GroupBuyEscrowEvidenceAdmittedV1"
  @stock "GroupBuyStockCommandAdmittedV1"
  @provider_authority "GroupBuyEscrowProviderAuthorizedV1"
  @provider_pin "GroupBuyEscrowProviderPinnedV2"
  @funded_accept "GroupBuyFundedContractAdmittedV1"
  @offer_keys ~w(id seller sku unit currency revision expires_at capacity solo_unit_minor tiers)a
  @pledge_keys ~w(id buyer offer_id offer_revision quantity max_group_unit_minor expires_at)a

  def policy, do: @policy

  def init,
    do: %{
      sellers: %{},
      members: %{},
      offers: %{},
      rounds: %{},
      events: %{},
      consents: %{},
      pledge_credentials: %{},
      # All external custody observations use this SAME canonical Log.
      # These maps are rebuilt from signed append history at startup.
      escrow_authorities: %{},
      escrow_grants: %{},
      escrow_states: %{},
      escrow_provider_events: %{},
      escrow_custody_claims: %{},
      stock_aggregates: %{},
      stock_claims: %{}
    }

  def event_types do
    %{
      @seller =>
        spec("governance", %{
          "seller_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey,
          "expires_at" => :int,
          "expected_version" => :int
        }),
      @member =>
        spec("group_seller", %{
          "seller_id" => :string,
          "buyer_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey,
          "expires_at" => :int,
          "expected_version" => :int,
          "active" => :bool
        }),
      @offer =>
        spec("group_seller", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "offer" => :any,
          "policy" => :string
        }),
      @close => spec("group_seller", %{"seller_id" => :string, "campaign_id" => :string}),
      @consent =>
        spec("group_buyer", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "buyer_id" => :string,
          "terms_hash" => :hash,
          "policy" => :string,
          "command" => :any,
          "valid_until" => :int
        }),
      @accept =>
        spec("group_seller", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "consent" => :bytes
        }),
      @read =>
        spec("group_buyer", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "buyer_id" => :string,
          "terms_hash" => :hash,
          "encryption_key" => :pubkey,
          "valid_until" => :int
        }),
      @escrow_provider =>
        spec("group_seller", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "provider_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey,
          "active" => :bool,
          "expires_at" => :int,
          "expected_version" => :int
        }),
      @escrow_evidence =>
        spec("group_seller", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "proof" => :bytes,
          "expected_version" => :int
        }),
      @provider_authority =>
        provider_spec(%{
          "provider_id" => :string,
          "key_id" => :string,
          "pubkey" => :pubkey,
          "active" => :bool,
          "expires_at" => :int,
          "expected_version" => :int,
          "provenance_ref" => :string,
          "provenance_hash" => :hash
        }),
      @provider_pin =>
        spec("group_seller", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "provider_id" => :string,
          "authority_event_id" => :string,
          "expires_at" => :int,
          "expected_version" => :int
        }),
      @funded_accept =>
        spec("group_seller", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "consent" => :bytes,
          "proof" => :bytes,
          "expected_version" => :int
        }),
      @stock =>
        spec("group_seller", %{
          "seller_id" => :string,
          "campaign_id" => :string,
          "command" => :any,
          "source_ref" => :string
        })
    }
  end

  defp provider_spec(fields) do
    spec("governance", fields)
    |> Map.put(:stream, {:payload_field, "private-group-buy-providers", "provider_id"})
  end

  defp spec(role, fields) do
    %{
      required_roles: [role],
      disclosure_class: :own_data,
      stream: {:payload_field, "private-group-buys", "seller_id"},
      payload: %{required: fields, optional: %{}}
    }
  end

  @doc "Hash all seller terms, policy and signature. Persisted offer terms are immutable."
  def terms_hash(%Envelope{type: @offer} = env),
    do:
      Canonical.hash(
        Envelope.full_record_term(%{
          env
          | stream_id: nil,
            stream_seq: nil,
            global_seq: nil,
            prev_stream_hash: nil,
            prev_global_hash: nil
        })
      )

  @doc "Build seller admission of already-signed upfront buyer consent; then seller signs."
  def acceptance(%Envelope{type: @consent} = consent, seller_signer) do
    with :ok <- Envelope.verify(consent),
         {:ok, bytes} <- Canonical.encode(Envelope.full_record_term(consent)) do
      Envelope.new(
        type: @accept,
        chapter_id: consent.chapter_id,
        timestamp_ms: System.system_time(:millisecond),
        signers: [seller_signer],
        payload: %{
          "seller_id" => consent.payload["seller_id"],
          "campaign_id" => consent.payload["campaign_id"],
          "consent" => {:bytes, bytes}
        }
      )
    end
  end

  @doc """
  Build an atomic funded contract proposal from signed buyer consent and raw
  canonical provider-report bytes. The seller must sign the returned envelope;
  submit/2 verifies both authorities and full held coverage before committing.
  """
  def funded_acceptance(consent, proof_bytes, expected_version, seller_signer)
      when is_binary(proof_bytes) and is_integer(expected_version) and expected_version >= 0 do
    with {:ok, admitted} <- acceptance(consent, seller_signer) do
      Envelope.new(
        type: @funded_accept,
        chapter_id: admitted.chapter_id,
        timestamp_ms: admitted.timestamp_ms,
        signers: admitted.signers,
        payload:
          Map.merge(admitted.payload, %{
            "proof" => {:bytes, proof_bytes},
            "expected_version" => expected_version
          })
      )
    end
  end

  @doc "Commit a signed authority event. A receipt asserts ledger admission only."
  def submit(%Envelope{} = env, server \\ Log.server()) do
    if env.type in [
         @seller,
         @member,
         @offer,
         @close,
         @accept,
         @escrow_provider,
         @escrow_evidence,
         @stock,
         @provider_authority,
         @provider_pin,
         @funded_accept
       ] do
      with {:ok, [accepted]} <- Log.append(env, server) do
        {:ok,
         %{
           event_id: accepted.event_id,
           global_seq: accepted.global_seq,
           payment: :not_collected,
           inventory: inventory_receipt(env),
           fulfillment: :not_authorized
         }}
      end
    else
      {:error, :not_a_group_buy_authority_event}
    end
  end

  defp inventory_receipt(%Envelope{
         type: @stock,
         payload: %{"command" => %{"op" => "reserve"}}
       }),
       do: :seller_home_stock_reserved_in_canonical_ledger

  defp inventory_receipt(%Envelope{type: @stock}),
    do: :seller_reported_stock_recorded_in_canonical_ledger

  defp inventory_receipt(_), do: :not_reserved

  @doc """
  Admit a signed single-recipient read, then return only an encrypted packet.
  Request signature binds the recipient's X25519 key, exact offer and expiry.
  A captured request cannot reveal plaintext. Public/gossip routing is never
  accepted. Call through a private authenticated host adapter.
  """
  def deliver(request, transport, server \\ Log.server())

  def deliver(%Envelope{type: @read} = request, :private, server) do
    with {:ok, [_]} <- Log.append(request, server) do
      gate = Log.gate(server)
      row = gate.group_buys.offers[key(request)]
      {:ok, bytes} = Canonical.encode(Envelope.full_record_term(row.envelope))
      {:bytes, recipient_key} = request.payload["encryption_key"]
      CoopSubstrate.GroupBuys.Cipher.seal(bytes, recipient_key, request)
    end
  end

  def deliver(_, _, _), do: {:error, :private_delivery_required}

  @doc false
  def live_check(%Envelope{type: type} = env, gate) do
    if Map.has_key?(event_types(), type) do
      now = System.system_time(:second)
      # The host signs admissions in the current seller-home second. This
      # makes the deterministic replay instant exactly the expiry/threshold
      # instant checked by the appender, rather than a buyer's old timestamp.
      if type in [
           @accept,
           @escrow_evidence,
           @stock,
           @funded_accept,
           @provider_pin,
           @provider_authority
         ] and div(env.timestamp_ms, 1000) != now,
         do: {:error, :stale_admission_time},
         else:
           with(
             :ok <- EscrowAdmission.live_grant(env, gate, now),
             do: check_at(env, gate, now)
           )
    else
      :ok
    end
  end

  def check(env, gate), do: check_at(env, gate, div(env.timestamp_ms, 1000))

  defp check_at(env, gate, now) do
    with :ok <- Envelope.verify(env),
         false <- Map.has_key?(gate.group_buys.events, env.event_id),
         {:ok, _} <- transition(env, gate, now) do
      :ok
    else
      true -> {:error, :group_buy_event_replay}
      {:error, _} = error -> error
    end
  end

  @doc false
  def fold!(env, gate) do
    with :ok <- check(env, gate),
         {:ok, next} <- transition(env, gate, div(env.timestamp_ms, 1000)) do
      put_in(next, [:events, env.event_id], env)
    else
      error -> raise "inconsistent group-buy history: #{inspect(error)}"
    end
  end

  @doc false
  def duplicate(envelopes, state) do
    results = Enum.map(envelopes, &duplicate_one(&1, state))

    cond do
      Enum.all?(results, &(&1 == :new)) -> :new
      error = Enum.find(results, &match?({:error, _}, &1)) -> error
      Enum.any?(results, &(&1 == :new)) -> {:error, :partial_group_buy_batch_replay}
      true -> {:ok, Enum.map(results, fn {:ok, accepted} -> accepted end)}
    end
  end

  defp duplicate_one(%Envelope{} = env, state) do
    case state.events[env.event_id] do
      nil ->
        EscrowAdmission.duplicate(env, state)

      accepted ->
        cond do
          env.type == @read ->
            {:error, :private_read_replayed}

          Envelope.signed_core_term(env) == Envelope.signed_core_term(accepted) and
              env.sigs == accepted.sigs ->
            {:ok, accepted}

          true ->
            {:error, :group_buy_event_id_conflict}
        end
    end
  end

  defp transition(%Envelope{type: @seller, chapter_id: ch, payload: p} = env, gate, now) do
    old = gate.group_buys.sellers[{ch, p["seller_id"]}]

    with :ok <- governance(env, gate),
         :ok <- revision(old, p["expected_version"]),
         :ok <- deadline(p["expires_at"], now),
         true <- id?(p["seller_id"]) and id?(p["key_id"]) do
      row = %{
        key_id: p["key_id"],
        pubkey: bytes(p["pubkey"]),
        expires_at: p["expires_at"],
        version: p["expected_version"] + 1,
        authorization_id: env.event_id
      }

      {:ok, put_in(gate.group_buys, [:sellers, Access.key({ch, p["seller_id"]})], row)}
    else
      false -> {:error, :invalid_seller_credential}
      error -> error
    end
  end

  defp transition(%Envelope{type: @member, chapter_id: ch, payload: p} = env, gate, now) do
    scope = {ch, p["seller_id"], p["buyer_id"]}
    old = gate.group_buys.members[scope]

    with {:ok, seller} <- seller(env, gate, now),
         :ok <- identity(gate, ch, p["buyer_id"], p["key_id"], bytes(p["pubkey"])),
         :ok <- revision(old, p["expected_version"]),
         :ok <- deadline(p["expires_at"], now),
         true <- id?(p["buyer_id"]) and id?(p["key_id"]) and p["buyer_id"] != p["seller_id"] do
      row = %{
        key_id: p["key_id"],
        pubkey: bytes(p["pubkey"]),
        expires_at: p["expires_at"],
        active: p["active"],
        version: p["expected_version"] + 1,
        seller_authorization: seller.authorization_id,
        authorization_id: env.event_id
      }

      {:ok, put_in(gate.group_buys, [:members, Access.key(scope)], row)}
    else
      false -> {:error, :invalid_member_credential}
      error -> error
    end
  end

  defp transition(%Envelope{type: @offer, payload: p} = env, gate, now) do
    with {:ok, seller} <- seller(env, gate, now),
         true <- gate.group_buys.offers[key(env)] == nil,
         true <- p["policy"] == @policy,
         {:ok, offer} <- offer(p["offer"]),
         true <- offer.id == p["campaign_id"] and offer.seller == p["seller_id"],
         {:ok, round} <- Round.new(offer, now),
         {:ok, escrow} <- Escrow.new(offer, now),
         {:ok, hash} <- terms_hash(env) do
      row = %{
        envelope: env,
        hash: hash,
        closed: false,
        seller_authorization: seller.authorization_id
      }

      {:ok,
       gate.group_buys
       |> put_in([:offers, Access.key(key(env))], row)
       |> put_in([:rounds, Access.key(key(env))], round)
       |> put_in([:escrow_states, Access.key(key(env))], escrow)}
    else
      false -> {:error, :immutable_or_mismatched_offer}
      error -> error
    end
  end

  defp transition(%Envelope{type: @close} = env, gate, now) do
    with {:ok, _} <- seller(env, gate, now),
         %{closed: false} = row <- gate.group_buys.offers[key(env)] do
      {:ok, put_in(gate.group_buys, [:offers, key(env)], %{row | closed: true})}
    else
      {:error, _} = error -> error
      _ -> {:error, :unknown_or_closed_offer}
    end
  end

  defp transition(%Envelope{type: @read, payload: p} = env, gate, now) do
    with {:ok, _} <- member(env, gate, now),
         {:ok, _} <- current_offer(env, gate, now, p["terms_hash"]),
         :ok <- deadline(p["valid_until"], now),
         :ok <- encryption_key(p["encryption_key"]) do
      {:ok, gate.group_buys}
    end
  end

  defp transition(%Envelope{type: @accept, payload: p} = env, gate, now) do
    with {:ok, _} <- seller(env, gate, now),
         {:ok, consent} <- consent(p["consent"]),
         true <- consent.chapter_id == env.chapter_id and key(consent) == key(env),
         false <- Map.has_key?(gate.group_buys.consents, consent.event_id),
         {:ok, credential} <- member(consent, gate, now),
         true <- consent.payload["policy"] == @policy,
         :ok <- deadline(consent.payload["valid_until"], now),
         {:ok, command} <- command(consent),
         :ok <- pledge_deadline(command, now),
         {:ok, _} <-
           current_offer(
             consent,
             gate,
             now,
             consent.payload["terms_hash"],
             command.op == :withdraw
           ),
         {:ok, round, :accepted} <-
           Round.apply(
             gate.group_buys.rounds[key(env)],
             consent.payload["buyer_id"],
             command,
             now
           ),
         credentials =
           pledge_credentials(
             gate.group_buys.pledge_credentials,
             env,
             consent,
             command,
             credential
           ),
         :ok <- activation_members(gate, env, round, credentials, now) do
      {:ok,
       gate.group_buys
       |> Map.put(:pledge_credentials, credentials)
       |> put_in([:rounds, key(env)], round)
       |> put_in([:consents, Access.key(consent.event_id)], env.event_id)}
    else
      true -> {:error, :consent_replay}
      false -> {:error, :consent_scope_or_policy_mismatch}
      {:ok, _, :duplicate} -> {:error, :consent_replay}
      {:error, _} = error -> error
    end
  end

  # ONE event contains the buyer consent and provider proof. No intermediate
  # binding state is visible if funding validation or coverage fails.
  defp transition(%Envelope{type: @funded_accept} = env, gate, now) do
    consent_env = %{env | type: @accept}

    with {:ok, contracts} <- transition(consent_env, gate, now),
         {:ok, funded} <- EscrowAdmission.admit(env, %{gate | group_buys: contracts}, now),
         :ok <- EscrowAdmission.complete_coverage(funded, key(env), now) do
      {:ok, funded}
    end
  end

  defp transition(%Envelope{type: @provider_authority} = env, gate, now) do
    with :ok <- governance(env, gate),
         do: EscrowAdmission.authorize(env, gate, now)
  end

  defp transition(%Envelope{type: @provider_pin} = env, gate, now),
    do: EscrowAdmission.pin_authorized(env, gate, now)

  defp transition(%Envelope{type: @escrow_provider} = env, gate, now),
    do: EscrowAdmission.pin(env, gate, now)

  defp transition(%Envelope{type: @escrow_evidence} = env, gate, now),
    do: EscrowAdmission.admit(env, gate, now)

  defp transition(%Envelope{type: @stock} = env, gate, now),
    do: Stock.apply_event(env, gate, now)

  defp transition(_, _, _), do: {:error, :consent_is_not_ledger_admission}

  # Recheck every still-conditional participant at the activating transition.
  # Later expiry/withdrawal of access cannot erase an already-bound purchase.
  defp pledge_credentials(credentials, env, consent, %{op: :pledge, pledge: pledge}, credential) do
    Map.put(
      credentials,
      {key(env), consent.payload["buyer_id"], pledge.id},
      credential.authorization_id
    )
  end

  defp pledge_credentials(credentials, _, _, _, _), do: credentials

  defp activation_members(gate, env, round, credentials, now) do
    previous = gate.group_buys.rounds[key(env)]

    if previous.activated == nil and round.activated != nil do
      eligible =
        Enum.all?(round.pledges, fn {buyer, pledge} ->
          member = gate.group_buys.members[{env.chapter_id, env.payload["seller_id"], buyer}]

          member != nil and member.active and member.expires_at > now and
            credentials[{key(env), buyer, pledge.id}] == member.authorization_id and
            identity(gate, env.chapter_id, buyer, member.key_id, member.pubkey) == :ok
        end)

      if eligible, do: :ok, else: {:error, :pending_member_ineligible}
    else
      :ok
    end
  end

  defp governance(env, gate) do
    case env.signers do
      [%{role: "governance", key_id: id, pubkey: pub}] ->
        if get_in(gate.role_keys, [{env.chapter_id, "governance"}, id]) == pub,
          do: :ok,
          else: {:error, :group_buy_governance_required}

      _ ->
        {:error, :group_buy_signer_cardinality}
    end
  end

  defp seller(env, gate, now) do
    credential = gate.group_buys.sellers[{env.chapter_id, env.payload["seller_id"]}]
    with :ok <- credential(credential, env.signers, "group_seller", now), do: {:ok, credential}
  end

  defp member(env, gate, now) do
    p = env.payload
    seller = gate.group_buys.sellers[{env.chapter_id, p["seller_id"]}]
    member = gate.group_buys.members[{env.chapter_id, p["seller_id"], p["buyer_id"]}]

    with true <- seller != nil and seller.expires_at > now,
         true <-
           member != nil and member.active and
             member.seller_authorization == seller.authorization_id,
         :ok <- credential(member, env.signers, "group_buyer", now),
         :ok <- identity(gate, env.chapter_id, p["buyer_id"], member.key_id, member.pubkey) do
      {:ok, member}
    else
      false -> {:error, :ineligible_group_buy_member}
      error -> error
    end
  end

  # The interested seller grants market eligibility, never buyer identity.
  # Identity keys come from MemberRegistered / old-key-authorized KeyRotated.
  defp identity(gate, chapter, buyer, key_id, pubkey) do
    case gate.members[{chapter, buyer}] do
      %{key_id: ^key_id, pubkey: ^pubkey} -> :ok
      _ -> {:error, :unverified_group_buy_identity}
    end
  end

  defp credential(
         %{key_id: id, pubkey: pub, expires_at: expires},
         [%{role: role, key_id: id, pubkey: pub}],
         role,
         now
       )
       when expires > now, do: :ok

  defp credential(_, _, _, _), do: {:error, :invalid_or_expired_group_buy_credential}

  defp current_offer(env, gate, now, {:bytes, hash}, withdrawing \\ false) do
    row = gate.group_buys.offers[key(env)]
    round = gate.group_buys.rounds[key(env)]
    seller = gate.group_buys.sellers[{env.chapter_id, env.payload["seller_id"]}]

    if row != nil and seller != nil and row.hash == hash and
         row.seller_authorization == seller.authorization_id and
         (withdrawing or (not row.closed and round.offer.expires_at > now)),
       do: {:ok, row},
       else: {:error, :stale_closed_or_expired_offer}
  end

  defp consent({:bytes, encoded}) do
    with {:ok, term} <- Canonical.decode(encoded),
         {:ok, %Envelope{type: @consent} = env} <- Envelope.from_full_record_term(term),
         false <- Envelope.appended?(env),
         :ok <- Envelope.verify(env) do
      {:ok, env}
    else
      _ -> {:error, :invalid_signed_consent}
    end
  end

  defp command(env) do
    p = env.payload
    c = p["command"]
    evidence = Base.encode16(Canonical.hash!(Envelope.signed_core_term(env)), case: :lower)

    case c do
      %{"op" => "pledge", "expected_version" => version, "pledge" => raw} when map_size(c) == 3 ->
        with {:ok, pledge} <- fields(raw, @pledge_keys) do
          {:ok,
           %{
             id: env.event_id,
             expected_version: version,
             op: :pledge,
             pledge: pledge,
             evidence_ref: evidence
           }}
        end

      %{"op" => "withdraw", "expected_version" => version, "pledge_id" => id}
      when map_size(c) == 3 ->
        {:ok,
         %{
           id: env.event_id,
           expected_version: version,
           op: :withdraw,
           buyer: p["buyer_id"],
           pledge_id: id,
           evidence_ref: evidence
         }}

      _ ->
        {:error, :invalid_signed_group_buy_command}
    end
  end

  defp pledge_deadline(%{op: :withdraw}, _), do: :ok

  defp pledge_deadline(%{op: :pledge, pledge: %{expires_at: expiry}}, now)
       when is_integer(expiry) and expiry > now, do: :ok

  defp pledge_deadline(_, _), do: {:error, :expired_pledge}

  defp offer(raw) do
    with {:ok, converted} <- fields(raw, @offer_keys),
         tiers when is_list(tiers) <- raw["tiers"] do
      Enum.reduce_while(tiers, {:ok, []}, fn t, {:ok, acc} ->
        case fields(t, [:min_quantity, :unit_minor]) do
          {:ok, tier} -> {:cont, {:ok, [tier | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, tiers} -> {:ok, %{converted | tiers: Enum.reverse(tiers)}}
        error -> error
      end
    else
      _ -> {:error, :invalid_signed_offer}
    end
  end

  defp fields(map, keys) when is_map(map) do
    if Enum.sort(Map.keys(map)) == Enum.sort(Enum.map(keys, &Atom.to_string/1)),
      do: {:ok, Map.new(keys, &{&1, map[Atom.to_string(&1)]})},
      else: {:error, :invalid_group_buy_fields}
  end

  defp fields(_, _), do: {:error, :invalid_group_buy_fields}

  defp encryption_key({:bytes, <<_::256>> = key}) do
    # Reject low-order X25519 points before the request can consume a nonce.
    try do
      {_, private} = :crypto.generate_key(:ecdh, :x25519)

      case :crypto.compute_key(:ecdh, key, private, :x25519) do
        <<0::256>> -> {:error, :invalid_encryption_key}
        _ -> :ok
      end
    rescue
      _ -> {:error, :invalid_encryption_key}
    end
  end

  defp revision(nil, 0), do: :ok
  defp revision(%{version: n}, n), do: :ok
  defp revision(_, _), do: {:error, :stale_credential_version}
  defp deadline(expiry, now) when is_integer(expiry) and expiry > now, do: :ok
  defp deadline(_, _), do: {:error, :expired_group_buy_authority}
  defp bytes({:bytes, value}), do: value
  defp id?(id), do: is_binary(id) and byte_size(id) in 1..2048 and String.trim(id) != ""
  defp key(env), do: {env.chapter_id, env.payload["seller_id"], env.payload["campaign_id"]}
end
