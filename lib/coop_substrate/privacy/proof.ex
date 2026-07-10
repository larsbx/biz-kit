defmodule CoopSubstrate.Privacy.Proof do
  @moduledoc """
  The Proof seam (Phase 1C step 8; hand-off §4): `prove(fact, inputs)` /
  `verify(fact, proof)`. Callers depend on this module only; the backing
  (`:proof_backing` app env, default `TrustedAudit`) can become real ZK
  circuits with zero caller changes — and only on a demonstrated trust
  requirement (corpus 08 §6 ladder, 08 §9).

  First facts (docs/phase1c_plan.md): `floor_cleared`, `balance_at_least`.
  """

  @type fact ::
          {:floor_cleared, chapter :: String.t(), member :: String.t(), entity :: String.t(),
           at_ms :: integer()}
          | {:balance_at_least, chapter :: String.t(), member :: String.t(),
             entity :: String.t(), min_minor :: integer()}

  @callback prove(fact(), private_inputs :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback verify(fact(), proof :: term()) :: boolean()

  @spec prove(fact(), keyword()) :: {:ok, term()} | {:error, term()}
  def prove(fact, private_inputs \\ []), do: backing().prove(fact, private_inputs)

  @spec verify(fact(), term()) :: boolean()
  def verify(fact, proof), do: backing().verify(fact, proof)

  defp backing do
    Application.get_env(:coop_substrate, :proof_backing, __MODULE__.TrustedAudit)
  end
end
