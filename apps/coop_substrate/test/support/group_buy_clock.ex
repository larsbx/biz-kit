defmodule CoopSubstrate.GroupBuyClock do
  @moduledoc """
  Test-only clock shared by the signing caller and the serialized appender.
  Without a supervised fixture it delegates to System, so other suites retain
  their real-clock coverage. Only synchronous tests may install a fixture.
  """
  use Agent

  def start_link(milliseconds), do: Agent.start_link(fn -> milliseconds end, name: __MODULE__)

  def system_time(unit) do
    case Process.whereis(__MODULE__) do
      nil -> System.system_time(unit)
      pid -> Agent.get(pid, &System.convert_time_unit(&1, :millisecond, unit))
    end
  end

  def set(milliseconds), do: Agent.update(__MODULE__, fn _ -> milliseconds end)
end
