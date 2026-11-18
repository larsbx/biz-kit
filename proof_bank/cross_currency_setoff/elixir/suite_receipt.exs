defmodule CrossCurrencySetoff.SuiteReceipt do
  @moduledoc false
  # Loaded only by the proof runner. Record ExUnit's declared inventory and
  # every test lifecycle, independently of its human-readable CLI summary.
  use GenServer

  def init(_opts) do
    {:ok,
     %{
       schema: "bizkit.cross-currency.barter-suite.v1",
       suite_started: 0,
       suite_finished: 0,
       interrupted: false,
       declared: [],
       started: [],
       finished: []
     }}
  end

  def handle_cast({:suite_started, _opts}, state) do
    {:noreply, %{state | suite_started: state.suite_started + 1}}
  end

  def handle_cast({:module_started, module}, state) do
    declared =
      Enum.map(module.tests, fn test ->
        %{id: identity(test), file: Path.relative_to(Path.expand(module.file), File.cwd!())}
      end)

    {:noreply, %{state | declared: state.declared ++ declared}}
  end

  def handle_cast({:test_started, test}, state) do
    {:noreply, %{state | started: [identity(test) | state.started]}}
  end

  def handle_cast({:test_finished, test}, state) do
    result = %{id: identity(test), status: status(test.state)}
    {:noreply, %{state | finished: [result | state.finished]}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    state = %{state | suite_finished: state.suite_finished + 1}
    File.write!(System.fetch_env!("BARTER_SUITE_RECEIPT"), JSON.encode!(state) <> "\n")
    {:noreply, state}
  end

  def handle_cast(:max_failures_reached, state), do: {:noreply, %{state | interrupted: true}}
  def handle_cast({:sigquit, _pending}, state), do: {:noreply, %{state | interrupted: true}}
  def handle_cast(_event, state), do: {:noreply, state}

  defp identity(test), do: inspect(test.module) <> ":" <> Atom.to_string(test.name)
  defp status(nil), do: "passed"
  defp status({kind, _details}), do: Atom.to_string(kind)
  defp status(_other), do: "unknown"
end
