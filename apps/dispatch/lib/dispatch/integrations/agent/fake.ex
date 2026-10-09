defmodule Dispatch.Integrations.Agent.Fake do
  @moduledoc """
  The contract-test agent adapters named in Section 29.0.

  Their purpose is structural, not behavioural: end-to-end test 12 requires that
  Hermes can be replaced without changing tool schemas, domain state,
  communications adapters, or client APIs, and that is only demonstrable against
  a second adapter. These never call a model and never emit a tool call, so a
  test exercising them cannot accidentally mutate domain state.

  `Dispatch.Config` rejects them in production.
  """

  defmodule Runtime do
    @moduledoc "Turn-based contract adapter. Returns a deterministic non-tool-calling turn."
    @behaviour Dispatch.Integrations.Agent.Runtime

    @impl true
    def open_session(%Dispatch.Agent.SessionRequest{} = request) do
      {:ok,
       %Dispatch.Agent.Session{
         agent_session_id: request.agent_session_id,
         provider: :FAKE,
         opened_at: DateTime.utc_now(),
         adapter_version: "fake/1"
       }}
    end

    @impl true
    def run_turn(%Dispatch.Agent.TurnRequest{} = request) do
      {:ok,
       %Dispatch.Agent.TurnResult{
         session: request.session,
         finish_reason: :STOP,
         text: "",
         provider: :FAKE,
         latency_ms: 0,
         tool_calls: []
       }}
    end

    @impl true
    def close_session(%Dispatch.Agent.Session{}, _reason), do: :ok
  end

  defmodule StreamingRuntime do
    @moduledoc "Streaming contract adapter. Accepts input and produces no output events."
    @behaviour Dispatch.Integrations.Agent.StreamingRuntime

    @impl true
    def start_stream(%Dispatch.Agent.StreamRequest{} = request, consumer) when is_pid(consumer) do
      {:ok,
       %Dispatch.Agent.Stream{
         stream_id: "fake-" <> request.session.agent_session_id,
         session: request.session,
         provider: :FAKE
       }}
    end

    @impl true
    def send_input(%Dispatch.Agent.Stream{}, %Dispatch.Agent.InputEvent{}), do: :ok

    @impl true
    def cancel(%Dispatch.Agent.Stream{}, _reason), do: :ok
  end
end
