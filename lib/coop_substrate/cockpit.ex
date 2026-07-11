defmodule CoopSubstrate.Cockpit do
  @moduledoc """
  The operator cockpit, read side (Phase 5A; corpus 10 §5): the R-queue as a
  pure fold — open items, deadline-ordered, `as_of:`-reproducible, closed
  items gone. Zero private state: succession stays a key ceremony because
  nothing here lives in the person.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @doc """
  Open R items for a chapter, ordered `{deadline_ms, item_id}` (basis-time
  tie order is the flagged v0 correction, docs/phase5a_plan.md). Supports
  `as_of:`.
  """
  @spec queue(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def queue(chapter_id, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts) do
      items =
        for {{^chapter_id, item_id}, %{open: true} = item} <- state.escalations do
          item |> Map.delete(:open) |> Map.put(:item_id, item_id)
        end

      {:ok, Enum.sort_by(items, &{&1.deadline_ms, &1.item_id})}
    end
  end

  @doc """
  The boards (Phase 5B): guard counts + act heat per process, B_op
  accounting for the `now_ms` period, fold health. Everything recomputes
  from (log, declared constants, the caller's clock) — absent numbers say
  so (the ε denominator awaits domain act streams; checkpoint age awaits an
  operating decision — docs/phase5b_plan.md).
  """
  @spec boards(String.t(), integer(), keyword()) :: {:ok, map()} | {:error, term()}
  def boards(chapter_id, now_ms, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts),
         {:ok, envelopes} <- Log.read_all(Keyword.take(opts, [:as_of])) do
      items =
        for {{^chapter_id, item_id}, item} <- state.escalations,
            do: Map.put(item, :item_id, item_id)

      {:ok,
       %{
         queue: %{
           open: Enum.count(items, & &1.open),
           nearest_deadline_ms:
             items |> Enum.filter(& &1.open) |> Enum.map(& &1.deadline_ms) |> Enum.min(fn -> nil end)
         },
         processes: process_board(items),
         b_op: b_op_board(state, chapter_id, items, now_ms),
         fold_health: fold_health(envelopes, now_ms),
         veto_feed: :no_veto_eligible_acts_exist
       }}
    end
  end

  defp process_board(items) do
    items
    |> Enum.group_by(& &1.process)
    |> Enum.sort()
    |> Enum.map(fn {process, process_items} ->
      resolved = Enum.reject(process_items, & &1.open)
      approved = Enum.count(resolved, &(&1[:verdict] == "approved"))

      %{
        process: process,
        raised: length(process_items),
        open: Enum.count(process_items, & &1.open),
        approved: approved,
        declined: Enum.count(resolved, &(&1[:verdict] == "declined")),
        defects: Enum.count(resolved, &(&1[:verdict] == "returned_defect")),
        # Chronic approval ⇒ the bound is too tight; chronic decline ⇒ the
        # agent logic is wrong (10 §5) — computable before ε's denominator is.
        approval_rate:
          (resolved != [] && Float.round(approved / length(resolved), 2)) || nil,
        act_heat:
          process_items |> Enum.frequencies_by(& &1.act_type) |> Enum.sort() |> Map.new()
      }
    end)
  end

  defp b_op_board(state, chapter_id, items, now_ms) do
    constants =
      for name <- ["cockpit/b_op", "cockpit/period_ms", "cockpit/cost_default"],
          into: %{},
          do: {name, state.charter_constants[{chapter_id, name}]}

    if Enum.any?(Map.values(constants), &(not is_integer(&1) or &1 <= 0)) do
      %{configured: false}
    else
      period = constants["cockpit/period_ms"]
      ref = div(now_ms, period)

      resolved_in_period =
        Enum.count(items, fn item ->
          not item.open and is_integer(item[:resolved_ms]) and
            div(item.resolved_ms, period) == ref
        end)

      spent = resolved_in_period * constants["cockpit/cost_default"]

      %{
        configured: true,
        period_ref: ref,
        resolved_items: resolved_in_period,
        spent_minutes: spent,
        budget_minutes: constants["cockpit/b_op"],
        breach: spent > constants["cockpit/b_op"]
      }
    end
  end

  defp fold_health(envelopes, now_ms) do
    case List.last(envelopes) do
      nil ->
        %{head_seq: 0}

      last ->
        %{
          head_seq: last.global_seq,
          last_event_ms: last.timestamp_ms,
          head_age_ms: max(now_ms - last.timestamp_ms, 0)
        }
    end
  end
end
