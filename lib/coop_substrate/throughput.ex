defmodule CoopSubstrate.Throughput do
  @moduledoc """
  Queryable throughput (Phase 1C step 5): every answer is a deterministic
  replay of `CoopSubstrate.Projections.Throughput` over the canonical log —
  `throughput(member, window, as_of) = fold(rule_vN, events ≤ as_of)`
  (hand-off §2.4; docs/phase1c_plan.md P1). The floor (step 6) reads
  `value/5`; per-member detail is only ever the member's own data.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Privacy
  alias CoopSubstrate.Projections.Throughput, as: Fold

  @doc """
  Weighted throughput for (chapter, member, entity) over the half-open
  event-time window `{from_ms, to_ms}`. Supports `as_of:` (log position).
  """
  @spec value(String.t(), String.t(), String.t(), {integer(), integer()}, keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def value(chapter_id, member_id, entity_id, {from_ms, to_ms}, opts \\ []) do
    with {:ok, state} <- Log.replay(Fold, opts) do
      {:ok, Fold.value(state, chapter_id, member_id, entity_id, {from_ms, to_ms})}
    end
  end

  @doc "The member's throughput entries for one membership. Supports `as_of:`."
  @spec entries(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def entries(chapter_id, member_id, entity_id, opts \\ []) do
    with {:ok, state} <- Log.replay(Fold, opts) do
      {:ok, Fold.entries(state, chapter_id, member_id, entity_id)}
    end
  end

  @doc """
  Chapter-wide system throughput over the window — a system aggregate,
  summed through the privacy seam; no per-member detail is exposed
  (hand-off §2.5). Supports `as_of:`.
  """
  @spec system_value(String.t(), {integer(), integer()}, keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def system_value(chapter_id, {from_ms, to_ms}, opts \\ []) do
    with {:ok, state} <- Log.replay(Fold, opts) do
      {:ok, Privacy.Aggregate.sum(Fold.contributions(state, chapter_id, {from_ms, to_ms}))}
    end
  end

  @doc """
  Federation-level throughput across chapters (Phase 1D; hand-off §3,
  acceptance 15): a computation over sovereign chapter folds, never an event
  (docs/phase1d_plan.md P2) — chapter contributions cross the line only as a
  seam-summed total. Supports `as_of:`.
  """
  @spec federation_value([String.t()], {integer(), integer()}, keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def federation_value(chapter_ids, {from_ms, to_ms}, opts \\ []) when is_list(chapter_ids) do
    with {:ok, state} <- Log.replay(Fold, opts) do
      contributions =
        Enum.flat_map(chapter_ids, &Fold.contributions(state, &1, {from_ms, to_ms}))

      {:ok, Privacy.Aggregate.sum(contributions)}
    end
  end
end
