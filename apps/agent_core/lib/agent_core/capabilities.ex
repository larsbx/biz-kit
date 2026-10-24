defmodule AgentCore.Capabilities do
  @moduledoc """
  Engine-neutral, fail-closed preflight for an already-authorized run.

  `check/2` compares *trusted host-derived* requirements with capabilities
  advertised by an administrator-approved, digest-pinned execution profile.
  Agent-supplied requirements are untrusted. This is not permission to read
  business data, invoke tools, or execute a task.

  Regions, data classifications, features and ceilings are declarative.
  Individual adapters must independently enforce the published configuration
  and reject unsupported features at runtime. No agent framework is assumed.
  """

  @features ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @region ~r/\A[a-zA-Z0-9][a-zA-Z0-9_.:-]{0,63}\z/
  @classes ~w(public internal confidential restricted)
  @max_duration_ms 31 * 86_400_000
  @max_output_bytes 16 * 1_048_576

  @doc """
  Verify an explicit, trusted run requirement against an immutable profile
  manifest's capability envelope. No feature/capability has a default.
  """
  @spec check(map(), map()) :: :ok | {:error, atom()}
  def check(%{"parameters" => %{"capabilities" => capabilities}}, requirements)
      when is_map(requirements) do
    with :ok <- validate_profile(capabilities),
         :ok <- validate_requirements(requirements),
         :ok <- subset(requirements["features"], capabilities["features"], :unsupported_agent_feature),
         :ok <- subset(requirements["data_classes"], capabilities["data_classes"], :data_class_not_allowed),
         :ok <- region_allowed(requirements["region"], capabilities["regions"]),
         :ok <- within_limits(requirements, capabilities) do
      :ok
    end
  end

  def check(_manifest, _requirements), do: {:error, :invalid_agent_capabilities}

  defp validate_profile(p) when is_map(p) do
    if MapSet.new(Map.keys(p)) == MapSet.new(~w(features data_classes regions max_duration_ms max_output_bytes)) and
         identifiers?(p["features"], @features, 32) and
         identifiers?(p["data_classes"], @classes, 4) and
         identifiers?(p["regions"], @region, 16) and
         integer_within?(p["max_duration_ms"], 1, @max_duration_ms) and
         integer_within?(p["max_output_bytes"], 1, @max_output_bytes),
       do: :ok,
       else: {:error, :invalid_agent_capabilities}
  end

  defp validate_profile(_other), do: {:error, :invalid_agent_capabilities}

  defp validate_requirements(r) when is_map(r) do
    if MapSet.new(Map.keys(r)) == MapSet.new(~w(features data_classes region max_duration_ms max_output_bytes)) and
         identifiers?(r["features"], @features, 32) and
         identifiers?(r["data_classes"], @classes, 4) and
         is_binary(r["region"]) and Regex.match?(@region, r["region"]) and
         integer_within?(r["max_duration_ms"], 1, @max_duration_ms) and
         integer_within?(r["max_output_bytes"], 1, @max_output_bytes),
       do: :ok,
       else: {:error, :invalid_agent_requirements}
  end

  defp validate_requirements(_other), do: {:error, :invalid_agent_requirements}

  defp identifiers?(values, allowed, maximum) when is_list(values) do
    values != [] and length(values) <= maximum and length(Enum.uniq(values)) == length(values) and
      Enum.all?(values, fn
        v when is_binary(v) ->
          case allowed do
            %Regex{} -> Regex.match?(allowed, v)
            list -> v in list
          end

        _ ->
          false
      end)
  end

  defp identifiers?(_values, _allowed, _maximum), do: false

  defp integer_within?(v, from, to) when is_integer(v), do: v >= from and v <= to
  defp integer_within?(_v, _from, _to), do: false

  defp subset(needed, available, error) do
    if Enum.all?(needed, &(&1 in available)), do: :ok, else: {:error, error}
  end

  defp region_allowed(region, regions) do
    if region in regions, do: :ok, else: {:error, :agent_region_not_allowed}
  end

  defp within_limits(r, p) do
    if r["max_duration_ms"] <= p["max_duration_ms"] and
         r["max_output_bytes"] <= p["max_output_bytes"],
       do: :ok,
       else: {:error, :agent_resource_budget_exceeded}
  end
end
