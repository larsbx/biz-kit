defmodule AgentOpsStore.Host do
  @moduledoc """
  Trusted staging host integration. No callback may use executor-supplied
  identity, policy or proof markers as authority. Missing/failed verification
  must return an error; there is no permissive implementation.

  context/1 and committed_state/0 return CURRENT committed signed replay.
  The host must serialize sensitive disclosure/admission against revocation.
  recovery_context/1 grants cleanup access to the exact historical profile
  digest, independently of a revoked execution grant. It does not permit a
  new launch. Credentials and normalized backend handles stay outside prompts.

  verify_observation/2 independently checks proof provenance, immutable effect
  and backend identity, generation binding, finality (including in-flight
  creates/permanent idempotency) and candidate size/completion before the DB
  deadline. Its normalized receipt must bind that context and contain no
  credentials. Candidate observations require within_budget: true. Markers
  verified/final/within_budget are HOST outputs, never client attestations.
  A receipt ID, HTTP 404, timeout or cancellation ack is not such a proof.
  """

  @callback environment() :: :staging | :production | term()
  @callback context(run_key :: tuple()) :: {:ok, map()} | {:error, term()}
  @callback committed_state() :: {:ok, map()} | {:error, term()}
  @callback consent(plan :: map()) :: :ok | {:error, term()}
  @callback reference(plan :: map(), handle :: term()) :: {:ok, String.t()} | {:error, term()}
  @callback request_termination(effect :: String.t(), backend_ref :: String.t() | nil) ::
              :ok | {:error, term()}
  @callback recovery_context(row :: map()) :: {:ok, map()} | {:error, term()}
  @callback verify_observation(row :: map(), raw :: map()) :: {:ok, map()} | {:error, term()}
  @callback authenticate_execution(credential :: term()) ::
              {:ok,
               %{
                 principal_id: String.t(),
                 effect_id: String.t(),
                 epoch: pos_integer(),
                 backend_ref: String.t()
               }}
              | {:error, term()}
end
