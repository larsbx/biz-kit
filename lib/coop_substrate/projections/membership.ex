defmodule CoopSubstrate.Projections.Membership do
  @moduledoc """
  The membership projection (Phase 1B): a chapter-scoped pure fold tracking
  registered entities, registered members (with their *current* signing key,
  following `KeyRotated`), membership records (class + lifecycle state), the
  active accrual rule per chapter, and open redemption schedules.

  This same fold is the **append gate's** state: `CoopSubstrate.Log` holds it
  alongside the chain head, rebuilt from the ledger on recovery and advanced
  on every append, and `CoopSubstrate.Protocol.Validity` checks each incoming
  envelope against it before anything persists. Because the state is a pure
  function of the log prefix, gate decisions are deterministic and
  reproducible by any member from events alone.

  Note the fold never reads log-assigned fields (`global_seq` etc.), so it is
  equally valid over unassigned envelopes — the gate uses this to give later
  events in a batch visibility of earlier ones before assignment.
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.Membership.Lifecycle
  alias CoopSubstrate.Protocol.Envelope

  @impl true
  def init do
    %{
      entities: %{},
      members: %{},
      memberships: %{},
      active_rules: %{},
      schedules: %{}
    }
  end

  @impl true
  def handle_event(%Envelope{type: "EntityRegistered", chapter_id: ch, payload: p}, state) do
    put_in(state, [:entities, Access.key({ch, p["entity_id"]})], %{
      class: p["class"],
      name: Map.get(p, "name")
    })
  end

  def handle_event(%Envelope{type: "MemberRegistered", chapter_id: ch, payload: p}, state) do
    {:bytes, pubkey} = p["pubkey"]

    put_in(state, [:members, Access.key({ch, p["member_id"]})], %{
      pubkey: pubkey,
      key_id: p["key_id"]
    })
  end

  def handle_event(%Envelope{type: "KeyRotated", chapter_id: ch, payload: p}, state) do
    # KeyRotated predates registration (1A, ungated): only a registered
    # member's current key is updated; rotations for unknown ids are inert
    # here (ChapterStats still records them).
    case state.members[{ch, p["member_id"]}] do
      nil ->
        state

      _member ->
        {:bytes, pubkey} = p["new_pubkey"]

        put_in(state, [:members, Access.key({ch, p["member_id"]})], %{
          pubkey: pubkey,
          key_id: p["new_key_id"]
        })
    end
  end

  def handle_event(%Envelope{type: "AccrualRuleActivated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:active_rules, Access.key(ch)], %{
      rule_id: p["rule_id"],
      params: p["params"]
    })
  end

  def handle_event(%Envelope{type: "RedemptionScheduleOpened", chapter_id: ch, payload: p}, state) do
    put_in(state, [:schedules, Access.key({ch, p["member_id"], p["entity_id"]})], %{
      years: p["years"],
      annual_cap_minor: p["annual_cap_minor"],
      method: p["method"]
    })
  end

  def handle_event(%Envelope{type: type, chapter_id: ch, payload: p} = env, state) do
    if Lifecycle.lifecycle_event?(type) do
      apply_lifecycle(state, ch, p, env)
    else
      state
    end
  end

  defp apply_lifecycle(state, ch, p, %Envelope{type: type} = _env) do
    key = {ch, p["member_id"], p["entity_id"]}
    current = state.memberships[key]

    case Lifecycle.apply(current && current.state, type) do
      {:ok, next} ->
        record = %{
          class: (current && current.class) || Map.get(p, "class"),
          state: next
        }

        put_in(state, [:memberships, Access.key(key)], record)

      {:error, _illegal} ->
        # The gate rejects illegal transitions before persistence, so this
        # branch is unreachable for a gated log; the fold stays total (and
        # deterministic) regardless.
        state
    end
  end

  # -- queries -----------------------------------------------------------------

  @doc "The membership record for (chapter, member, entity), or nil."
  def membership(state, chapter_id, member_id, entity_id) do
    state.memberships[{chapter_id, member_id, entity_id}]
  end

  @doc "All of one member's memberships in a chapter: `[{entity_id, record}]`."
  def memberships_of(state, chapter_id, member_id) do
    for {{^chapter_id, ^member_id, entity_id}, record} <- state.memberships do
      {entity_id, record}
    end
  end
end
