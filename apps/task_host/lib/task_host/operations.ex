defmodule TaskHost.Operations do
  @moduledoc """
  A configurable, read-only operations view over existing project feeds.

  Configuration supplies presentation and exact project references. It does
  not create projects, grants, principals, commercial membership or task
  state. Every workspace is authorized against the same supplied canonical
  gate used to select its public feed projection. Unauthorized workspaces,
  including their labels and existence, are omitted.

  The first schema supports arbitrary workspace labels and categories. Its
  timezone is a display setting, not a recurring-work execution policy.
  The browser validates the zone against its actual timezone database before
  displaying date-based groups; this module only validates its syntax.
  """

  alias CoopSubstrate.Feed.{Access, View}

  @config_fields ~w(schema_version title time_zone workspaces)
  @workspace_fields ~w(id label category chapter_id tenant_id project_id release_review_url)
  @required_workspace_fields ~w(id label chapter_id tenant_id project_id)
  @view_kinds [:tasks, :suggestions, :workflows]
  @max_workspaces 32
  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/
  @release_review ~r/\Ahttps:\/\/[A-Za-z0-9][A-Za-z0-9.-]*\/biz-kit\/releases\/[a-z][a-z0-9-]{0,63}\/[a-z][a-z0-9-]{0,63}\z/
  @zone ~r/\A[A-Za-z0-9_+-]+(?:\/[A-Za-z0-9_+-]+)*\z/
  @control ~r/[\x00-\x1f\x7f]/u

  @doc "An unconfigured deployment is an empty operations view, not a demo."
  def default_config do
    %{
      "schema_version" => 1,
      "title" => "Operations",
      "time_zone" => "Etc/UTC",
      "workspaces" => []
    }
  end

  @doc "Normalize a closed, string-keyed schema-1 configuration."
  @spec normalize(term()) :: {:ok, map()} | {:error, :invalid_operations_config}
  def normalize(%{"schema_version" => 1, "workspaces" => workspaces} = config)
      when is_list(workspaces) and length(workspaces) <= @max_workspaces do
    title = Map.get(config, "title", "Operations")
    time_zone = Map.get(config, "time_zone", "Etc/UTC")

    if known_fields?(config, @config_fields) and text?(title, 120) and zone?(time_zone) and
         Enum.all?(workspaces, &workspace?/1) and unique?(workspaces) do
      {:ok,
       %{
         "schema_version" => 1,
         "title" => title,
         "time_zone" => time_zone,
         "workspaces" => Enum.map(workspaces, &Map.put_new(&1, "category", "general"))
       }}
    else
      invalid()
    end
  end

  def normalize(_config), do: invalid()

  @doc """
  Select only workspaces readable by `principal` in the supplied gate.

  Authorization and data selection use one gate value, so a grant from one
  snapshot cannot authorize data from a later snapshot. The host is still
  responsible for authenticating the principal for each request. No count,
  identifier, category or label of an unauthorized workspace is returned.
  """
  @spec snapshot(map(), String.t(), term()) ::
          {:ok, map()} | {:error, :invalid_operations_config | :unauthorized}
  def snapshot(gate, principal, config) when is_binary(principal) and principal != "" do
    with {:ok, config} <- normalize(config) do
      workspaces =
        for workspace <- config["workspaces"],
            scope = scope(workspace),
            authorized?(gate, principal, scope) do
          # No device enumeration is needed by this read-only view. The
          # whitelist also excludes delegations and custody receipts.
          view = gate |> View.select(scope) |> Map.take(@view_kinds)
          Map.put(workspace, "view", view)
        end

      {:ok, Map.put(config, "workspaces", workspaces)}
    end
  end

  def snapshot(_gate, _principal, _config), do: {:error, :unauthorized}

  defp authorized?(gate, principal, scope) do
    case Access.for_principal(gate.orchestration, principal, scope) do
      {:ok, _reader} ->
        true

      {:error, :no_grant} ->
        match?({:ok, _reader}, Access.for_administrator(gate, principal, scope))
    end
  end

  defp workspace?(workspace) when is_map(workspace) do
    known_fields?(workspace, @workspace_fields) and
      Enum.all?(@required_workspace_fields, &Map.has_key?(workspace, &1)) and
      Enum.all?(~w(id chapter_id tenant_id project_id), &segment?(workspace[&1])) and
      release_review?(workspace) and
      text?(workspace["label"], 120) and text?(Map.get(workspace, "category", "general"), 80)
  end

  defp workspace?(_workspace), do: false

  defp release_review?(%{"release_review_url" => url}),
    do: is_binary(url) and byte_size(url) <= 420 and Regex.match?(@release_review, url)

  defp release_review?(_workspace), do: true

  defp unique?(workspaces) do
    length(Enum.uniq_by(workspaces, & &1["id"])) == length(workspaces) and
      length(Enum.uniq_by(workspaces, &scope/1)) == length(workspaces)
  end

  defp scope(workspace),
    do: {workspace["chapter_id"], workspace["tenant_id"], workspace["project_id"]}

  defp known_fields?(value, fields), do: Enum.all?(Map.keys(value), &(&1 in fields))

  defp segment?(value), do: is_binary(value) and Regex.match?(@segment, value)

  defp zone?(value),
    do: is_binary(value) and byte_size(value) in 1..100 and Regex.match?(@zone, value)

  defp text?(value, max) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..max and
      String.trim(value) != "" and not Regex.match?(@control, value)
  end

  defp invalid, do: {:error, :invalid_operations_config}
end
