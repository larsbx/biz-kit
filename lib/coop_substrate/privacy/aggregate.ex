defmodule CoopSubstrate.Privacy.Aggregate do
  @moduledoc """
  The Aggregate seam (Phase 1C step 8; hand-off §4): every cross-member
  summation calls THIS module, never `Enum.sum` — swapping the backing
  (plaintext today; k-gated or additive-HE later, corpus 08 §6 ladder) must
  change zero caller code (acceptance item 13, docs/phase1c_plan.md P8).
  Escalation beyond the plain rung requires a demonstrated failure of this
  one (08 §6; premature crypto is a defect, 08 §9).

  Backing selection: `:aggregate_backing` app env; defaults to `Plaintext`.
  """

  alias CoopSubstrate.Privacy.Mechanism

  @callback sum(contributions :: [integer()]) :: integer()
  @callback descriptor() :: Mechanism.descriptor()

  @spec sum([integer()]) :: integer()
  def sum(contributions), do: backing().sum(contributions)

  @doc "The configured backing's mechanism descriptor, validated (Phase 6A)."
  @spec descriptor() :: {:ok, Mechanism.descriptor()} | {:error, term()}
  def descriptor, do: Mechanism.describe(backing())

  defp backing do
    Application.get_env(:coop_substrate, :aggregate_backing, __MODULE__.Plaintext)
  end

  defmodule Plaintext do
    @moduledoc "Day-one backing: plaintext sum by the auditable operator (hand-off §4)."

    @behaviour CoopSubstrate.Privacy.Aggregate

    @impl true
    def sum(contributions), do: Enum.sum(contributions)

    @impl true
    def descriptor, do: %{rung: :plain, boundary: :beam, workload: :bounded_computation}
  end
end
