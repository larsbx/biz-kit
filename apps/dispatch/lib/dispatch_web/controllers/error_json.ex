defmodule DispatchWeb.ErrorJSON do
  @moduledoc """
  RFC 9457 Problem Details for unhandled errors (Section 19.2).

  Every error response must carry `type`, `title`, `status`, `detail`,
  `instance`, `code`, and `correlation_id`. The detail text is derived from the
  status only, so an unexpected exception cannot leak internal state into a
  client response.
  """

  @doc false
  @spec render(String.t(), map()) :: map()
  def render(template, assigns) do
    status = String.trim_trailing(template, ".json") |> String.to_integer()
    title = Plug.Conn.Status.reason_phrase(status)

    %{
      type: "https://dispatch.invalid/problems/#{code_for(status)}",
      title: title,
      status: status,
      detail: title,
      instance: instance(assigns),
      code: code_for(status) |> String.upcase(),
      correlation_id: correlation_id(assigns)
    }
  end

  defp code_for(status) do
    status |> Plug.Conn.Status.reason_atom() |> Atom.to_string()
  rescue
    _ -> "unknown_error"
  end

  defp instance(%{conn: %Plug.Conn{request_path: path}}), do: path
  defp instance(_assigns), do: "unknown"

  defp correlation_id(%{conn: %Plug.Conn{assigns: %{correlation_id: id}}}) when is_binary(id),
    do: id

  defp correlation_id(_assigns), do: "unassigned"
end
