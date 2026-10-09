defmodule Dispatch.LogFormatter do
  @moduledoc """
  Structured JSON log formatter (Section 32).

  Section 32 lists what must never be logged: access tokens, break-glass session
  references, raw incident reasons, message bodies, transcripts, precise
  coordinates, face data, and provider credentials. A formatter cannot inspect
  intent, so it enforces the mechanical half of that rule — it emits only
  allowlisted metadata keys, so a key added to a log call somewhere in the
  codebase cannot reach output until it is listed here and reviewed.
  """

  @allowed_metadata ~w(
    request_id correlation_id tenant_id participant_id role_assignment_id
    assignment_id conversation_id call_id proposal_id provider channel
    event_name capability purpose outcome reason_code mfa
  )a

  @doc "Formats one log event as a single JSON line."
  @spec format(Logger.level(), Logger.message(), Logger.Formatter.date_time_ms(), keyword()) ::
          IO.chardata()
  def format(level, message, timestamp, metadata) do
    payload = %{
      timestamp: format_timestamp(timestamp),
      level: level,
      service: "dispatch-central",
      environment: to_string(Application.get_env(:dispatch, :environment, :dev)),
      message: IO.chardata_to_string(message)
    }

    payload
    |> Map.merge(allowed(metadata))
    |> Jason.encode_to_iodata!()
    |> then(&[&1, "\n"])
  rescue
    # A formatter that raises takes the logger down with it, so an unencodable
    # term degrades to a plain line rather than losing the log pipeline.
    _ -> ["{\"level\":\"", to_string(level), "\",\"message\":\"log_format_error\"}\n"]
  end

  defp allowed(metadata) do
    metadata
    |> Keyword.take(@allowed_metadata)
    |> Map.new(fn {key, value} -> {key, stringify(value)} end)
  end

  defp stringify(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: inspect(value)

  defp format_timestamp({{year, month, day}, {hour, minute, second, millisecond}}) do
    :io_lib.format(
      "~4..0B-~2..0B-~2..0BT~2..0B:~2..0B:~2..0B.~3..0BZ",
      [year, month, day, hour, minute, second, millisecond]
    )
    |> IO.chardata_to_string()
  end
end
