defmodule BizKit.Extension.Manifest do
  @moduledoc """
  Strict BizKit.ExtensionV1 validator. No dynamic atoms, code loading, or grants.
  All command/event names and writers must be owned by their declaring extension.
  """

  @keys [
    :id,
    :contract_version,
    :version,
    :dependencies,
    :capabilities,
    :requested_grants,
    :commands,
    :events,
    :projections,
    :migrations,
    :deployment,
    :activation,
    :health
  ]

  @id ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @qualified ~r/\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/
  @semver ~r/\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/

  @spec validate(term()) :: {:ok, map()} | {:error, term()}
  def validate(manifest) when is_map(manifest) do
    with :ok <- exact_keys(manifest, @keys, :manifest),
         :ok <- check_id(manifest.id),
         :ok <- check_version(manifest.version),
         :ok <- check_dependencies(manifest.dependencies, manifest.id),
         :ok <- named_strings(manifest.capabilities, :capabilities),
         :ok <- named_strings(manifest.requested_grants, :requested_grants),
         :ok <- check_commands(manifest.commands, manifest.id, manifest.requested_grants),
         :ok <- check_events(manifest.events, manifest.id),
         :ok <- check_projections(manifest.projections, manifest.id),
         :ok <- named_strings(manifest.migrations, :migrations),
         :ok <- check_modes(manifest) do
      {:ok,
       %{
         manifest
         | dependencies: Enum.sort_by(manifest.dependencies, & &1.id),
           capabilities: Enum.sort(manifest.capabilities),
           requested_grants: Enum.sort(manifest.requested_grants),
           commands: Enum.sort_by(manifest.commands, & &1.name),
           events: Enum.sort_by(manifest.events, & &1.name),
           projections: Enum.sort_by(manifest.projections, & &1.name),
           migrations: Enum.sort(manifest.migrations)
       }}
    end
  end

  def validate(_), do: {:error, {:invalid_field, :manifest}}

  defp exact_keys(value, keys, field) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(keys),
      do: :ok,
      else: {:error, {:invalid_fields, field}}
  end

  defp exact_keys(_, _, field), do: {:error, {:invalid_fields, field}}

  defp check_id(id) when is_binary(id) do
    if Regex.match?(@id, id), do: :ok, else: {:error, {:invalid_field, :id}}
  end

  defp check_id(_), do: {:error, {:invalid_field, :id}}

  defp check_version(v) when is_binary(v) do
    if Regex.match?(@semver, v), do: :ok, else: {:error, {:invalid_field, :version}}
  end

  defp check_version(_), do: {:error, {:invalid_field, :version}}

  defp qualified?(s), do: is_binary(s) and byte_size(s) <= 128 and Regex.match?(@qualified, s)

  defp unique?(xs), do: length(xs) == length(Enum.uniq(xs))

  defp named_strings(xs, field) when is_list(xs) do
    if Enum.all?(xs, &qualified?/1) and unique?(xs),
      do: :ok,
      else: {:error, {:invalid_field, field}}
  end

  defp named_strings(_, field), do: {:error, {:invalid_field, field}}

  defp check_dependencies(xs, id) when is_list(xs) do
    valid? =
      Enum.all?(xs, fn dep ->
        exact_keys(dep, [:id, :min_version], :dependency) == :ok and
          match?(:ok, check_id(dep.id)) and dep.id != id and
          match?(:ok, check_version(dep.min_version))
      end)

    if valid? and unique?(Enum.map(xs, & &1.id)),
      do: :ok,
      else: {:error, {:invalid_field, :dependencies}}
  end

  defp check_dependencies(_, _), do: {:error, {:invalid_field, :dependencies}}

  defp check_commands(xs, id, grants) when is_list(xs) do
    valid? =
      Enum.all?(xs, fn command ->
        exact_keys(command, [:name, :writer, :required_grants], :command) == :ok and
          owned?(command.name, id) and command.writer == id and
          named_strings(command.required_grants, :required_grants) == :ok and
          Enum.all?(command.required_grants, &(&1 in grants))
      end)

    if valid? and unique?(Enum.map(xs, & &1.name)),
      do: :ok,
      else: {:error, {:invalid_field, :commands}}
  end

  defp check_commands(_, _, _), do: {:error, {:invalid_field, :commands}}

  defp check_events(xs, id) when is_list(xs) do
    valid? =
      Enum.all?(xs, fn event ->
        exact_keys(event, [:name, :writer], :event) == :ok and
          owned?(event.name, id) and event.writer == id
      end)

    if valid? and unique?(Enum.map(xs, & &1.name)),
      do: :ok,
      else: {:error, {:invalid_field, :events}}
  end

  defp check_events(_, _), do: {:error, {:invalid_field, :events}}

  defp check_projections(xs, id) when is_list(xs) do
    valid? =
      Enum.all?(xs, fn projection ->
        exact_keys(projection, [:name, :source_event], :projection) == :ok and
          owned?(projection.name, id) and qualified?(projection.source_event)
      end)

    if valid? and unique?(Enum.map(xs, & &1.name)),
      do: :ok,
      else: {:error, {:invalid_field, :projections}}
  end

  defp check_projections(_, _), do: {:error, {:invalid_field, :projections}}

  defp owned?(name, id), do: qualified?(name) and String.starts_with?(name, id <> ".")

  defp check_modes(m) do
    if m.contract_version == 1 and m.deployment in [:integrated, :external] and
         m.activation == :manual and m.health == :host,
       do: :ok,
       else: {:error, {:invalid_field, :contract_modes}}
  end
end
