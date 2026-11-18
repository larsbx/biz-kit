defmodule TaskCore.Intake do
  @moduledoc """
  Typed intake (docs/architecture/2026-11-02-typed-intake.md): a catalogue of
  request types, each fixing the shape of a task's Definition of Done. Pure.

  A request type declares its parameters and its criteria. A criterion's
  description may name a parameter as a hole, `{name}`. Instantiating fills
  the holes and nothing else, so whoever defines a typed Definition of Done
  chooses values, never structure: the criterion IDs, their number and their
  wording around the holes are the catalogue's.

  A catalogue is decoded data (string-keyed maps, lists and strings) that a
  host reads by digest (`TaskCore.Host.read_catalogue/1`):

      %{"request_types" => %{
          "feature" => %{
            "params" => ["area"],
            "criteria" => [%{"id" => "tests", "description" => "Tests for {area} pass"}]
          }}}

  Every parameter a type declares appears in at least one of its
  descriptions, and every hole names a declared parameter: a parameter that
  changes nothing would let two definitions differ without differing.
  """

  @hole ~r/\{([A-Za-z0-9_]+)\}/
  @max_types 64
  @max_params 16

  @doc "Validate a decoded catalogue: `{:ok, catalogue}` or `{:error, :invalid_intake_catalogue}`."
  def normalize_catalogue(%{"request_types" => types} = doc)
      when is_map(types) and map_size(types) in 1..@max_types do
    if Enum.all?(types, fn {name, type} -> segment?(name) and type?(type) end),
      do: {:ok, doc},
      else: {:error, :invalid_intake_catalogue}
  end

  def normalize_catalogue(_), do: {:error, :invalid_intake_catalogue}

  @doc """
  The criteria of `request_type` with `params` filled in. `params` must name
  exactly the type's parameters, each a nonblank string of at most 256 bytes.
  Each value is substituted once; it is never read as a further hole.
  """
  def instantiate(%{"request_types" => types}, request_type, params) do
    with {:ok, type} <- fetch_type(types, request_type),
         :ok <- exact_params(type["params"], params),
         :ok <- valid_values(params) do
      criteria =
        Enum.map(type["criteria"], fn c ->
          %{c | "description" => Regex.replace(@hole, c["description"], &fill(params, &1, &2))}
        end)

      with :ok <- TaskCore.DoD.validate_criteria(criteria), do: {:ok, criteria}
    end
  end

  defp fill(params, _whole, name), do: Map.fetch!(params, name)

  defp fetch_type(types, name) do
    case Map.fetch(types, name) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_request_type}
    end
  end

  defp exact_params(declared, params) when is_map(params) do
    if Enum.sort(Map.keys(params)) == Enum.sort(declared),
      do: :ok,
      else: {:error, :intake_params_mismatch}
  end

  defp exact_params(_declared, _params), do: {:error, :intake_params_mismatch}

  defp valid_values(params) do
    if Enum.all?(Map.values(params), &value?/1),
      do: :ok,
      else: {:error, :invalid_intake_param}
  end

  defp type?(%{"params" => params, "criteria" => criteria} = type)
       when map_size(type) == 2 and is_list(params) and length(params) <= @max_params do
    holes = holes(criteria)

    Enum.all?(params, &param_name?/1) and
      length(Enum.uniq(params)) == length(params) and
      TaskCore.DoD.validate_criteria(criteria) == :ok and
      MapSet.equal?(holes, MapSet.new(params))
  end

  defp type?(_), do: false

  defp holes(criteria) when is_list(criteria) do
    for %{"description" => d} when is_binary(d) <- criteria,
        [_, name] <- Regex.scan(@hole, d),
        into: MapSet.new(),
        do: name
  end

  defp holes(_), do: MapSet.new()

  defp param_name?(name),
    do: is_binary(name) and byte_size(name) in 1..64 and Regex.match?(~r/\A[A-Za-z0-9_]+\z/, name)

  defp value?(v),
    do: is_binary(v) and String.valid?(v) and byte_size(v) in 1..256 and String.trim(v) != ""

  defp segment?(value),
    do:
      is_binary(value) and byte_size(value) in 1..128 and
        Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/, value)
end
