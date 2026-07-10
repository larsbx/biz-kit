defmodule CoopSubstrate.Projections.CapitalAccounts do
  @moduledoc """
  The capital-account fold (Phase 1B; hand-off §2.3): per-(chapter, member,
  entity) internal capital accounts as a pure fold over the canonical log —
  `account(member, as_of) = fold(rule_vN, events(≤ as_of))`, queried through
  `CoopSubstrate.Capital`.

  Rule versioning: `AccrualRuleActivated` events switch the active rule per
  chapter *forward*; each accrual entry records the `rule_id` (and the
  credited amount computed under it) at the moment it was folded, so a later
  rule change can never mutate a historical entry — reproducibility is a
  property of the log alone. Value is ledger arithmetic, never appraisal
  (master_design §7 via the hand-off): integer minor units throughout.

  Account states: `:accruing` while the membership lives; every terminal
  membership exit flips the account to a redeemable state (`:redeemable`, or
  `:estate` for death-to-estate, keeping `estate_ref`); an open redemption
  schedule moves it to `:in_redemption`. Redemption payments consume accrual
  entries FIFO and draw the entity's sinking fund. These are the *data
  structures* the redemption workflow will drive later — no payout engine,
  caps, or eligibility enforcement lives here (docs/phase1b_plan.md).
  """

  @behaviour CoopSubstrate.Projection

  alias CoopSubstrate.Capital.AccrualRules
  alias CoopSubstrate.Membership.Lifecycle
  alias CoopSubstrate.Protocol.Envelope

  @impl true
  def init do
    %{active_rules: %{}, accounts: %{}, sinking_funds: %{}}
  end

  @impl true
  def handle_event(%Envelope{type: "AccrualRuleActivated", chapter_id: ch, payload: p}, state) do
    put_in(state, [:active_rules, Access.key(ch)], %{
      rule_id: p["rule_id"],
      params: p["params"]
    })
  end

  def handle_event(%Envelope{type: "PatronageRecorded", chapter_id: ch, payload: p} = env, state) do
    # The gate guarantees an active rule exists and the id is registered.
    %{rule_id: rule_id, params: params} = Map.fetch!(state.active_rules, ch)
    {:ok, rule} = AccrualRules.fetch(rule_id)
    credited = rule.credit(params, p["kind"], p["amount_minor"])

    entry = %{
      global_seq: env.global_seq,
      kind: p["kind"],
      amount_minor: p["amount_minor"],
      credited_minor: credited,
      remaining_minor: credited,
      rule_id: rule_id
    }

    update_account(state, {ch, p["member_id"], p["entity_id"]}, fn account ->
      %{
        account
        | entries: account.entries ++ [entry],
          credited_minor: account.credited_minor + credited
      }
    end)
  end

  def handle_event(%Envelope{type: "RedemptionScheduleOpened", chapter_id: ch, payload: p} = env, state) do
    update_account(state, {ch, p["member_id"], p["entity_id"]}, fn account ->
      %{
        account
        | status: :in_redemption,
          schedule: %{
            opened_seq: env.global_seq,
            years: p["years"],
            annual_cap_minor: p["annual_cap_minor"],
            method: p["method"],
            payments: []
          }
      }
    end)
  end

  def handle_event(%Envelope{type: "RedemptionPaid", chapter_id: ch, payload: p} = env, state) do
    amount = p["amount_minor"]
    key = {ch, p["member_id"], p["entity_id"]}
    payment = %{global_seq: env.global_seq, amount_minor: amount}

    state
    |> update_account(key, fn account ->
      %{
        account
        | redeemed_minor: account.redeemed_minor + amount,
          entries: consume_fifo(account.entries, amount),
          schedule:
            account.schedule && Map.update!(account.schedule, :payments, &(&1 ++ [payment]))
      }
    end)
    |> draw_sinking_fund(ch, p["entity_id"], amount)
  end

  def handle_event(%Envelope{type: "SinkingFundContributed", chapter_id: ch, payload: p}, state) do
    update_in(state, [:sinking_funds, Access.key({ch, p["entity_id"]}, 0)], &(&1 + p["amount_minor"]))
  end

  def handle_event(%Envelope{type: type, chapter_id: ch, payload: p} = _env, state) do
    with true <- Lifecycle.lifecycle_event?(type),
         {:ok, next} <- Lifecycle.target(type),
         true <- Lifecycle.terminal?(next) do
      update_account(state, {ch, p["member_id"], p["entity_id"]}, fn account ->
        case next do
          :deceased -> %{account | status: :estate, estate_ref: Map.get(p, "estate_ref")}
          _terminal -> %{account | status: :redeemable}
        end
      end)
    else
      _ -> state
    end
  end

  # -- queries -----------------------------------------------------------------

  @doc "The account for (chapter, member, entity), or nil."
  def account(state, chapter_id, member_id, entity_id) do
    state.accounts[{chapter_id, member_id, entity_id}]
  end

  @doc "Outstanding balance in minor units: credited − redeemed. 0 without an account."
  def balance(state, chapter_id, member_id, entity_id) do
    case account(state, chapter_id, member_id, entity_id) do
      nil -> 0
      account -> account.credited_minor - account.redeemed_minor
    end
  end

  @doc "The entity's sinking-fund balance (contributions − redemption draws)."
  def sinking_fund(state, chapter_id, entity_id) do
    Map.get(state.sinking_funds, {chapter_id, entity_id}, 0)
  end

  # -- internals ---------------------------------------------------------------

  defp update_account(state, key, fun) do
    update_in(state, [:accounts, Access.key(key, empty_account())], fun)
  end

  defp empty_account do
    %{
      status: :accruing,
      entries: [],
      credited_minor: 0,
      redeemed_minor: 0,
      schedule: nil,
      estate_ref: nil
    }
  end

  # FIFO: oldest entries are consumed first (multi-year payout ordering).
  defp consume_fifo(entries, 0), do: entries
  defp consume_fifo([], _amount), do: []

  defp consume_fifo([entry | rest], amount) do
    consumed = min(entry.remaining_minor, amount)

    [%{entry | remaining_minor: entry.remaining_minor - consumed} | consume_fifo(rest, amount - consumed)]
  end

  defp draw_sinking_fund(state, chapter_id, entity_id, amount) do
    update_in(state, [:sinking_funds, Access.key({chapter_id, entity_id}, 0)], &(&1 - amount))
  end
end
