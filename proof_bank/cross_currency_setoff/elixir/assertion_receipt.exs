defmodule CrossCurrencySetoff.AssertionReceipt do
  @moduledoc false
  # Separate from the all-passing Mix suite receipt. Mutation controls need
  # exact failing test identities and exception classes, not CLI text matching.
  use GenServer

  def init(_opts) do
    {:ok,
     %{
       schema: "bizkit.cross-currency.assertion-suite.v1",
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
    {status, failures} = outcome(test.state)
    result = %{id: identity(test), status: status, failure_classes: failures}
    {:noreply, %{state | finished: [result | state.finished]}}
  end

  def handle_cast({:suite_finished, _times}, state) do
    state = %{state | suite_finished: state.suite_finished + 1}
    File.write!(System.fetch_env!("SETOFF_ASSERTION_RECEIPT"), JSON.encode!(state) <> "\n")
    {:noreply, state}
  end

  def handle_cast(:max_failures_reached, state), do: {:noreply, %{state | interrupted: true}}
  def handle_cast({:sigquit, _pending}, state), do: {:noreply, %{state | interrupted: true}}
  def handle_cast(_event, state), do: {:noreply, state}

  defp identity(test), do: inspect(test.module) <> ":" <> Atom.to_string(test.name)
  defp outcome(nil), do: {"passed", []}

  defp outcome({:failed, failures}) when is_list(failures) do
    classes =
      Enum.map(failures, fn
        {:error, %ExUnit.AssertionError{}, _stack} -> "ExUnit.AssertionError"
        {kind, %{__struct__: module}, _stack} -> Atom.to_string(kind) <> ":" <> inspect(module)
        _other -> "unknown"
      end)

    {"failed", classes}
  end

  defp outcome({kind, _details}), do: {Atom.to_string(kind), []}
  defp outcome(_other), do: {"unknown", []}
end
