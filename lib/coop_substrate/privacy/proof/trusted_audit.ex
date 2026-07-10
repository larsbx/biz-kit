defmodule CoopSubstrate.Privacy.Proof.TrustedAudit do
  @moduledoc """
  Day-one Proof backing (hand-off §4): trusted-but-auditable. A "proof" is
  the fact plus the log position it was checked at — any holder of the log
  re-derives the verdict deterministically; there is no cryptographic
  content, and `verify/2` IS the audit (a full recomputation).

  FLAGGED DEVIATION from the plan's "signed assertion carrying the fold
  inputs' hash": no operator/role key exists yet to sign with — key
  structure is 1D (hand-off §4.5). The pinned log position makes the
  assertion auditable today; the signature attaches when the key does.
  """

  @behaviour CoopSubstrate.Privacy.Proof

  alias CoopSubstrate.Capital
  alias CoopSubstrate.Floor
  alias CoopSubstrate.Log

  @impl true
  def prove(fact, _private_inputs) do
    as_of = Log.head().global_seq

    if holds?(fact, as_of) do
      {:ok, %{fact: fact, as_of: as_of}}
    else
      {:error, :fact_does_not_hold}
    end
  end

  @impl true
  def verify(fact, %{fact: fact, as_of: as_of}), do: holds?(fact, as_of)
  def verify(_fact, _proof), do: false

  defp holds?({:floor_cleared, chapter, member, entity, at_ms}, as_of) do
    Floor.cleared?(chapter, member, entity, at: at_ms, as_of: as_of) == {:ok, true}
  end

  defp holds?({:balance_at_least, chapter, member, entity, min_minor}, as_of) do
    case Capital.balance(chapter, member, entity, as_of: as_of) do
      {:ok, balance} -> balance >= min_minor
      _ -> false
    end
  end

  defp holds?(_fact, _as_of), do: false
end
