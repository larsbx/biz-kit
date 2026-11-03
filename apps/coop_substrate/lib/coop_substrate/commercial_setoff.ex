defmodule CoopSubstrate.CommercialSetoff do
  @moduledoc """
  Read-only bridge from the canonical signed business obligation rail to an
  **unsigned** bilateral NettingExecuted proposal.

  NettingExecuted and its dual-signature/current-key/atomic append gate
  already exist in CoopSubstrate. This module neither creates a second
  ledger nor posts a money transfer. It only offers a canonical envelope for
  the two currently registered member keys to review and sign independently.

  IMPORTANT: The underlying ObligationRecorded event is an attested claim,
  not verified proof of a trade. NettingExecuted cannot encode a source-ID
  digest, legal setoff agreement, sanctions clearance or jurisdictional
  decision. Do not solicit signatures or submit the returned envelope before
  those checks have been established outside this helper. This is not a
  production commercial settlement workflow.
  """

  alias CoopSubstrate.Finance
  alias CoopSubstrate.Log
  alias CoopSubstrate.Protocol.Envelope

  @doc """
  Assemble an unsigned, fully calculated, member-key-bound bilateral netting
  envelope from the *current serialized Log gate*.

  Requires a caller-selected fresh residual obligation ID when the net is
  nonzero. Returns the exact source obligation IDs only for human review:
  they are NOT part of the existing NettingExecuted signed payload.

  This function never appends, signs or performs a financial operation.
  """
  def prepare(chapter, {a, b}, denomination, residual_id, timestamp_ms, server \\ Log.server())

  def prepare(chapter, {a, b}, denomination, residual_id, timestamp_ms, server)
      when is_binary(chapter) and byte_size(chapter) > 0 and
             is_binary(a) and is_binary(b) and is_binary(denomination) and
             is_integer(timestamp_ms) and timestamp_ms > 0 do
    if a >= b or a == "" or b == "" or denomination == "" do
      {:error, :invalid_pair_or_denomination}
    else
      gate = Log.gate(server)
      build(gate, chapter, {a, b}, denomination, residual_id, timestamp_ms)
    end
  end

  def prepare(_, _, _, _, _, _), do: {:error, :invalid_request}

  @doc """
  Testable deterministic preparation against a source-owned gate snapshot.
  The host MUST obtain this snapshot from its canonical Log; never trust a
  federation projection or user-controlled map for operational use.
  """
  def from_gate(gate, chapter, {a, b}, denomination, residual_id, timestamp_ms)
      when is_map(gate) and is_binary(chapter) and is_binary(a) and is_binary(b) and
             is_binary(denomination) and is_integer(timestamp_ms) and timestamp_ms > 0 do
    if chapter == "" or a >= b or a == "" or b == "" or denomination == "" do
      {:error, :invalid_pair_or_denomination}
    else
      build(gate, chapter, {a, b}, denomination, residual_id, timestamp_ms)
    end
  end

  def from_gate(_, _, _, _, _, _), do: {:error, :invalid_request}

  defp build(%{members: members, obligations: obligations}, chapter, {a, b}, denomination, residual_id, at) do
    report =
      obligations
      |> Finance.compute(chapter, {a, b})
      |> Enum.find(&(&1.denomination == denomination))

    with {:ok, actor_a} <- current_signer(members, chapter, a, "party_a"),
         {:ok, actor_b} <- current_signer(members, chapter, b, "party_b"),
         {:ok, report} <- eligible_report(report),
         {:ok, residual} <- residual_payload(obligations, chapter, report.net, residual_id),
         {:ok, envelope} <-
           Envelope.new(
             type: "NettingExecuted",
             chapter_id: chapter,
             timestamp_ms: at,
             signers: [actor_a, actor_b],
             payload:
               Map.merge(
                 %{
                   "party_a" => a,
                   "party_b" => b,
                   "denomination" => denomination,
                   "a_to_b" => report.a_to_b,
                   "b_to_a" => report.b_to_a,
                   "setoff" => report.setoff
                 },
                 residual
               )
           ) do
      source_ids =
        obligations
        |> Enum.filter(fn
          {{^chapter, _id}, %{open: true, denomination: ^denomination} = ob} ->
            {ob.debtor_id, ob.creditor_id} in [{a, b}, {b, a}]

          _ ->
            false
        end)
        |> Enum.map(fn {{_chapter, id}, _ob} -> id end)
        |> Enum.sort()

      {:ok,
       %{
         envelope: envelope,
         source_obligation_ids: source_ids,
         status: :unsigned_not_legally_cleared,
         source_binding: :not_signed_by_existing_event_schema,
         legal_evidence: :not_verified,
         financial_settlement: :none,
         action: :independent_dual_signature_and_admission_required
       }}
    end
  end

  defp build(_, _, _, _, _, _), do: {:error, :invalid_gate_snapshot}

  defp current_signer(members, chapter, actor, role) do
    case Map.get(members, {chapter, actor}) do
      %{key_id: key_id, pubkey: pubkey}
      when is_binary(key_id) and is_binary(pubkey) and byte_size(pubkey) == 32 ->
        {:ok, %{role: role, key_id: key_id, pubkey: pubkey}}

      _ ->
        {:error, {:unregistered_or_invalid_member, actor}}
    end
  end

  defp eligible_report(%{setoff: n} = report) when is_integer(n) and n > 0,
    do: {:ok, report}

  defp eligible_report(_), do: {:error, :nothing_to_net}

  defp residual_payload(obligations, chapter, nil, nil), do: {:ok, %{}}

  defp residual_payload(obligations, chapter, {debtor, creditor, amount}, residual_id)
       when is_binary(residual_id) and byte_size(residual_id) > 0 and
              is_integer(amount) and amount > 0 do
    if Map.has_key?(obligations, {chapter, residual_id}) do
      {:error, :residual_id_already_used}
    else
      {:ok,
       %{
         "residual_obligation_id" => residual_id,
         "net_debtor" => debtor,
         "net_creditor" => creditor,
         "net_minor" => amount
       }}
    end
  end

  defp residual_payload(_, _, _, _), do: {:error, :invalid_residual_id}
end
