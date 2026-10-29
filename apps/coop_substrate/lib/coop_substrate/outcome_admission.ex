defmodule CoopSubstrate.OutcomeAdmission do
  @moduledoc """
  Source-bound recording of already committed TigerBeetle outcomes.

  The host supplies an immutable, authenticated complete-group snapshot and
  pinned verifier keys in the Log's startup options. This module does not
  authenticate native history or construct that snapshot. No production host
  wires this port yet; absent configuration refuses admission. Requests cannot
  supply a snapshot, destination alias or verification Boolean.

  Bindings, original receipts and complete-prefix cursors derive ONLY from
  accepted signed ledger events. The in-memory fold is a rebuildable index,
  protected by the ledger's expected-version append. No financial command,
  execution authorization or settlement transition exists here.
  """
  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Protocol.Envelope

  @outcome "TigerBeetleOutcomeRecordedV1"
  @cursor "TigerBeetleOutcomeCheckpointedV1"
  @role "tb-history-verifier"
  @group_fields ~w(home cluster generation ordinal anchor native_transfer_ids native_evidence outcome)

  def event_types do
    scope = %{
      "home" => :string,
      "destination" => :string,
      "cluster" => :bytes,
      "generation" => :bytes
    }

    Map.new(
      [
        {@outcome,
         Map.merge(scope, %{
           "ordinal" => :int,
           "anchor" => :bytes,
           "native_transfer_ids" => :any,
           "native_evidence" => :bytes,
           "outcome" => :bytes
         })},
        {@cursor,
         Map.merge(scope, %{
           "ordinal" => :int,
           "anchor" => :bytes,
           "outcome_event_hash" => :hash
         })}
      ],
      fn {type, required} ->
        {type,
         %{
           required_roles: [@role],
           disclosure_class: :own_data,
           stream: {:chapter_scoped, "tb-outcomes"},
           payload: %{required: required, optional: %{}}
         }}
      end
    )
  end

  def source_event?(%Envelope{type: type}), do: type in [@outcome, @cursor]
  def init, do: %{destination: nil, records: %{}, positions: %{}, cursors: %{}, checkpoints: %{}}

  @doc "Validate trusted startup configuration, never a request parameter."
  def validate_snapshot!(nil), do: nil

  def validate_snapshot!(%{destination: destination, origins: origins} = snapshot)
      when is_binary(destination) and byte_size(destination) > 0 and is_map(origins) do
    Enum.each(origins, fn {{home, cluster, generation}, %{keys: keys, groups: groups}} ->
      true = is_map(keys) and map_size(keys) > 0 and is_list(groups)
      true = Enum.all?(keys, fn {id, key} -> is_binary(id) and match?(<<_::256>>, key) end)

      Enum.with_index(groups, 1)
      |> Enum.each(fn {group, ordinal} ->
        true = Enum.sort(Map.keys(group)) == Enum.sort(@group_fields)
        true = origin(group) == {home, cluster, generation}
        true = group["ordinal"] == ordinal
        :ok = group_shape(group)
      end)

      anchors = Enum.map(groups, & &1["anchor"])
      true = length(Enum.uniq(anchors)) == length(anchors)
    end)

    snapshot
  end

  def validate_snapshot!(_), do: raise(ArgumentError, "invalid TigerBeetle source snapshot")

  def validate_recovered!(state, nil), do: state

  def validate_recovered!(state, %{destination: destination} = snapshot) do
    unless state.destination in [nil, destination],
      do: raise(ArgumentError, "destination differs from accepted TigerBeetle history")

    # The currently configured source must agree with EVERY accepted binding,
    # including its historical verifier key. Startup cannot rewrite the source
    # body behind an existing cursor or forget an admitted group.
    Enum.each(state.records, fn {_slot, env} ->
      unless authenticated_source(env, snapshot, init()) == :ok,
        do: raise(ArgumentError, "source snapshot differs from accepted TigerBeetle history")
    end)

    state
  end

  @doc "Runs inside the serialized appender, for append AND append_if."
  def admission(envelopes, state, snapshot) do
    if Enum.any?(envelopes, &source_event?/1) do
      case envelopes do
        [env] ->
          with :ok <- authenticated_source(env, snapshot, state),
               :ok <- destination(env, state),
               do: decision(env, state)

        _ ->
          {:error, :source_admission_requires_single_event}
      end
    else
      :new
    end
  end

  def cursor(state, scope), do: Map.get(state.cursors, scope, 0)

  @doc "Audit semantic consistency during recovery; never overwrite a binding."
  def fold!(%Envelope{} = env, state) do
    if source_event?(env) do
      with :ok <- destination(env, state),
           :new <- decision(env, state) do
        put_event(env, state)
      else
        error -> raise "invalid accepted TigerBeetle admission history: #{inspect(error)}"
      end
    else
      state
    end
  end

  # Source membership is exact byte equality, in a host-pinned snapshot. The
  # signer is checked against host-pinned keys, never TOFU or caller-supplied keys.
  defp authenticated_source(_, nil, _state), do: {:error, :source_admission_disabled}

  defp authenticated_source(%Envelope{payload: p, signers: [signer]} = env, snapshot, state) do
    with true <- p["destination"] == snapshot.destination,
         true <- env.chapter_id == p["home"],
         %{keys: keys, groups: groups} <- snapshot.origins[origin(p)],
         true <- signer.role == @role and keys[signer.key_id] == signer.pubkey,
         n when is_integer(n) and n > 0 <- p["ordinal"],
         group when is_map(group) <- Enum.at(groups, n - 1),
         true <- p["anchor"] == group["anchor"],
         # An occupied slot can only return its old receipt or a body conflict;
         # it can never take the fresh-append branch below.
         true <-
           env.type == @cursor or Map.drop(p, ["destination"]) == group or
             Map.has_key?(state.records, slot(p)) do
      :ok
    else
      _ -> {:error, :unverified_source_outcome}
    end
  end

  # Generic envelopes allow several keys for one required role. This source
  # protocol requires one pinned verifier; other signer shapes are input
  # refusals, not a reason to terminate the canonical appender.
  defp authenticated_source(_env, _snapshot, _state),
    do: {:error, :unverified_source_outcome}

  defp destination(%Envelope{chapter_id: home, payload: p}, state) do
    if home == p["home"] and is_binary(p["destination"]) and p["destination"] != "" and
         state.destination in [nil, p["destination"]],
       do: :ok,
       else: {:error, :source_destination_mismatch}
  end

  defp decision(%Envelope{type: @outcome, payload: p}, state) do
    with :ok <- group_shape(p) do
      case state.records[slot(p)] do
        %Envelope{payload: ^p} = original ->
          {:ok, [original]}

        %Envelope{} ->
          {:error, :source_body_conflict}

        nil ->
          if Map.has_key?(state.positions, {scope(p), p["ordinal"]}),
            do: {:error, :source_ordinal_conflict},
            else: :new
      end
    end
  end

  defp decision(%Envelope{type: @cursor, payload: p}, state) do
    key = {scope(p), p["ordinal"]}

    case state.checkpoints[key] do
      %Envelope{payload: ^p} = original ->
        {:ok, [original]}

      %Envelope{} ->
        {:error, :source_checkpoint_conflict}

      nil ->
        with true <- p["ordinal"] == cursor(state, scope(p)) + 1,
             %Envelope{payload: accepted} = receipt <- state.records[slot(p)],
             true <- accepted["ordinal"] == p["ordinal"],
             {:ok, hash} <- Envelope.event_hash(receipt),
             true <- p["outcome_event_hash"] == {:bytes, hash} do
          :new
        else
          _ -> {:error, :source_prefix_not_durable}
        end
    end
  end

  defp put_event(%Envelope{type: @outcome, payload: p} = env, state) do
    %{
      state
      | destination: p["destination"],
        records: Map.put(state.records, slot(p), env),
        positions: Map.put(state.positions, {scope(p), p["ordinal"]}, slot(p))
    }
  end

  defp put_event(%Envelope{type: @cursor, payload: p} = env, state) do
    %{
      state
      | cursors: Map.put(state.cursors, scope(p), p["ordinal"]),
        checkpoints: Map.put(state.checkpoints, {scope(p), p["ordinal"]}, env)
    }
  end

  defp group_shape(p) do
    with true <- is_binary(p["home"]) and p["home"] != "",
         true <- match?({:bytes, <<_::128>>}, p["cluster"]),
         true <- match?({:bytes, <<_::64>>}, p["generation"]),
         n when is_integer(n) and n > 0 <- p["ordinal"],
         [anchor | _] = ids <- p["native_transfer_ids"],
         true <- p["anchor"] == anchor,
         true <- Enum.all?(ids, &match?({:bytes, <<id::128>>} when id > 0, &1)),
         true <- length(Enum.uniq(ids)) == length(ids),
         :ok <- canonical_bytes(p["native_evidence"]),
         :ok <- canonical_bytes(p["outcome"]) do
      :ok
    else
      _ -> {:error, :invalid_source_group}
    end
  end

  defp canonical_bytes({:bytes, bytes}) when is_binary(bytes) do
    with {:ok, term} <- Canonical.decode(bytes), {:ok, ^bytes} <- Canonical.encode(term), do: :ok
  end

  defp canonical_bytes(_), do: {:error, :invalid_source_bytes}

  defp origin(p), do: {p["home"], p["cluster"], p["generation"]}
  def scope(p), do: {p["home"], p["destination"], p["cluster"], p["generation"]}

  defp slot(p), do: {scope(p), p["anchor"]}
end
