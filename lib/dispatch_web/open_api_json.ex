defmodule DispatchWeb.OpenApiJson do
  @moduledoc """
  Deterministic JSON encoding of the OpenAPI description.

  The `openapi-diff` gate compares bytes, so the encoding must be stable across
  runs and machines. Map key order in Elixir is unspecified, so keys are sorted
  before encoding; otherwise the gate would fail on unrelated changes.
  """

  @doc "The canonical, byte-stable JSON for `contracts/openapi.json`."
  @spec encode() :: binary()
  def encode do
    DispatchWeb.ApiSpec.spec()
    |> OpenApiSpex.OpenApi.to_map()
    |> sort()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp sort(%{} = map) when not is_struct(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map(fn {key, value} -> {key, sort(value)} end)
    |> Jason.OrderedObject.new()
  end

  defp sort(list) when is_list(list), do: Enum.map(list, &sort/1)
  defp sort(other), do: other
end
