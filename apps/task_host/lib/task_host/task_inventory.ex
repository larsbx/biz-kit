defmodule TaskHost.TaskInventory do
  @moduledoc "Bounded pages of tasks, projects and authority from one ledger snapshot."

  alias CoopSubstrate.Feed.{Access, View}
  alias TaskCore.{Projects, State, TaskLifecycle}

  @fields ~w(limit after snapshot state open roadmap workflow text)
  @default_limit 50
  @max_limit 200
  @roles %{
    grants: "operator",
    suggester_grants: "suggester",
    dod_grants: "reviewer",
    delegations: "delegation",
    task_access_grants: "task_access"
  }

  @doc """
  Sort by stable task ID. A continuation names the exact ledger head of the
  preceding page. If the head advanced, start over from a new first page.
  """
  def page({gate, {seq, hash}}, scope, params) do
    snapshot = token(seq, hash)
    after_id = params["after"]

    with true <- Enum.all?(Map.keys(params), &(&1 in @fields)) or {:error, :unknown_filter},
         {:ok, limit} <- limit(params["limit"]),
         :ok <- filter_values(params),
         :ok <- continue(after_id, params["snapshot"], snapshot) do
      selected =
        gate
        |> View.tasks(scope)
        |> Enum.filter(fn {_id, task} -> matches?(task, params) end)
        |> Enum.sort_by(&elem(&1, 0))

      {rows, continuation} = window(selected, after_id, limit)

      {:ok,
       %{
         tasks: Enum.map(rows, fn {id, task} -> Map.put(task, :task_id, id) end),
         total: length(selected),
         snapshot: snapshot,
         next_after: continuation
       }}
    end
  end

  @doc "The canonical grants and delegations in one project, including inactive records."
  def authority({gate, {seq, hash}}, {chapter, _, _} = scope, params) do
    snapshot = token(seq, hash)
    after_id = params["after"]
    o = gate.orchestration

    with true <-
           Enum.all?(Map.keys(params), &(&1 in ~w(limit after snapshot principal role active))) or
             {:error, :unknown_filter},
         :ok <- authority_filters(params),
         {:ok, limit} <- limit(params["limit"]),
         :ok <- continue(after_id, params["snapshot"], snapshot) do
      selected =
        for {kind, id, a} <- State.authorities(o),
            {a.chapter_id, a.tenant_id, a.project_id} == scope,
            role = Map.fetch!(@roles, kind),
            one_of?(role, params["role"]),
            one_of?(to_string(a.active), params["active"]),
            params["principal"] == nil or params["principal"] in State.holders(a) do
          {id,
           %{
             authority_event_id: id,
             role: role,
             active: a.active,
             principal_id: a.principal_id,
             principal_kind: Projects.kind(o, chapter, a.principal_id),
             key_id: a[:key_id],
             delegator_principal_id: a[:delegator_principal_id],
             task_id: a[:task_id]
           }}
        end
        |> Enum.sort_by(&elem(&1, 0))

      {rows, continuation} = window(selected, after_id, limit)

      {:ok,
       %{
         authorities: Enum.map(rows, &elem(&1, 1)),
         total: length(selected),
         snapshot: snapshot,
         next_after: continuation
       }}
    end
  end

  defp authority_filters(params) do
    principal = params["principal"]

    if (is_nil(principal) or (is_binary(principal) and byte_size(principal) in 1..256)) and
         params["role"] in [nil | Map.values(@roles)] and
         params["active"] in [nil, "true", "false"],
       do: :ok,
       else: {:error, :invalid_filter}
  end

  @doc "Projects readable by the authenticated principal, with stable scoped IDs."
  def projects({gate, {seq, hash}}, principal, params) do
    snapshot = token(seq, hash)
    after_id = params["after"]
    o = gate.orchestration

    with true <-
           Enum.all?(Map.keys(params), &(&1 in ~w(limit after snapshot))) or
             {:error, :unknown_filter},
         {:ok, limit} <- limit(params["limit"]),
         :ok <- continue(after_id, params["snapshot"], snapshot) do
      scopes =
        for {_, _, grant} <- State.authorities(o),
            grant.active,
            do: {grant.chapter_id, grant.tenant_id, grant.project_id}

      selected =
        for {chapter, tenant, project} = scope <-
              Enum.uniq(scopes ++ Map.keys(o.projects) ++ Map.keys(o.hierarchy)),
            readable?(gate, principal, scope) do
          id = "#{chapter}/#{tenant}/#{project}"

          {id,
           %{
             chapter_id: chapter,
             tenant_id: tenant,
             project_id: project,
             name: get_in(o, [:hierarchy, scope, :name])
           }}
        end
        |> Enum.sort_by(&elem(&1, 0))

      {rows, continuation} = window(selected, after_id, limit)

      {:ok,
       %{
         projects: Enum.map(rows, &elem(&1, 1)),
         total: length(selected),
         snapshot: snapshot,
         next_after: continuation
       }}
    end
  end

  defp readable?(gate, principal, scope) do
    case Access.for_principal(gate.orchestration, principal, scope) do
      {:ok, _} -> true
      {:error, :no_grant} -> match?({:ok, _}, Access.for_administrator(gate, principal, scope))
    end
  end

  defp token(seq, hash), do: "#{seq}-#{Base.url_encode64(hash || "", padding: false)}"

  defp window(sorted, after_id, limit) do
    page =
      sorted
      |> Enum.drop_while(fn {id, _} -> after_id != nil and id <= after_id end)
      |> Enum.take(limit + 1)

    rows = Enum.take(page, limit)
    {rows, if(length(page) > limit, do: rows |> List.last() |> elem(0))}
  end

  defp limit(nil), do: {:ok, @default_limit}

  defp limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..@max_limit -> {:ok, n}
      _ -> {:error, :invalid_limit}
    end
  end

  defp limit(_), do: {:error, :invalid_limit}

  defp filter_values(params) do
    state = params["state"]
    open = params["open"]

    if (state == nil or match?({:ok, _}, TaskLifecycle.parse(state))) and
         (open == nil or (open == "true" and state == nil)) and
         Enum.all?(~w(roadmap workflow text), fn field ->
           params[field] == nil or
             (is_binary(params[field]) and byte_size(params[field]) in 1..256)
         end),
       do: :ok,
       else: {:error, :invalid_filter}
  end

  defp continue(nil, nil, _snapshot), do: :ok
  defp continue(id, snapshot, snapshot) when is_binary(id) and id != "", do: :ok

  defp continue(id, previous, _) when is_binary(id) and is_binary(previous),
    do: {:error, :stale_snapshot}

  defp continue(_, _, _), do: {:error, :invalid_cursor}

  defp matches?(task, params) do
    one_of?(task.state, params["state"]) and
      (params["open"] == nil or open?(task.state)) and
      one_of?(get_in(task, [:blueprint, :roadmap_key]), params["roadmap"]) and
      one_of?(get_in(task, [:blueprint, :workflow_id]), params["workflow"]) and
      (params["text"] == nil or
         String.contains?(String.downcase(task.title || ""), String.downcase(params["text"])))
  end

  defp open?(state) do
    case TaskLifecycle.parse(state) do
      {:ok, value} -> not TaskLifecycle.terminal?(value)
      _ -> false
    end
  end

  defp one_of?(_, nil), do: true
  defp one_of?(actual, expected), do: actual == expected
end
