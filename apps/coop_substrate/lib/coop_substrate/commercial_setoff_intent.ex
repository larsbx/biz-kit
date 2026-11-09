defmodule CoopSubstrate.CommercialSetoffIntent do
  @moduledoc """
  An inert, exact-source, double-signed COMMERCIAL PROPOSAL event.

  The existing canonical CoopSubstrate.Log is the only business event writer.
  A successful admission records a reviewed proposal; it does not discharge
  debts, reserve claims, create spendable credits or instruct financial rails.

  The append-time gate binds the *complete currently open* pair obligation
  identities, amounts and currency to the signed event. It protects proposals
  from same-total source substitution. It does NOT authenticate underlying
  invoices, company agency, legal effect, sanctions or source-event revisions.
  Current member keys are not equivalent to corporate agency grants.
  """

  alias CoopSubstrate.Canonical
  alias CoopSubstrate.Protocol.Envelope

  @intent_type "CommercialSetoffIntentRecordedV1"
  @source_keys ~w(amount_minor creditor_id debtor_id denomination obligation_id)
  @payload_keys ~w(a_to_b b_to_a denomination intent_id party_a party_b
                   setoff source_terms_digest sources)
  @max_sources 256
  @max_minor 9_223_372_036_854_775_807

  @doc "The admitted event is only a signed, inert accounting proposal."
  def event_type, do: @intent_type

  @doc """
  Called by Validity inside the existing serialized business append gate.
  A source list is bound to canonical currently open obligations, not just
  aggregate totals. Any changed source set or current signing key is refused.
  """
  def check(%Envelope{type: @intent_type, chapter_id: chapter, payload: payload} = env, gate)
      when is_map(payload) and is_map(gate) do
    with :ok <- validate_header(payload),
         :ok <- unique_intent(gate, chapter, payload["intent_id"]),
         :ok <- current_roles(env, gate, chapter, payload),
         {:ok, sources, a_to_b, b_to_a} <- exact_current_sources(gate, chapter, payload),
         :ok <- validate_figures(payload, a_to_b, b_to_a),
         :ok <- validate_digest(payload["source_terms_digest"], sources) do
      :ok
    end
  end

  def check(_, _), do: {:error, :invalid_commercial_setoff_intent}

  @doc """
  Fold after authorized Log admission. Do not change any obligation,
  reservation, payable, financial balance or custody state.
  """
  def fold(%Envelope{type: @intent_type, chapter_id: chapter, payload: p}, state) do
    record = %{
      party_a: p["party_a"],
      party_b: p["party_b"],
      denomination: p["denomination"],
      sources: p["sources"],
      source_terms_digest: p["source_terms_digest"],
      a_to_b: p["a_to_b"],
      b_to_a: p["b_to_a"],
      setoff: p["setoff"],
      status: :signed_proposal_not_discharge,
      settlement: :none
    }

    update_in(state, [:commercial_setoff_intents], fn existing ->
      Map.put(existing, {chapter, p["intent_id"]}, record)
    end)
  end

  defp validate_header(p) do
    a = p["party_a"]
    b = p["party_b"]
    denomination = p["denomination"]
    id = p["intent_id"]

    if Enum.sort(Map.keys(p)) == Enum.sort(@payload_keys) and
         Enum.all?([a, b, denomination, id], &(is_binary(&1) and &1 != "")) and
         a < b and byte_size(id) <= 256 and byte_size(denomination) == 3 and
         String.match?(denomination, ~r/\A[A-Z]{3}\z/) do
      :ok
    else
      {:error, :invalid_commercial_setoff_header}
    end
  end

  defp unique_intent(%{commercial_setoff_intents: intents}, chapter, id) do
    if Map.has_key?(intents, {chapter, id}),
      do: {:error, :commercial_setoff_intent_replayed},
      else: :ok
  end

  defp unique_intent(_, _, _), do: {:error, :missing_commercial_setoff_gate}

  defp current_roles(%Envelope{signers: signers}, gate, chapter, p) do
    Enum.reduce_while([{"party_a", p["party_a"]}, {"party_b", p["party_b"]}], :ok,
      fn {role, actor}, _ ->
        case Map.get(gate.members, {chapter, actor}) do
          %{key_id: key_id, pubkey: pubkey} ->
            if Enum.any?(signers, fn signer ->
                 signer.role == role and signer.key_id == key_id and
                   signer.pubkey == pubkey
               end) do
              {:cont, :ok}
            else
              {:halt, {:error, {:stale_commercial_setoff_signer, role}}}
            end

          _ ->
            {:halt, {:error, {:unknown_commercial_setoff_actor, actor}}}
        end
      end)
  end

  defp exact_current_sources(%{obligations: obligations}, chapter, p) do
    a = p["party_a"]
    b = p["party_b"]
    denomination = p["denomination"]

    rows =
      for {{^chapter, id}, %{open: true, denomination: ^denomination} = ob} <- obligations,
          {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}] do
        %{
          "obligation_id" => id,
          "debtor_id" => ob.debtor_id,
          "creditor_id" => ob.creditor_id,
          "amount_minor" => ob.amount_minor,
          "denomination" => ob.denomination
        }
      end
      |> Enum.sort_by(& &1["obligation_id"])

    supplied = p["sources"]

    cond do
      not is_list(supplied) or length(supplied) < 2 or length(supplied) > @max_sources ->
        {:error, :invalid_commercial_setoff_sources}

      not Enum.all?(supplied, &source_shape?/1) ->
        {:error, :invalid_commercial_setoff_sources}

      supplied != rows ->
        {:error, :commercial_setoff_source_mismatch}

      true ->
        a_to_b =
          rows
          |> Enum.filter(&(&1["debtor_id"] == a))
          |> Enum.map(& &1["amount_minor"])
          |> Enum.sum()

        b_to_a =
          rows
          |> Enum.filter(&(&1["debtor_id"] == b))
          |> Enum.map(& &1["amount_minor"])
          |> Enum.sum()

        if a_to_b <= 0 or b_to_a <= 0 or a_to_b > @max_minor or
             b_to_a > @max_minor do
          {:error, :commercial_setoff_amount_out_of_range}
        else
          {:ok, rows, a_to_b, b_to_a}
        end
    end
  end

  defp exact_current_sources(_, _, _), do: {:error, :invalid_commercial_setoff_gate}

  defp source_shape?(%{} = source) do
    Enum.sort(Map.keys(source)) == @source_keys and
      is_binary(source["obligation_id"]) and source["obligation_id"] != "" and
      is_binary(source["debtor_id"]) and is_binary(source["creditor_id"]) and
      is_binary(source["denomination"]) and
      is_integer(source["amount_minor"]) and source["amount_minor"] > 0 and
      source["amount_minor"] <= @max_minor
  end

  defp source_shape?(_), do: false

  defp validate_figures(p, a_to_b, b_to_a) do
    if p["a_to_b"] == a_to_b and p["b_to_a"] == b_to_a and
         p["setoff"] == min(a_to_b, b_to_a) do
      :ok
    else
      {:error, :commercial_setoff_figure_mismatch}
    end
  end

  defp validate_digest({:bytes, supplied}, sources)
       when is_binary(supplied) and byte_size(supplied) == 32 do
    case Canonical.hash(sources) do
      {:ok, ^supplied} -> :ok
      {:ok, _} -> {:error, :commercial_setoff_digest_mismatch}
      {:error, reason} -> {:error, {:commercial_setoff_encoding_failed, reason}}
    end
  end

  defp validate_digest(_, _), do: {:error, :invalid_commercial_setoff_digest}
end
