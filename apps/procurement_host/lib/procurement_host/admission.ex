defmodule ProcurementHost.Admission do
  @moduledoc """
  Bounded re-signing after an explicit pre-append clock-boundary refusal.

  The signed envelope's second can end while it waits for Log. Try at most
  three times, constructing a fresh envelope each time with the SAME command
  identifier, version and attributes. Every attempt goes through current Log
  authorization. This does not extend a session, grant or quote deadline.

  Never retry a timeout, process exit, storage error, stale workflow version,
  expired/revoked authority, or any other unknown outcome. A lost successful
  response is not an explicit refusal and remains the operator's retry decision.
  """

  @spec run((-> term())) :: term()
  def run(operation) when is_function(operation, 0), do: attempt(operation, 3)

  defp attempt(operation, remaining) do
    case operation.() do
      {:error, :stale_procurement_admission_time} when remaining > 1 ->
        attempt(operation, remaining - 1)

      {:error, {:reject, 0, :stale_procurement_admission_time}} when remaining > 1 ->
        attempt(operation, remaining - 1)

      result -> result
    end
  end
end
