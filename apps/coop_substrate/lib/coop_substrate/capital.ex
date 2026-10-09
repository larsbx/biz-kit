defmodule CoopSubstrate.Capital do
  @moduledoc """
  Queryable capital accounts (Phase 1B): every answer is a deterministic
  replay of `CoopSubstrate.Projections.CapitalAccounts` over the canonical
  log — `as_of:` a global sequence number gives the account exactly as it
  stood then (hand-off §2.3: `account(member, asOf)`), and any member can
  reproduce any number here from the events alone.

  This is the seam the stake-view UI (a later cold-start step) will read.
  The 1C privacy interfaces will wrap the *aggregate* queries; per-member
  detail is only ever the member's own data (hand-off invariant §0.6).
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Privacy
  alias CoopSubstrate.Projections.CapitalAccounts

  @doc "The account record for (chapter, member, entity), or nil. Supports `as_of:`."
  @spec account(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def account(chapter_id, member_id, entity_id, opts \\ []) do
    with {:ok, state} <- Log.replay(CapitalAccounts, opts) do
      {:ok, CapitalAccounts.account(state, chapter_id, member_id, entity_id)}
    end
  end

  @doc "Outstanding balance in minor units (credited − redeemed). Supports `as_of:`."
  @spec balance(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def balance(chapter_id, member_id, entity_id, opts \\ []) do
    with {:ok, state} <- Log.replay(CapitalAccounts, opts) do
      {:ok, CapitalAccounts.balance(state, chapter_id, member_id, entity_id)}
    end
  end

  @doc "The entity's sinking-fund balance. Supports `as_of:`."
  @spec sinking_fund(String.t(), String.t(), keyword()) ::
          {:ok, integer()} | {:error, term()}
  def sinking_fund(chapter_id, entity_id, opts \\ []) do
    with {:ok, state} <- Log.replay(CapitalAccounts, opts) do
      {:ok, CapitalAccounts.sinking_fund(state, chapter_id, entity_id)}
    end
  end

  @doc """
  The chapter's total sinking-fund pool — a system aggregate, summed through
  the privacy seam (Phase 1C step 8). Supports `as_of:`.
  """
  @spec sinking_fund_total(String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def sinking_fund_total(chapter_id, opts \\ []) do
    with {:ok, state} <- Log.replay(CapitalAccounts, opts) do
      contributions =
        for {{ch, _entity}, balance} <- state.sinking_funds, ch == chapter_id, do: balance

      {:ok, Privacy.Aggregate.sum(contributions)}
    end
  end
end
