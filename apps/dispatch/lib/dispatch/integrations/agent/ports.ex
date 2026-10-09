defmodule Dispatch.Integrations.Agent.Runtime do
  @moduledoc """
  Turn-based agent runtime port (Section 29.0).

  Only the central agent-integration component may call this. Section 29.0
  forbids Ash resources, policies, controllers, communications adapters, Oban
  jobs, Android code, and portal code from reaching a runtime directly, which is
  what keeps a runtime swap out of the authorization surface.
  """

  @callback open_session(Dispatch.Agent.SessionRequest.t()) ::
              {:ok, Dispatch.Agent.Session.t()} | {:error, term()}

  @callback run_turn(Dispatch.Agent.TurnRequest.t()) ::
              {:ok, Dispatch.Agent.TurnResult.t()} | {:error, term()}

  @callback close_session(Dispatch.Agent.Session.t(), reason :: atom()) ::
              :ok | {:error, term()}
end

defmodule Dispatch.Integrations.Agent.StreamingRuntime do
  @moduledoc """
  Streaming agent runtime port for voice (Section 29.0).

  Selected independently of the turn-based runtime, so a deployment can migrate
  voice and text separately.
  """

  @callback start_stream(Dispatch.Agent.StreamRequest.t(), pid()) ::
              {:ok, Dispatch.Agent.Stream.t()} | {:error, term()}

  @callback send_input(Dispatch.Agent.Stream.t(), Dispatch.Agent.InputEvent.t()) ::
              :ok | {:error, term()}

  @callback cancel(Dispatch.Agent.Stream.t(), reason :: atom()) :: :ok | {:error, term()}
end
