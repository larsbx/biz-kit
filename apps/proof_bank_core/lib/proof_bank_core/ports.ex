defmodule ProofBankCore.ConstructionPort do
  @moduledoc """
  Optional backend contract for producing candidate proof artifacts.

  The backend may use a CPU, Lean tactics, SAT/SMT, Mojo/MAX, or another
  engine. A successful return is NOT an accepted proof or business decision.
  The host owns authorization, budgets, data disclosure and artifact custody.
  """
  @callback construct(obligation :: map(), approved_context :: map()) ::
              {:ok, %{required(:candidate_ref) => String.t()}} | {:error, term()}
end

defmodule ProofBankCore.CheckingPort do
  @moduledoc """
  Independent checking boundary. A checker must pin the claim, axioms,
  dependencies, toolchain, exact bytes and evidence. Host policy determines
  which checking profiles are acceptable; a reported result cannot itself
  authorize extension activation or business writes.
  """
  @callback check(candidate_ref :: String.t(), approved_context :: map()) ::
              {:ok,
               %{required(:evidence_ref) => String.t(), required(:profile_digest) => String.t()}}
              | {:error, term()}
end
