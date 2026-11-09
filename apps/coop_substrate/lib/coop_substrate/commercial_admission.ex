defmodule CoopSubstrate.CommercialAdmission do
  @moduledoc """
  Versioned, inert commercial proposal admission in the existing business log.

  A governance-signed chapter profile permanently fences new legacy netting,
  assignment, discharge and V1 proposal commands. V2 binds complete current
  original source records and reserves their identities for one proposal.
  Reservations have no release transition in this deliberately narrow slice.

  All state is a read fold of the canonical ledger, never another writer.
  Current participant keys and declared governance authorize only this inert
  admission. They do not establish corporate agency, contractual discharge,
  accounting recognition, regulatory compliance or financial settlement.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Protocol.Envelope

  @activate "CommercialAdmissionProfileActivatedV1"
  @reserve "CommercialSetoffIntentReservedV2"
  @profile "source_bound_proposal_v2"
  @version 2
  @legacy ~w(NettingExecuted ObligationAssigned ObligationDischarged CommercialSetoffIntentRecordedV1)
  @sources ~w(ObligationRecorded ObligationAssigned ObligationDischarged NettingExecuted)
  @max_minor 9_223_372_036_854_775_807
  @max_sources 256

  def profile, do: @profile
  def activation_type, do: @activate
  def reservation_type, do: @reserve

  def init do
    %{
      profiles: %{},
      sources: %{},
      member_revisions: %{},
      governance: %{},
      reservations: %{},
      intents: %{},
      events: %{}
    }
  end

  def event_types do
    %{
      @activate => %{
        required_roles: ["governance"],
        disclosure_class: :commons,
        stream: {:chapter_scoped, "commercial-admission-profile"},
        payload: %{
          required: %{
            "profile" => :string,
            "version" => :int,
            "governance_event_id" => :string,
            "governance_event_hash" => :hash
          },
          optional: %{}
        }
      },
      @reserve => %{
        required_roles: ["party_a", "party_b", "governance"],
        disclosure_class: :bilateral,
        stream: {:payload_field, "commercial-reserved-intents", "intent_id"},
        payload: %{
          required: %{
            "profile" => :string,
            "version" => :int,
            "profile_event_id" => :string,
            "profile_event_hash" => :hash,
            "intent_id" => :string,
            "party_a" => :string,
            "party_b" => :string,
            "party_a_key_revision" => :int,
            "party_b_key_revision" => :int,
            "governance_event_id" => :string,
            "governance_event_hash" => :hash,
            "denomination" => :string,
            "sources" => :any,
            "source_terms_digest" => :hash,
            "a_to_b" => :int,
            "b_to_a" => :int,
            "setoff" => :int
          },
          optional: %{}
        }
      }
    }
  end

  @doc "New-admission fence only. Never invoke this to reinterpret old history."
  def fence(%Envelope{type: type, chapter_id: chapter}, gate)
      when type in @legacy or type in @sources do
    case gate do
      %{commercial_admission: %{profiles: profiles}} when is_map(profiles) ->
        case Map.fetch(profiles, chapter) do
          :error ->
            :ok

          {:ok, %{profile: @profile, version: @version}} ->
            if type in @legacy,
              do: {:error, {:legacy_commercial_event_disabled, type}},
              else: :ok

          _ ->
            {:error, :unsupported_commercial_profile}
        end

      _ ->
        {:error, :missing_commercial_admission_gate}
    end
  end

  def fence(_, _), do: :ok

  def check(%Envelope{type: @activate, chapter_id: ch, payload: p} = env, gate) do
    with {:ok, state} <- state(gate),
         :ok <- signer_shape(env, ["governance"]),
         :ok <- require_profile(p),
         false <- Map.has_key?(state.profiles, ch),
         {:ok, authority} <- current_governance(env, gate, state),
         :ok <- bind_authority(authority, p) do
      :ok
    else
      true -> {:error, :commercial_profile_already_activated}
      {:error, _} = error -> error
    end
  end

  def check(%Envelope{type: @reserve, chapter_id: ch, payload: p} = env, gate) do
    with {:ok, state} <- state(gate),
         :ok <- signer_shape(env, ["governance", "party_a", "party_b"]),
         :ok <- require_profile(p),
         :ok <- active_profile(state, ch, p),
         :ok <- header(p),
         :ok <- fresh_intent(state, ch, p["intent_id"]),
         :ok <- current_parties(env, gate, state),
         {:ok, authority} <- current_governance(env, gate, state),
         :ok <- bind_authority(authority, p),
         {:ok, rows} <- source_rows(gate, state, ch, p),
         :ok <- exact_sources(rows, p),
         :ok <- unreserved(state, ch, rows) do
      :ok
    end
  end

  def check(_, _), do: {:error, :invalid_commercial_admission}

  @doc """
  Read-only signing payload from a gate snapshot. A successful preparation is
  not admission: the serialized Log checks all bindings again at append.
  """
  def prepare(gate, chapter, intent_id, {a, b}, denomination, governance_key_id) do
    with {:ok, state} <- state(gate),
         %{profile: @profile, version: @version} = profile <- state.profiles[chapter],
         %{active: true, event_hash: hash} = authority when is_binary(hash) <-
           state.governance[{chapter, governance_key_id}],
         true <-
           get_in(gate.role_keys, [{chapter, "governance"}, governance_key_id]) ==
             authority.pubkey,
         p <- %{
           "party_a" => a,
           "party_b" => b,
           "denomination" => denomination,
           "intent_id" => intent_id
         },
         :ok <- header(p),
         {:ok, rows} <- source_rows(gate, state, chapter, p),
         {:ok, digest} <- Canonical.hash(rows) do
      {a_to_b, b_to_a} = totals(rows, a)

      prepared =
        Map.merge(p, %{
          "profile" => @profile,
          "version" => @version,
          "profile_event_id" => profile.event_id,
          "profile_event_hash" => {:bytes, profile.event_hash},
          "party_a_key_revision" => state.member_revisions[{chapter, a}],
          "party_b_key_revision" => state.member_revisions[{chapter, b}],
          "governance_event_id" => authority.event_id,
          "governance_event_hash" => {:bytes, authority.event_hash},
          "sources" => rows,
          "source_terms_digest" => {:bytes, digest},
          "a_to_b" => a_to_b,
          "b_to_a" => b_to_a,
          "setoff" => min(a_to_b, b_to_a)
        })

      with :ok <- exact_sources(rows, prepared),
           :ok <- fresh_intent(state, chapter, intent_id),
           :ok <- unreserved(state, chapter, rows),
           do: {:ok, prepared}
    else
      {:error, _} = error -> error
      _ -> {:error, :commercial_preparation_unavailable}
    end
  end

  @doc "Exact V2 retries return the historical receipt, never new authority."
  def duplicate([%Envelope{type: @reserve} = env], %{commercial_admission: state}) do
    case Map.get(state.events, {env.chapter_id, env.event_id}) do
      nil ->
        :new

      prior ->
        if Envelope.signed_core_term(prior) == Envelope.signed_core_term(env) and
             prior.sigs == env.sigs,
           do: {:ok, [prior]},
           else: {:error, :commercial_event_id_reused}
    end
  end

  def duplicate(_, _), do: :new

  @doc """
  Fold assigned events only for full-record provenance. Legacy projections
  keep their historical semantics. Before/after are the same authoritative
  gate around its ordinary Membership/Procurement fold, not separate ledgers.
  """
  def fold(%Envelope{} = env, before, next) do
    state = Map.fetch!(before, :commercial_admission)
    Map.put(next, :commercial_admission, fold_state(env, before, state))
  end

  defp fold_state(%Envelope{type: @activate, chapter_id: ch, payload: p} = env, _, state) do
    put_in(state, [:profiles, Access.key(ch)], %{
      profile: p["profile"],
      version: p["version"],
      event_id: env.event_id,
      event_hash: record_hash(env)
    })
  end

  defp fold_state(%Envelope{type: @reserve, chapter_id: ch, payload: p} = env, _, state) do
    intent = {ch, p["intent_id"]}

    reservations =
      Enum.reduce(p["sources"], state.reservations, fn row, acc ->
        Map.put(acc, {ch, row["obligation_id"]}, intent)
      end)

    state
    |> Map.put(:reservations, reservations)
    |> put_in([:intents, Access.key(intent)], %{
      event: env,
      status: :reserved_proposal_not_discharge,
      contractual_authority: :unverified,
      accounting_recognition: :none,
      discharge: :none,
      settlement: :none
    })
    |> put_in([:events, Access.key({ch, env.event_id})], env)
  end

  defp fold_state(
         %Envelope{type: "ObligationRecorded", chapter_id: ch, payload: p} = env,
         _,
         state
       ) do
    put_in(state, [:sources, Access.key({ch, p["obligation_id"]})], provenance(env, true))
  end

  defp fold_state(%Envelope{type: type, chapter_id: ch, payload: p} = env, _, state)
       when type in ~w(ObligationAssigned ObligationDischarged) do
    revise(state, {ch, p["obligation_id"]}, env)
  end

  defp fold_state(
         %Envelope{type: "NettingExecuted", chapter_id: ch, payload: p} = env,
         before,
         state
       ) do
    {a, b, denomination} = {p["party_a"], p["party_b"], p["denomination"]}

    revised =
      Enum.reduce(before.obligations, state, fn
        {{^ch, id}, %{open: true, denomination: ^denomination} = ob}, acc ->
          if {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}],
            do: revise(acc, {ch, id}, env),
            else: acc

        _, acc ->
          acc
      end)

    case p["residual_obligation_id"] do
      nil -> revised
      id -> put_in(revised, [:sources, Access.key({ch, id})], provenance(env, false))
    end
  end

  defp fold_state(%Envelope{type: type, chapter_id: ch, payload: p}, before, state)
       when type in ~w(MemberRegistered KeyRotated KeyRecoveryRotated) do
    key = {ch, p["member_id"]}

    if type == "MemberRegistered" or Map.has_key?(before.members, key) do
      update_in(state, [:member_revisions], &Map.update(&1, key, 0, fn n -> n + 1 end))
    else
      state
    end
  end

  defp fold_state(
         %Envelope{
           type: "RoleKeyDeclared",
           chapter_id: ch,
           payload: %{"role" => "governance"} = p
         } = env,
         _,
         state
       ) do
    {:bytes, pubkey} = p["pubkey"]

    put_in(state, [:governance, Access.key({ch, p["key_id"]})], %{
      active: true,
      pubkey: pubkey,
      event_id: env.event_id,
      event_hash: record_hash(env)
    })
  end

  defp fold_state(
         %Envelope{
           type: "RoleKeyRevoked",
           chapter_id: ch,
           payload: %{"role" => "governance"} = p
         },
         _,
         state
       ) do
    update_in(state, [:governance], fn authorities ->
      case Map.fetch(authorities, {ch, p["key_id"]}) do
        {:ok, row} -> Map.put(authorities, {ch, p["key_id"]}, %{row | active: false})
        :error -> authorities
      end
    end)
  end

  defp fold_state(_, _, state), do: state

  defp provenance(env, original_only) do
    hash = record_hash(env)

    %{
      original_event_id: env.event_id,
      original_event_hash: hash,
      revision: 0,
      latest_event_id: env.event_id,
      latest_event_hash: hash,
      original_only: original_only and is_binary(hash)
    }
  end

  defp revise(state, key, env) do
    update_in(state, [:sources], fn rows ->
      case Map.fetch(rows, key) do
        {:ok, row} ->
          Map.put(rows, key, %{
            row
            | revision: row.revision + 1,
              latest_event_id: env.event_id,
              latest_event_hash: record_hash(env),
              original_only: false
          })

        :error ->
          rows
      end
    end)
  end

  # Unassigned preview folds cannot fabricate full-record provenance. The Log
  # tentatively assigns the whole batch before validity and still commits only
  # after every check passes and the store's expected-version CAS succeeds.
  defp record_hash(%Envelope{global_seq: n} = env) when is_integer(n) and n > 0 do
    {:ok, hash} = Envelope.event_hash(env)
    hash
  end

  defp record_hash(_), do: nil

  defp state(%{commercial_admission: state}) when is_map(state), do: {:ok, state}
  defp state(_), do: {:error, :missing_commercial_admission_gate}

  # The historic envelope validator accepts repeated signer roles. This new
  # profile requires one independently keyed signature for each declared role.
  defp signer_shape(%Envelope{signers: signers}, roles) do
    if Enum.sort(Enum.map(signers, & &1.role)) == roles and
         length(Enum.uniq(Enum.map(signers, & &1.pubkey))) == length(roles),
       do: :ok,
       else: {:error, :invalid_commercial_signer_set}
  end

  defp require_profile(%{"profile" => @profile, "version" => @version}), do: :ok
  defp require_profile(_), do: {:error, :unsupported_commercial_profile}

  defp active_profile(state, ch, p) do
    case state.profiles[ch] do
      %{profile: @profile, version: @version, event_id: id, event_hash: hash}
      when is_binary(hash) ->
        if p["profile_event_id"] == id and p["profile_event_hash"] == {:bytes, hash},
          do: :ok,
          else: {:error, :commercial_profile_binding_mismatch}

      _ ->
        {:error, :commercial_profile_not_active}
    end
  end

  defp header(p) do
    a = p["party_a"]
    b = p["party_b"]
    id = p["intent_id"]
    currency = p["denomination"]

    if Enum.all?([a, b, id, currency], &(is_binary(&1) and &1 != "")) and a < b and
         String.match?(id, ~r/\A[A-Za-z0-9_-]{1,128}\z/) and
         String.match?(currency, ~r/\A[A-Z]{3}\z/),
       do: :ok,
       else: {:error, :invalid_commercial_admission_header}
  end

  defp fresh_intent(state, ch, id) do
    if Map.has_key?(state.intents, {ch, id}), do: {:error, :commercial_intent_replayed}, else: :ok
  end

  defp current_parties(%Envelope{chapter_id: ch, payload: p, signers: signers}, gate, state) do
    Enum.reduce_while(["party_a", "party_b"], :ok, fn role, _ ->
      actor = p[role]
      member = gate.members[{ch, actor}]
      signer = Enum.find(signers, &(&1.role == role))
      revision = state.member_revisions[{ch, actor}]

      if member != nil and signer != nil and is_integer(revision) and
           signer.key_id == member.key_id and signer.pubkey == member.pubkey and
           p[role <> "_key_revision"] == revision,
         do: {:cont, :ok},
         else: {:halt, {:error, {:stale_commercial_party_authority, role}}}
    end)
  end

  defp current_governance(%Envelope{chapter_id: ch, signers: signers}, gate, state) do
    with %{key_id: id, pubkey: pubkey} <- Enum.find(signers, &(&1.role == "governance")),
         ^pubkey <- get_in(gate.role_keys, [{ch, "governance"}, id]),
         %{active: true, pubkey: ^pubkey, event_hash: hash} = authority when is_binary(hash) <-
           state.governance[{ch, id}] do
      {:ok, authority}
    else
      _ -> {:error, :current_commercial_governance_required}
    end
  end

  defp bind_authority(authority, p) do
    if p["governance_event_id"] == authority.event_id and
         p["governance_event_hash"] == {:bytes, authority.event_hash},
       do: :ok,
       else: {:error, :stale_commercial_governance_epoch}
  end

  defp source_rows(gate, state, chapter, p) do
    a = p["party_a"]
    b = p["party_b"]
    currency = p["denomination"]

    selected =
      for {{^chapter, id}, %{open: true, denomination: ^currency} = ob} <- gate.obligations,
          {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}],
          do: {id, ob}

    selected
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, []}, fn {id, ob}, {:ok, rows} ->
      case state.sources[{chapter, id}] do
        %{
          original_only: true,
          revision: 0,
          original_event_hash: origin,
          latest_event_hash: latest
        } = source
        when is_binary(origin) and is_binary(latest) ->
          row = %{
            "obligation_id" => id,
            "debtor_id" => ob.debtor_id,
            "creditor_id" => ob.creditor_id,
            "amount_minor" => ob.amount_minor,
            "denomination" => ob.denomination,
            "original_event_id" => source.original_event_id,
            "original_event_hash" => {:bytes, origin},
            "source_revision" => source.revision,
            "latest_event_id" => source.latest_event_id,
            "latest_event_hash" => {:bytes, latest}
          }

          {:cont, {:ok, [row | rows]}}

        _ ->
          {:halt, {:error, :unsupported_commercial_source_lineage}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp exact_sources(rows, p) do
    {a_to_b, b_to_a} = totals(rows, p["party_a"])

    cond do
      length(rows) < 2 or length(rows) > @max_sources ->
        {:error, :invalid_commercial_source_count}

      p["sources"] != rows ->
        {:error, :commercial_source_binding_mismatch}

      a_to_b <= 0 or b_to_a <= 0 or a_to_b > @max_minor or b_to_a > @max_minor ->
        {:error, :commercial_amount_out_of_range}

      {p["a_to_b"], p["b_to_a"], p["setoff"]} != {a_to_b, b_to_a, min(a_to_b, b_to_a)} ->
        {:error, :commercial_figure_mismatch}

      p["source_terms_digest"] != {:bytes, Canonical.hash!(rows)} ->
        {:error, :commercial_source_digest_mismatch}

      true ->
        :ok
    end
  end

  defp totals(rows, a) do
    Enum.reduce(rows, {0, 0}, fn row, {ab, ba} ->
      if row["debtor_id"] == a,
        do: {ab + row["amount_minor"], ba},
        else: {ab, ba + row["amount_minor"]}
    end)
  end

  defp unreserved(state, ch, rows) do
    if Enum.any?(rows, &Map.has_key?(state.reservations, {ch, &1["obligation_id"]})),
      do: {:error, :commercial_source_already_reserved},
      else: :ok
  end
end
