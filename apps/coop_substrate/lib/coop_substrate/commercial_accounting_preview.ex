defmodule CoopSubstrate.CommercialAccountingPreview do
  @moduledoc """
  Read-only accounting journal and residual-debt preview for an existing,
  source-bound `CommercialSetoffIntentReservedV2` business-ledger event.

  The canonical local Log authenticates the historical reservation. This
  module recomputes the exact-source arithmetic without posting a journal,
  closing an obligation, releasing a reservation, or instructing a bank.

  Even a valid, three-party-signed V2 reservation proves neither business
  agency nor legally effective contractual setoff. The displayed entries are
  HYPOTHETICAL, not entries in CoopSubstrate or Hawala accounting books.
  """

  alias CoopSubstrate.{Canonical, Log}
  alias CoopSubstrate.Protocol.Envelope

  @schema "bizkit.commercial.accounting-preview.v1"
  @reservation "CommercialSetoffIntentReservedV2"
  @profile "source_bound_proposal_v2"
  @max_minor 9_223_372_036_854_775_807
  @source_fields ~w(amount_minor creditor_id debtor_id denomination latest_event_hash
                    latest_event_id obligation_id original_event_hash original_event_id
                    source_revision)

  @doc """
  Read the authoritative local business gate without mutation. A stable
  before/after head establishes a consistent *read*, not a CAS reservation.
  """
  def preview(chapter, intent_id, server \\ Log.server())

  def preview(chapter, intent_id, server)
      when is_binary(chapter) and chapter != "" and is_binary(intent_id) and intent_id != "" do
    head = Log.head(server)
    gate = Log.gate(server)

    with {:ok, plan} <- from_gate(gate, chapter, intent_id),
         ^head <- Log.head(server) do
      {:ok, %{plan | observed_head: head, evidence_scope: :canonical_local_read_only}}
    else
      {:error, _} = error -> error
      _ -> {:error, :concurrent_ledger_change}
    end
  end

  def preview(_, _, _), do: {:error, :invalid_request}

  @doc """
  Pure snapshot calculation. Caller-supplied gates are UNTRUSTED; only
  preview/3 obtains this state from the local canonical Log. No call to this
  function constitutes approval, authorization or a posting.
  """
  def from_gate(
        %{commercial_admission: %{profiles: profiles, intents: intents, reservations: reserved}} =
          gate,
        chapter,
        intent_id
      )
      when is_map(profiles) and is_map(intents) and is_map(reserved) and
             is_binary(chapter) and is_binary(intent_id) do
    intent = {chapter, intent_id}

    with %{profile: @profile, version: 2} <- Map.get(profiles, chapter),
         %{
           status: :reserved_proposal_not_discharge,
           contractual_authority: :unverified,
           accounting_recognition: :none,
           discharge: :none,
           settlement: :none,
           event:
             %Envelope{type: @reservation, chapter_id: ^chapter, payload: p} = event
         } <- Map.get(intents, intent),
         :ok <- Envelope.verify(event),
         :ok <- validate_header(p, intent_id),
         {:ok, rows, a_to_b, b_to_a} <- validate_rows(gate, reserved, intent, p),
         {:ok, source_digest} <- canonical_digest(rows, p),
         {:ok, event_hash} <- Envelope.event_hash(event),
         {:ok, allocations, residuals} <- allocate_bilateral(rows, p),
         {:ok, postings} <- journal_intents(allocations, p),
         :ok <- verify_conservation(allocations, residuals, postings, a_to_b, b_to_a, p) do
      {:ok,
       %{
         schema: @schema,
         status: :hypothetical_unposted_accounting,
         evidence_scope: :caller_snapshot_untrusted,
         observed_head: nil,
         chapter_id: chapter,
         intent_id: intent_id,
         signed_event_id: event.event_id,
         signed_event_hash: event_hash,
         source_terms_digest: source_digest,
         currency: p["denomination"],
         parties: [p["party_a"], p["party_b"]],
         original_gross_minor: a_to_b + b_to_a,
         proposed_gross_reduction_minor: 2 * p["setoff"],
         residual_gross_minor: a_to_b + b_to_a - 2 * p["setoff"],
         source_allocations: allocations,
         residual_obligations: residuals,
         journal_intents: postings,
         accounting_posted: false,
         contractual_discharge: :not_established,
         financial_settlement: :none,
         provider_instruction: :none,
         optimization: :exact_bilateral_fifo_allocation_not_multilateral_optimum
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :not_an_authoritative_protected_reservation}
    end
  end

  def from_gate(_, _, _), do: {:error, :invalid_gate_snapshot}

  defp validate_header(p, intent_id) when is_map(p) do
    a = p["party_a"]
    b = p["party_b"]
    d = p["denomination"]
    amount = p["setoff"]

    if p["profile"] == @profile and p["version"] == 2 and
         p["intent_id"] == intent_id and
         is_binary(a) and is_binary(b) and a < b and
         is_binary(d) and String.match?(d, ~r/\A[A-Z]{3}\z/) and
         is_integer(amount) and amount > 0 and amount <= @max_minor do
      :ok
    else
      {:error, :invalid_protected_reservation_header}
    end
  end

  defp validate_header(_, _), do: {:error, :invalid_protected_reservation_header}

  defp validate_rows(gate, reserved, {chapter, _} = intent, p) do
    rows = p["sources"]
    a = p["party_a"]
    b = p["party_b"]
    currency = p["denomination"]

    cond do
      not is_list(rows) or length(rows) < 2 or length(rows) > 256 ->
        {:error, :invalid_source_count}

      not Enum.all?(rows, &valid_source?(&1, {a, b}, currency)) ->
        {:error, :invalid_source_terms}

      Enum.map(rows, & &1["obligation_id"]) !=
          (rows |> Enum.map(& &1["obligation_id"]) |> Enum.uniq() |> Enum.sort()) ->
        {:error, :duplicate_or_unsorted_source}

      not Enum.all?(rows, fn row ->
        id = row["obligation_id"]
        obligation = get_in(gate, [:obligations, {chapter, id}])
        source = get_in(gate, [:commercial_admission, :sources, {chapter, id}])

        Map.get(reserved, {chapter, id}) == intent and
          match?(%{open: true}, obligation) and
          obligation.debtor_id == row["debtor_id"] and
          obligation.creditor_id == row["creditor_id"] and
          obligation.amount_minor == row["amount_minor"] and
          obligation.denomination == row["denomination"] and
          match?(%{original_only: true, revision: 0}, source) and
          source.original_event_id == row["original_event_id"] and
          source.latest_event_id == row["latest_event_id"] and
          row["original_event_hash"] == {:bytes, source.original_event_hash} and
          row["latest_event_hash"] == {:bytes, source.latest_event_hash}
      end) ->
        {:error, :source_reservation_or_lineage_changed}

      true ->
        {a_to_b, b_to_a} =
          Enum.reduce(rows, {0, 0}, fn row, {ab, ba} ->
            n = row["amount_minor"]
            if row["debtor_id"] == a, do: {ab + n, ba}, else: {ab, ba + n}
          end)

        if a_to_b > 0 and b_to_a > 0 and
             a_to_b <= @max_minor and b_to_a <= @max_minor and
             a_to_b + b_to_a <= @max_minor and
             {p["a_to_b"], p["b_to_a"], p["setoff"]} ==
               {a_to_b, b_to_a, min(a_to_b, b_to_a)} do
          {:ok, rows, a_to_b, b_to_a}
        else
          {:error, :aggregate_mismatch_or_overflow}
        end
    end
  end

  defp valid_source?(%{} = row, {a, b}, currency) do
    Enum.sort(Map.keys(row)) == Enum.sort(@source_fields) and
      is_binary(row["obligation_id"]) and row["obligation_id"] != "" and
      {row["debtor_id"], row["creditor_id"]} in [{a, b}, {b, a}] and
      row["denomination"] == currency and
      is_integer(row["amount_minor"]) and
      row["amount_minor"] > 0 and row["amount_minor"] <= @max_minor and
      row["source_revision"] == 0 and
      is_binary(row["original_event_id"]) and
      is_binary(row["latest_event_id"]) and
      match?({:bytes, <<_::256>>}, row["original_event_hash"]) and
      match?({:bytes, <<_::256>>}, row["latest_event_hash"])
  end

  defp valid_source?(_, _, _), do: false

  defp canonical_digest(rows, p) do
    case Canonical.hash(rows) do
      {:ok, digest} ->
        if p["source_terms_digest"] == {:bytes, digest},
          do: {:ok, digest},
          else: {:error, :source_commitment_mismatch}

      {:error, _} ->
        {:error, :invalid_canonical_source_encoding}
    end
  end

  defp allocate_bilateral(rows, p) do
    a = p["party_a"]
    setoff = p["setoff"]

    {left, rest_a} = allocate(Enum.filter(rows, &(&1["debtor_id"] == a)), setoff)
    {right, rest_b} = allocate(Enum.filter(rows, &(&1["debtor_id"] != a)), setoff)

    if rest_a == 0 and rest_b == 0 do
      allocations = Enum.sort_by(left ++ right, & &1.source_id)

      residuals =
        allocations
        |> Enum.filter(&(&1.remaining_minor > 0))
        |> Enum.map(&Map.take(&1, [:source_id, :debtor, :creditor, :remaining_minor]))

      {:ok, allocations, residuals}
    else
      {:error, :unallocated_setoff}
    end
  end

  defp allocate(rows, target) do
    Enum.map_reduce(rows, target, fn row, remaining ->
      applied = min(row["amount_minor"], remaining)

      {%{
         source_id: row["obligation_id"],
         debtor: row["debtor_id"],
         creditor: row["creditor_id"],
         original_minor: row["amount_minor"],
         proposed_offset_minor: applied,
         remaining_minor: row["amount_minor"] - applied
       }, remaining - applied}
    end)
  end

  defp journal_intents(allocations, p) do
    currency = p["denomination"]

    postings =
      allocations
      |> Enum.filter(&(&1.proposed_offset_minor > 0))
      |> Enum.flat_map(fn row ->
        n = row.proposed_offset_minor
        id = row.source_id

        [
          posting(row.debtor, currency, id, :accounts_payable, :debit, n),
          posting(row.debtor, currency, id, :commercial_clearing_control, :credit, n),
          posting(row.creditor, currency, id, :commercial_clearing_control, :debit, n),
          posting(row.creditor, currency, id, :accounts_receivable, :credit, n)
        ]
      end)
      |> Enum.sort_by(&{&1.actor, &1.source_id, &1.account, &1.side})

    {:ok, postings}
  end

  defp posting(actor, currency, source_id, account, side, amount) do
    %{
      actor: actor,
      currency: currency,
      source_id: source_id,
      account: account,
      side: side,
      amount_minor: amount,
      status: :unposted_no_legal_effect
    }
  end

  defp verify_conservation(allocations, residuals, postings, a_to_b, b_to_a, p) do
    setoff = p["setoff"]
    applied = Enum.sum(Enum.map(allocations, & &1.proposed_offset_minor))
    residual = Enum.sum(Enum.map(residuals, & &1.remaining_minor))

    balanced =
      postings
      |> Enum.group_by(& &1.actor)
      |> Enum.all?(fn {_actor, entries} ->
        debit = sum(entries, :debit)
        credit = sum(entries, :credit)

        controls = Enum.filter(entries, &(&1.account == :commercial_clearing_control))

        debit == credit and
          sum(controls, :debit) == sum(controls, :credit)
      end)

    if applied == 2 * setoff and
         applied + residual == a_to_b + b_to_a and balanced do
      :ok
    else
      {:error, :preview_conservation_failure}
    end
  end

  defp sum(entries, side) do
    entries
    |> Enum.filter(&(&1.side == side))
    |> Enum.sum_by(& &1.amount_minor)
  end
end
