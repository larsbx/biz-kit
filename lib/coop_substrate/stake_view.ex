defmodule CoopSubstrate.StakeView do
  @moduledoc """
  The member stake view (Phase 11B, docs/phase11b_plan.md) — the composed
  own-data surface the hand-off named since 1B: one call answers "what do
  I have?" for one member.

  Composition, never recomputation: every number comes from the
  already-classified module queries (`Capital`, `Floor`, `Throughput`,
  `Dispatch`) or the gate fold, so the view can never drift from them.
  Own-data by shape: the single `member_id` argument is subject and
  audience; the only cross-member content is the member's own dual-signed
  obligation edges (their side of the 07 §5 sovereign edge). The floor
  instant `at:` is caller-supplied — nothing here reads a clock.

  Requesting-member authentication remains a transport concern (§8
  query-authn): every access today is a library call; this module is the
  own-data shape the future middleware will enforce.
  """

  alias CoopSubstrate.Capital
  alias CoopSubstrate.Dispatch
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership
  alias CoopSubstrate.Throughput

  @doc """
  The member's whole stake in a chapter. Options: `at:` (ms) — the floor/
  throughput evaluation instant; omitted, that section reports
  `:no_instant_given` rather than guessing.
  """
  def view(chapter_id, member_id, opts \\ []) do
    at = Keyword.get(opts, :at)

    with {:ok, state} <- Log.replay(Membership) do
      case state.members[{chapter_id, member_id}] do
        nil ->
          {:error, {:unregistered_member, member_id}}

        member ->
          memberships = Membership.memberships_of(state, chapter_id, member_id)

          {:ok,
           %{
             member_id: member_id,
             key_id: member.key_id,
             memberships:
               Map.new(memberships, fn {entity_id, record} ->
                 {entity_id, entity_view(state, chapter_id, member_id, entity_id, record, at)}
               end),
             obligations: obligation_edges(state, chapter_id, member_id)
           }}
      end
    end
  end

  defp entity_view(state, ch, member_id, entity_id, record, at) do
    {:ok, balance} = Capital.balance(ch, member_id, entity_id)
    {:ok, dispatch} = Dispatch.demo_kit(ch, member_id, entity_id)

    %{
      class: record.class,
      state: record.state,
      capital: %{
        balance_minor: balance,
        redemption_schedule: state.schedules[{ch, member_id, entity_id}]
      },
      floor: floor_view(state, ch, member_id, entity_id, at),
      dispatch: dispatch
    }
  end

  defp floor_view(_state, _ch, _member_id, _entity_id, nil), do: :no_instant_given

  defp floor_view(state, ch, member_id, entity_id, at) do
    verdict =
      case Floor.cleared?(ch, member_id, entity_id, at: at) do
        {:ok, cleared} -> cleared
        {:error, reason} -> reason
      end

    throughput =
      case state.floor_rules[ch] do
        %{params: %{"window_ms" => window_ms}} ->
          {:ok, value} = Throughput.value(ch, member_id, entity_id, {at - window_ms, at})
          %{window_ms: window_ms, value: value}

        nil ->
          :no_active_floor_rule
      end

    %{at_ms: at, cleared: verdict, throughput: throughput}
  end

  # The member's own edges: every obligation they co-signed, both
  # directions, open only — never a lookup ABOUT anyone else.
  defp obligation_edges(state, ch, member_id) do
    for {{^ch, id}, %{open: true} = ob} <- state.obligations,
        member_id in [ob.debtor_id, ob.creditor_id] do
      %{
        obligation_id: id,
        direction: if(ob.debtor_id == member_id, do: :owes, else: :owed),
        counterparty: if(ob.debtor_id == member_id, do: ob.creditor_id, else: ob.debtor_id),
        amount_minor: ob.amount_minor,
        denomination: ob.denomination
      }
    end
    |> Enum.sort_by(& &1.obligation_id)
  end
end
