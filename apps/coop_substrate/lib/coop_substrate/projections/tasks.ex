defmodule CoopSubstrate.Projections.Tasks do
  @moduledoc """
  `TaskCore.State` as a ledger projection, hosted by `CoopSubstrate.TaskHost`.
  The append gate (`Projections.Membership`) uses the same fold as replay.
  """

  @behaviour CoopSubstrate.Projection

  @impl true
  def init, do: TaskCore.State.init(CoopSubstrate.TaskHost)

  @impl true
  defdelegate handle_event(env, state), to: TaskCore.State

  defdelegate task_key(env), to: TaskCore.State
end
