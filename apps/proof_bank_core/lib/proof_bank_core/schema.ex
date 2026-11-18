defmodule ProofBankCore.Schema do
  @moduledoc false

  @id_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,79}\z/

  def fields(value, required) when is_map(value) do
    actual = Map.keys(value)
    unknown = actual -- required
    missing = required -- actual

    cond do
      unknown != [] -> {:error, {:unknown_fields, Enum.sort(unknown)}}
      missing != [] -> {:error, {:missing_fields, Enum.sort(missing)}}
      true -> :ok
    end
  end

  def fields(_value, _required), do: {:error, :expected_map}

  def identifier(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@id_pattern, value),
      do: :ok,
      else: {:error, {:invalid_identifier, value}}
  end

  def identifier(_), do: {:error, :invalid_identifier}

  def positive_revision(value) when is_integer(value) and value > 0, do: :ok
  def positive_revision(_), do: {:error, :invalid_revision}

  def text(field, value) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= 4096 and String.trim(value) != "",
      do: :ok,
      else: {:error, {:invalid_text, field}}
  end

  def text(field, _), do: {:error, {:invalid_text, field}}

  def items(kind, values, validator) when is_list(values) and values != [] do
    result =
      Enum.reduce_while(values, {:ok, []}, fn item, {:ok, acc} ->
        case validator.(item) do
          {:ok, validated} -> {:cont, {:ok, [validated | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, entries} ->
        ordered = Enum.sort_by(entries, & &1.id)
        ids = Enum.map(ordered, & &1.id)

        if length(Enum.uniq(ids)) == length(ids),
          do: {:ok, ordered},
          else: {:error, {:duplicate_ids, kind}}

      other ->
        other
    end
  end

  def items(kind, _, _), do: {:error, {:invalid_collection, kind}}

  def answer(value) do
    with :ok <- fields(value, [:id, :question, :answer]),
         :ok <- identifier(value.id),
         :ok <- text(:question, value.question),
         :ok <- text(:answer, value.answer) do
      {:ok,
       %{id: value.id, question: String.trim(value.question), answer: String.trim(value.answer)}}
    end
  end

  def requirement(value) do
    with :ok <- fields(value, [:id, :statement, :kind, :answer_ids]),
         :ok <- identifier(value.id),
         :ok <- text(:statement, value.statement),
         :ok <- allowed_kind(value.kind),
         {:ok, refs} <- ref_ids(:answer_ids, value.answer_ids) do
      {:ok,
       %{
         id: value.id,
         statement: String.trim(value.statement),
         kind: value.kind,
         answer_ids: refs
       }}
    end
  end

  def obligation(value) do
    with :ok <- fields(value, [:id, :claim, :method, :requirement_ids]),
         :ok <- identifier(value.id),
         :ok <- text(:claim, value.claim),
         :ok <- allowed_method(value.method),
         {:ok, refs} <- ref_ids(:requirement_ids, value.requirement_ids) do
      {:ok,
       %{
         id: value.id,
         claim: String.trim(value.claim),
         method: value.method,
         requirement_ids: refs,
         status: :unverified
       }}
    end
  end

  def capabilities(values) when is_list(values) do
    with {:ok, caps} <- ref_ids(:capabilities, values, false) do
      {:ok, caps}
    end
  end

  def capabilities(_), do: {:error, {:invalid_collection, :capabilities}}

  defp allowed_kind(v) when v in [:invariant, :behavior, :objective], do: :ok
  defp allowed_kind(_), do: {:error, :invalid_requirement_kind}

  # :quint is bounded model exploration unless separately proven;
  # :manual and :conformance are not Lean proofs.
  defp allowed_method(v) when v in [:lean, :quint, :conformance, :manual], do: :ok
  defp allowed_method(_), do: {:error, :invalid_obligation_method}

  defp ref_ids(kind, values, require_nonempty \\ true)

  defp ref_ids(kind, values, require_nonempty) when is_list(values) do
    cond do
      require_nonempty and values == [] ->
        {:error, {:invalid_collection, kind}}

      Enum.any?(values, &(identifier(&1) != :ok)) ->
        {:error, {:invalid_reference_id, kind}}

      length(Enum.uniq(values)) != length(values) ->
        {:error, {:duplicate_references, kind}}

      true ->
        {:ok, Enum.sort(values)}
    end
  end

  defp ref_ids(kind, _, _), do: {:error, {:invalid_collection, kind}}

  def references(answers, requirements, obligations) do
    answer_ids = MapSet.new(answers, & &1.id)
    requirement_ids = MapSet.new(requirements, & &1.id)

    missing_answers =
      requirements
      |> Enum.flat_map(& &1.answer_ids)
      |> Enum.reject(&MapSet.member?(answer_ids, &1))
      |> Enum.uniq()
      |> Enum.sort()

    missing_requirements =
      obligations
      |> Enum.flat_map(& &1.requirement_ids)
      |> Enum.reject(&MapSet.member?(requirement_ids, &1))
      |> Enum.uniq()
      |> Enum.sort()

    covered =
      obligations
      |> Enum.flat_map(& &1.requirement_ids)
      |> MapSet.new()

    uncovered =
      requirements
      |> Enum.map(& &1.id)
      |> Enum.reject(&MapSet.member?(covered, &1))
      |> Enum.sort()

    cond do
      missing_answers != [] -> {:error, {:unknown_answers, missing_answers}}
      missing_requirements != [] -> {:error, {:unknown_requirements, missing_requirements}}
      uncovered != [] -> {:error, {:uncovered_requirements, uncovered}}
      true -> :ok
    end
  end
end
