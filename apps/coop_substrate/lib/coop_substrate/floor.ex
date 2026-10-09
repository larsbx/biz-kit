defmodule CoopSubstrate.Floor do
  @moduledoc """
  The participation floor (Phase 1C step 6; hand-off §2.4):

      cleared?(member, at) = throughput(member, [at − window_ms, at)) ≥ threshold_vN(class)

  A pure query over two replays of the canonical log — the membership fold
  (class, lifecycle state, active floor rule) and the throughput fold — so
  any member can reproduce their own floor verdict from events alone
  (docs/phase1c_plan.md P1). The evaluation instant `at:` is caller-supplied;
  nothing here reads a clock. Hardship suspends evaluation (same rule the
  append gate enforces on `FloorEvaluationRecorded`). Enforcement lives at
  the gate since 10A (docs/phase10a_plan.md): floor transitions cite
  evaluations by id and the exit is bounded by the declared cure window —
  this query stays the pure verdict a recorded evaluation attests.
  """

  alias CoopSubstrate.Floor.Rules
  alias CoopSubstrate.Log
  alias CoopSubstrate.Membership.Lifecycle
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Projections.Throughput, as: ThroughputFold

  @doc """
  Does (chapter, member, entity) clear the floor at instant `at:` (ms,
  required)? Supports `as_of:` (log position). Errors are distinct states,
  not failures: no membership, no active floor rule, or hardship suspension.
  """
  @spec cleared?(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def cleared?(chapter_id, member_id, entity_id, opts) do
    at = Keyword.fetch!(opts, :at)
    replay_opts = Keyword.take(opts, [:as_of])

    with {:ok, gate} <- Log.replay(Membership, replay_opts),
         {:ok, throughput} <- Log.replay(ThroughputFold, replay_opts) do
      record = Membership.membership(gate, chapter_id, member_id, entity_id)
      active = gate.floor_rules[chapter_id]

      cond do
        record == nil ->
          {:error, {:no_membership, member_id, entity_id}}

        Lifecycle.floor_suspended?(record.state) ->
          {:error, :floor_suspended_by_hardship}

        active == nil ->
          {:error, {:no_active_floor_rule, chapter_id}}

        true ->
          # The activation gate guarantees the rule is known and its params
          # (incl. window_ms) validated.
          {:ok, rule} = Rules.fetch(active.rule_id)
          window_ms = Map.fetch!(active.params, "window_ms")

          value =
            ThroughputFold.value(
              throughput,
              chapter_id,
              member_id,
              entity_id,
              {at - window_ms, at}
            )

          {:ok, rule.cleared?(active.params, record.class, value)}
      end
    end
  end
end
