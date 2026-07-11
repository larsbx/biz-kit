defmodule CoopSubstrate.Harness do
  @moduledoc """
  Queryable harness gate (Phase 2A; corpus 11 §2): `gate(section)` and its
  input counts, each a deterministic replay of the gate fold —
  as-of-reproducible, revocation-excluded, failing closed until the charter
  constants (`harness/<section>/{n,c,d}` and `k`) are declared.
  """

  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  @doc "Does gate(section) hold? Supports `as_of:`. Fails closed on undeclared constants."
  @spec gate(String.t(), String.t(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def gate(chapter_id, section, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts) do
      Membership.harness_gate(state, chapter_id, section)
    end
  end

  @doc "The gate's inputs (interviews/corroborated/documents/adopted/fixtures). Supports `as_of:`."
  @spec counts(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def counts(chapter_id, section, opts \\ []) do
    with {:ok, state} <- Log.replay(Membership, opts),
         {:ok, constants} <- Membership.harness_constants(state, chapter_id, section) do
      {:ok, Membership.harness_counts(state, chapter_id, section, constants.k)}
    end
  end
end
