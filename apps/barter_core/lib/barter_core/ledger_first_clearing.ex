defmodule BarterCore.LedgerFirstClearing do
  @moduledoc """
  Deterministic, pure previews of contractual debt-cycle clearing.

  Input obligations are HOST-ASSERTED commercial claims, not authenticated
  evidence. The returned clearing cycles and balanced per-actor journal intents
  are NOT admitted, signed, approved, legally discharged or financially settled.
  No currency conversion, credit issuance, custody or external bank instruction.
  The Hawala financial authority and local business-admission gate remain
  separate. A caller must independently validate contracts, participant consent,
  jurisdiction, source revision and effective legal discharge before posting.
  """

  alias BarterCore, as: B

  @schema "bizkit.barter.ledger-first-clearing.v1"
  @maximum 9_007_199_254_740_991
  @default_work_budget 16_000_000
  @keys ~w(id debtor creditor currency amount_minor revision evidence_ref valid_until status)a

  @doc """
  Preview reductions to same-currency commercial obligations by bilateral and
  directed multilateral cycles. Uses exact integer minor units.

  Every cycle subtracts the minimum positive obligation on its route. The
  deterministic shortest-path cycle selection is a *heuristic*, not a proof of
  globally minimum residual liquidity over all legal clearing arrangements.

  No real ledger mutation or legal settlement occurs.
  """
  def propose(obligations, now, opts \\ [])

  def propose(obligations, now, opts)
      when is_list(obligations) and is_integer(now) and now >= 0 and is_list(opts) do
    with :ok <- validate(obligations, now),
         :ok <- check_budget(obligations, opts),
         {:ok, original} <- safe_sum(Enum.map(obligations, & &1.amount_minor)) do
      snapshot = Enum.sort_by(obligations, & &1.id)

      {cycles, residuals} =
        snapshot
        |> Enum.group_by(& &1.currency)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.reduce({[], []}, fn {_currency, edges}, {all_cycles, all_residuals} ->
          {found, remaining} = clear_cycles(edges, [])
          {all_cycles ++ found, all_residuals ++ remaining}
        end)

      source_index = Map.new(snapshot, &{&1.id, &1})
      journals = journal_intents(cycles, source_index)
      cleared = Enum.sum(Enum.map(cycles, &(&1.amount_minor * length(&1.obligation_ids))))
      remaining = Enum.sum(Enum.map(residuals, & &1.amount_minor))

      if cleared + remaining != original do
        {:error, :conservation_failure}
      else
        hash_fields =
          [@schema, Integer.to_string(now)] ++
            Enum.flat_map(snapshot, &source_fields/1) ++
            Enum.flat_map(cycles, &cycle_fields/1)

        {:ok,
         %{
           schema: @schema,
           observed_at: now,
           obligations: snapshot,
           cycles: cycles,
           residuals: residuals,
           journal_intents: journals,
           original_minor: original,
           proposed_reduction_minor: cleared,
           residual_minor: remaining,
           status: :unadmitted_preview_only,
           authority: :host_assertions_unverified,
           discharge: :requires_contract_consent_and_legal_effect,
           financial_settlement: :none,
           optimization: :deterministic_cycle_heuristic_not_global_optimum,
           terms_hash: B.digest(hash_fields)
         }}
      end
    end
  end

  def propose(_, _, _), do: {:error, :invalid_obligations}

  @doc "Recompute an exact proposal; changed obligations, cycles or entries fail."
  def verify_plan(%{obligations: obligations} = candidate, now, opts \\ []) do
    case propose(obligations, now, opts) do
      {:ok, ^candidate} -> {:ok, candidate}
      _ -> {:error, :invalid_clearing_plan}
    end
  end

  def verify_plan(_, _, _), do: {:error, :invalid_clearing_plan}

  defp validate(obligations, now) do
    cond do
      not Enum.all?(obligations, &valid_obligation?(&1, now)) ->
        {:error, :invalid_obligations}

      Enum.uniq_by(obligations, & &1.id) |> length() != length(obligations) ->
        {:error, :duplicate_obligation}

      true ->
        :ok
    end
  end

  defp valid_obligation?(%{} = o, now) do
    Enum.sort(Map.keys(o)) == Enum.sort(@keys) and
      B.valid_public_id?(o.id) and
      B.valid_public_id?(o.debtor) and
      B.valid_public_id?(o.creditor) and
      o.debtor != o.creditor and
      is_binary(o.currency) and
      String.match?(o.currency, ~r/\A[A-Z]{3}\z/) and
      is_integer(o.amount_minor) and o.amount_minor > 0 and
      o.amount_minor <= @maximum and
      is_integer(o.revision) and o.revision >= 1 and o.revision <= @maximum and
      is_binary(o.evidence_ref) and byte_size(o.evidence_ref) in 1..256 and
      is_integer(o.valid_until) and o.valid_until > now and
      o.status == :host_declared_eligible
  end

  defp valid_obligation?(_, _), do: false

  defp check_budget(obligations, opts) do
    budget = Keyword.get(opts, :work_budget, @default_work_budget)
    n = length(obligations)

    cond do
      not Keyword.keyword?(opts) or
          Enum.any?(Keyword.keys(opts), &(&1 != :work_budget)) or
          length(Keyword.keys(opts)) > 1 or
          not is_integer(budget) or budget <= 0 ->
        {:error, :invalid_options}

      n * n * n * n > budget ->
        {:error, :work_budget_exceeded}

      true ->
        :ok
    end
  end

  defp safe_sum(amounts) do
    amount = Enum.sum(amounts)
    if amount <= @maximum, do: {:ok, amount}, else: {:error, :amount_overflow}
  end

  defp clear_cycles(edges, collected) do
    case next_cycle(edges) do
      nil ->
        {Enum.reverse(collected), Enum.filter(edges, &(&1.amount_minor > 0))}

      legs ->
        minimum = Enum.min(Enum.map(legs, & &1.amount_minor))
        ids = Enum.map(legs, & &1.id)
        membership = MapSet.new(ids)

        reduced =
          Enum.map(edges, fn edge ->
            if MapSet.member?(membership, edge.id) do
              %{edge | amount_minor: edge.amount_minor - minimum}
            else
              edge
            end
          end)

        cycle = %{currency: hd(legs).currency, amount_minor: minimum, obligation_ids: ids}
        clear_cycles(reduced, [cycle | collected])
    end
  end

  defp next_cycle(edges) do
    Enum.find_value(edges, fn edge ->
      if edge.amount_minor > 0 do
        case shortest_path(edge.creditor, edge.debtor, edges, edge.id) do
          nil -> nil
          path -> [edge | path]
        end
      end
    end)
  end

  # Breadth-first traversal avoids exponential enumeration of simple paths.
  # A positive edge must be consumed by each clearing cycle, so at most n
  # cycles can be produced. The admission budget conservatively bounds n^4.
  defp shortest_path(from, target, edges, excluded_id) do
    queue = :queue.in({from, []}, :queue.new())
    path_search(queue, MapSet.new([from]), target, edges, excluded_id)
  end

  defp path_search(queue, visited, target, edges, excluded_id) do
    case :queue.out(queue) do
      {:empty, _} ->
        nil

      {{:value, {current, prefix}}, rest} ->
        outgoing =
          Enum.filter(edges, fn edge ->
            edge.amount_minor > 0 and edge.debtor == current and edge.id != excluded_id
          end)

        {next_queue, next_visited, found} =
          Enum.reduce_while(outgoing, {rest, visited, nil}, fn edge, {q, seen, _} ->
            route = prefix ++ [edge]

            cond do
              edge.creditor == target ->
                {:halt, {q, seen, route}}

              MapSet.member?(seen, edge.creditor) ->
                {:cont, {q, seen, nil}}

              true ->
                {:cont,
                 {:queue.in({edge.creditor, route}, q), MapSet.put(seen, edge.creditor),
                  nil}}
            end
          end)

        if found == nil do
          path_search(next_queue, next_visited, target, edges, excluded_id)
        else
          found
        end
    end
  end

  defp journal_intents(cycles, index) do
    cycles
    |> Enum.with_index()
    |> Enum.flat_map(fn {cycle, cycle_index} ->
      Enum.flat_map(cycle.obligation_ids, fn obligation_id ->
        source = Map.fetch!(index, obligation_id)
        amount = cycle.amount_minor

        [
          posting(source.debtor, source.currency, obligation_id, cycle_index, :accounts_payable, :debit, amount),
          posting(source.debtor, source.currency, obligation_id, cycle_index, :clearing_control, :credit, amount),
          posting(source.creditor, source.currency, obligation_id, cycle_index, :clearing_control, :debit, amount),
          posting(source.creditor, source.currency, obligation_id, cycle_index, :accounts_receivable, :credit, amount)
        ]
      end)
    end)
    |> Enum.sort_by(fn row ->
      {row.actor, row.currency, row.cycle_index, row.obligation_id, row.account, row.side}
    end)
  end

  defp posting(actor, currency, obligation_id, cycle_index, account, side, amount) do
    %{
      actor: actor,
      currency: currency,
      cycle_index: cycle_index,
      obligation_id: obligation_id,
      account: account,
      side: side,
      amount_minor: amount,
      status: :unadmitted_preview
    }
  end

  defp source_fields(o) do
    [
      o.id, o.debtor, o.creditor, o.currency,
      Integer.to_string(o.amount_minor),
      Integer.to_string(o.revision),
      o.evidence_ref, Integer.to_string(o.valid_until),
      Atom.to_string(o.status)
    ]
  end

  defp cycle_fields(c) do
    [c.currency, Integer.to_string(c.amount_minor), Integer.to_string(length(c.obligation_ids))] ++
      c.obligation_ids
  end
end
