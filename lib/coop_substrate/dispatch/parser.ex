defmodule CoopSubstrate.Dispatch.Parser do
  @moduledoc """
  The v0 tender parser (Phase 8A; corpus 08 §7): a deterministic line
  parser for the `key: value` import format — no model, no frontier refs,
  nothing authoritative. Its output lands on the log only inside a graded
  `TenderParsed` event, and the published fixture set is its TDD corpus
  (11 §1.5): the dispatch-sim suite runs it over every published fixture.

      lane: detroit->chicago
      rate_minor: 210000
      equipment: dry_van

  Unknown lines are ignored (real tenders carry noise); the three fields
  above are required; `rate_minor` must be a positive integer.
  """

  @required ~w(lane rate_minor equipment)

  @doc "Parse tender text into `%{\"lane\", \"rate_minor\", \"equipment\"}`."
  def parse(text) when is_binary(text) do
    fields =
      text
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [key, value] -> Map.put(acc, String.trim(key), String.trim(value))
          _ -> acc
        end
      end)
      |> Map.take(@required)

    with :ok <- require_fields(fields),
         {:ok, rate} <- parse_rate(fields["rate_minor"]) do
      {:ok, %{fields | "rate_minor" => rate}}
    end
  end

  def parse(_other), do: {:error, :not_text}

  defp require_fields(fields) do
    case @required -- Map.keys(fields) do
      [] -> :ok
      missing -> {:error, {:missing_fields, missing}}
    end
  end

  defp parse_rate(value) do
    case Integer.parse(value) do
      {rate, ""} when rate > 0 -> {:ok, rate}
      _ -> {:error, {:bad_rate, value}}
    end
  end
end
