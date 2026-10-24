defmodule AgentCore.ExecutionPort do
  @moduledoc """
  Engine-neutral execution backend contract.

  An adapter may wrap a local process, container, VM, model service, workflow
  engine, remote agent, or another execution mechanism. Implementations must
  accept ONLY trusted, host-approved profiles. Neither a running backend nor
  a success response acquires biz-kit task, read or business-write authority.

  Backend IDs and handles are operational identifiers, not business records.
  Admission to the CoopSubstrate ledger and artifact custody remain separate.
  Adapters must use stable, idempotent effect IDs and reconcile uncertain
  launches; cancellation is a request, not proof of termination.
  """

  @type execution :: %{required(:run_id) => String.t(), required(:ticket) => map()}
  @type profile :: map()
  @type handle :: term()
  @type status ::
          :queued | :running | :succeeded | :failed | :cancel_requested | :cancelled

  @doc "Request a launch under an operator-approved execution profile."
  @callback launch(execution(), profile(), effect_id :: String.t()) ::
              {:ok, handle()} | {:error, term()}

  @doc "Observe execution status; status and output never authorize business writes."
  @callback poll(handle()) ::
              {:ok, %{required(:state) => status(), optional(:candidate_ref) => term()}}
              | {:error, term()}

  @doc "Request cancellation; caller must poll or reconcile until it terminates."
  @callback cancel(handle(), reason :: atom()) :: :ok | {:error, term()}
end
