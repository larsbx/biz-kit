defmodule CoopSubstrate.Projections.Throughput do
  @moduledoc """
  The throughput fold (Phase 1C step 5; hand-off §2.4): recorded component
  claims plus obligation-rail discharges (the verified `settlement`
  component, corpus 05 §1.2), weighted by the chapter's active throughput
  rule at fold position — same in-log versioning discipline as
  `Projections.CapitalAccounts`: every entry records the `rule_id` that
  credited it, and a later activation never touches prior entries.

  Entry keying: claim entries land per (chapter, member, entity) — the
  membership the work was recorded against. Settlement entries land per
  (chapter, member, `nil`): an obligation is member-to-member and carries no
  entity, so its discharge credits **both parties** at member level, and the
  windowed query counts a member's rail settlement toward each of their
  memberships. **PLACEHOLDER governance semantics** (docs/phase1c_plan.md:
  the entity dimension of rail-derived throughput awaits the absent
  throughput_and_floor spec / charter).

  Discharges before any throughput rule is active credit nothing (there is
  no weight to run) — deterministic either way, since the outcome is a pure
  function of the log order.
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.Protocol.Envelope
  alias CoopSubstrate.Throughput.Rules

  @impl true
  def init do
    %{active_rules: %{}, obligations: %{}, entries: %{}}
  end

  @impl true
  def handle_event(%Envelope{type: "ThroughputRuleActivated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:active_rules, Access.key(ch)], %{
      rule_id: p["rule_id"],
      params: p["params"]
    })
  end

  def handle_event(%Envelope{type: "ThroughputRecorded", chapter_id: ch, payload: p} = env, state) do
    # The gate guarantees an active rule exists and the component is known.
    credit(state, ch, {ch, p["member_id"], p["entity_id"]}, p["component"], p["units"],
      occurred_ms: p["occurred_ms"],
      global_seq: env.global_seq
    )
  end

  def handle_event(%Envelope{type: "ObligationRecorded", chapter_id: ch, payload: p}, state) do
    put_in(state, [:obligations, Access.key({ch, p["obligation_id"]})], %{
      debtor_id: p["debtor_id"],
      creditor_id: p["creditor_id"],
      amount_minor: p["amount_minor"]
    })
  end

  def handle_event(%Envelope{type: "ObligationAssigned", chapter_id: ch, payload: p}, state) do
    update_in(state, [:obligations, Access.key({ch, p["obligation_id"]})], fn ob ->
      %{ob | debtor_id: p["new_debtor_id"]}
    end)
  end

  def handle_event(%Envelope{type: "ObligationDischarged", chapter_id: ch, payload: p} = env, state) do
    ob = Map.fetch!(state.obligations, {ch, p["obligation_id"]})

    # Settlement is participation by both parties; units = the settled
    # amount; event time = the signed envelope timestamp (the discharge
    # attests the settlement).
    Enum.reduce([ob.debtor_id, ob.creditor_id], state, fn member_id, state ->
      credit(state, ch, {ch, member_id, nil}, "settlement", ob.amount_minor,
        occurred_ms: env.timestamp_ms,
        global_seq: env.global_seq
      )
    end)
  end

  def handle_event(%Envelope{}, state), do: state

  # -- queries -----------------------------------------------------------------

  @doc """
  Weighted throughput for (chapter, member, entity) over the half-open
  event-time window `[from_ms, to_ms)`: entity-scoped claim entries plus the
  member's rail settlement entries (see moduledoc).
  """
  def value(state, chapter_id, member_id, entity_id, {from_ms, to_ms}) do
    [{chapter_id, member_id, entity_id}, {chapter_id, member_id, nil}]
    |> Enum.uniq()
    |> Enum.flat_map(&Map.get(state.entries, &1, []))
    |> Enum.filter(&(&1.occurred_ms >= from_ms and &1.occurred_ms < to_ms))
    |> Enum.map(& &1.credited_minor)
    |> Enum.sum()
  end

  @doc "All entries for (chapter, member, entity), fold order. Own-data query."
  def entries(state, chapter_id, member_id, entity_id) do
    Map.get(state.entries, {chapter_id, member_id, entity_id}, [])
  end

  # -- internals ---------------------------------------------------------------

  defp credit(state, ch, key, component, units, meta) do
    case state.active_rules[ch] do
      nil ->
        state

      %{rule_id: rule_id, params: params} ->
        {:ok, rule} = Rules.fetch(rule_id)

        entry = %{
          global_seq: meta[:global_seq],
          component: component,
          units: units,
          credited_minor: rule.credit(params, component, units),
          rule_id: rule_id,
          occurred_ms: meta[:occurred_ms]
        }

        update_in(state, [:entries, Access.key(key, [])], &(&1 ++ [entry]))
    end
  end
end
