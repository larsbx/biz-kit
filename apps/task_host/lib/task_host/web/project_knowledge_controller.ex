defmodule TaskHost.Web.ProjectKnowledgeController do
  @moduledoc """
  Project-scoped knowledge drafts and governance-signed reviews.

  Reads require a current session and the exact project's feed or administrator
  grant. Governance-signed review requests also work from a CLI. When a browser
  session is supplied it must belong to that governance key, and the held review
  remains bound to that same session through submission. No evidence bodies are
  loaded or returned, and reading a draft never records a review.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn
  import TaskHost.Web.Requests, only: [json_body: 1, bytes: 1, held: 2, appended: 2]

  alias BizKit.Identity
  alias BizKit.Identity.Sessions
  alias CoopSubstrate.{Knowledge, Log}
  alias CoopSubstrate.Feed.Access
  alias CoopSubstrate.Governance.{Authorization, Read}
  alias TaskCore.Knowledge, as: Core
  alias TaskHost.ProjectKnowledgeSuggestions
  alias TaskHost.Web.{AuthController, Requests}

  @statuses ~w(pending approved rejected withdrawn stale)
  @shown ~w(expected_review_version generator_version source_fingerprint draft_digest snapshot)
  @review_fields @shown ++ ~w(governance_key_id decision reason)
  @fresh_fields ~w(id status current source_fingerprint draft_digest review_version)
  @segment ~r/\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/

  def index(conn, params) do
    conn = private_response(conn)

    with {:ok, scope} <- scope(params),
         {:ok, principal, session, _reader, gate} <- reader(conn, scope),
         conn = fetch_query_params(conn),
         {:ok, options} <- list_options(conn.query_params),
         candidates = Core.candidates(gate.orchestration, scope),
         selected = filter_status(candidates, options.status),
         counts = Core.counts(gate.orchestration, scope),
         {:ok, latest} <- fresh_gate(principal, session, scope),
         true <-
           candidate_versions(candidates) ===
             candidate_versions(Core.candidates(latest.orchestration, scope)) or
             {:error, :stale_knowledge_preview} do
      json(
        conn,
        envelope(scope, principal)
        |> Map.merge(%{
          "items" => Enum.slice(selected, options.offset, options.limit),
          "counts" => counts,
          "total" => length(selected),
          "offset" => options.offset,
          "limit" => options.limit
        })
      )
    else
      error -> refuse(conn, error)
    end
  end

  def show(conn, %{"candidate_id" => id} = params) do
    conn = private_response(conn)

    with {:ok, scope} <- scope(params),
         {:ok, principal, session, _reader, gate} <- reader(conn, scope),
         :ok <- identifier(id),
         {:ok, candidate} <- Core.candidate(gate.orchestration, scope, id),
         available = Core.verify_availability(gate.orchestration, candidate) == :ok,
         {:ok, latest} <- fresh_gate(principal, session, scope),
         :ok <- candidates_current(latest.orchestration, scope, [candidate]) do
      json(
        conn,
        Map.put(
          envelope(scope, principal),
          "candidate",
          Map.put(candidate, "source_available", available)
        )
      )
    else
      error -> refuse(conn, error)
    end
  end

  def suggestions(conn, params) do
    conn = private_response(conn)

    with {:ok, scope} <- scope(params),
         {:ok, principal, session, _reader, gate} <- reader(conn, scope),
         conn = fetch_query_params(conn),
         {:ok, result} <-
           ProjectKnowledgeSuggestions.select(gate.orchestration, scope, conn.query_params),
         {:ok, latest} <- fresh_gate(principal, session, scope),
         :ok <- candidates_current(latest.orchestration, scope, result["items"]),
         true <-
           target(gate.orchestration, scope, conn.query_params) ===
             target(latest.orchestration, scope, conn.query_params) or
             {:error, :stale_knowledge_preview} do
      json(conn, Map.merge(envelope(scope, principal), result))
    else
      error -> refuse(conn, error)
    end
  end

  def prepare(conn, %{"candidate_id" => id} = params) do
    conn = private_response(conn)

    with {:ok, scope} <- scope(params),
         :ok <- identifier(id),
         {:ok, body} <- json_body(conn),
         :ok <- review_request(body),
         :ok <- governing(conn, scope, body["governance_key_id"]),
         {:ok, binding} <- session_binding(conn),
         :ok <- current_binding(scope, binding, body["governance_key_id"]),
         {:ok, pending} <-
           Knowledge.prepare(
             scope,
             id,
             body["decision"],
             body["reason"],
             Map.take(body, @shown),
             body["governance_key_id"],
             binding
           ),
         :ok <- current_binding(scope, binding, body["governance_key_id"]) do
      held(conn, pending)
    else
      error -> refuse(conn, error)
    end
  end

  def submit(conn, %{"candidate_id" => id, "held_id" => held_id} = params) do
    conn = private_response(conn)

    with {:ok, scope} <- scope(params),
         :ok <- identifier(id),
         {:ok, body} <- json_body(conn),
         true <- Map.keys(body) == ["signature"] or {:error, :bad_request},
         {:ok, signature} <- bytes(body["signature"]),
         {:ok, binding} <- session_binding(conn),
         {:ok, key_id} <- Knowledge.signer(scope, id, held_id, binding),
         :ok <- current_binding(scope, binding, key_id),
         {:ok, env} <-
           Knowledge.submit(scope, id, held_id, signature, binding,
             guard: {__MODULE__, :review_binding_current, [scope, binding, key_id]}
           ) do
      appended(conn, env)
    else
      error -> refuse(conn, error)
    end
  end

  defp reader(conn, scope) do
    with {:ok, principal, session} <- authenticate(conn),
         gate = Log.gate(),
         {:ok, reader} <- authorized(gate, principal, scope) do
      {:ok, principal, session, reader, gate}
    end
  end

  defp authorized(gate, principal, scope) do
    case Access.for_principal(gate.orchestration, principal, scope) do
      {:ok, reader} -> {:ok, reader}
      {:error, :no_grant} -> Access.for_administrator(gate, principal, scope)
    end
  end

  defp authenticate(conn) do
    case AuthController.principal(conn) do
      {:ok, principal, session} -> {:ok, principal, session}
      _ -> {:error, :unauthorized}
    end
  end

  defp fresh_gate(principal, session, scope) do
    with {:ok, %{principal: ^principal}} <- Identity.session(session),
         gate = Log.gate(),
         {:ok, _reader} <- authorized(gate, principal, scope) do
      {:ok, gate}
    else
      {:error, :no_grant} = error -> error
      _ -> {:error, :unauthorized}
    end
  end

  defp session_binding(conn) do
    case AuthController.principal(conn) do
      {:ok, principal, session} -> {:ok, {:session, principal, Sessions.reference(session)}}
      {:error, :no_credentials} -> {:ok, :cli}
      _ -> {:error, :unauthorized}
    end
  end

  defp current_binding(scope, binding, key_id),
    do: review_binding_current(Log.gate(), scope, binding, key_id)

  @doc false
  def review_binding_current(gate, scope, :cli, key_id),
    do: Knowledge.binding_current(gate, scope, :cli, key_id)

  # Called with the serialized appender's current gate. Identity's independent
  # session store is rechecked here without recursively calling the Log.
  def review_binding_current(gate, scope, {:session, principal, reference} = binding, key_id) do
    with {:ok, %{principal: ^principal}} <- Identity.session_from_reference(reference) do
      Knowledge.binding_current(gate, scope, binding, key_id)
    else
      _ -> {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :unauthorized}
  catch
    :exit, _ -> {:error, :unauthorized}
  end

  defp governing(conn, {chapter, _, _}, key_id) do
    with [header] <- get_req_header(conn, "authorization"),
         {:ok, %{key_id: ^key_id} = request, signature} <-
           Authorization.parse(header, conn.method, conn.request_path),
         {:ok, chapters} <- Read.authorize(request, signature),
         true <- chapter in chapters do
      :ok
    else
      _ -> {:error, :unauthorized}
    end
  end

  defp review_request(body) do
    if Enum.sort(Map.keys(body)) == Enum.sort(@review_fields) and
         body["decision"] in ~w(approve reject withdraw) and
         is_binary(body["reason"]) and byte_size(body["reason"]) <= 1_000 and
         is_binary(body["governance_key_id"]) and is_map(body["snapshot"]) and
         body["generator_version"] === 1 and is_integer(body["expected_review_version"]) and
         body["expected_review_version"] >= 0 and
         Enum.all?(~w(source_fingerprint draft_digest), &digest?(body[&1])),
       do: :ok,
       else: {:error, :bad_request}
  end

  defp list_options(params) do
    with true <- Enum.all?(Map.keys(params), &(&1 in ~w(status limit offset))),
         status = Map.get(params, "status"),
         true <- is_nil(status) or status in @statuses,
         {:ok, limit} <- bounded_integer(Map.get(params, "limit", "25"), 1, 100),
         {:ok, offset} <- bounded_integer(Map.get(params, "offset", "0"), 0, 10_000) do
      {:ok, %{status: status, limit: limit, offset: offset}}
    else
      _ -> {:error, :invalid_query}
    end
  end

  defp bounded_integer(value, minimum, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= minimum and number <= maximum -> {:ok, number}
      _ -> {:error, :invalid_query}
    end
  end

  defp bounded_integer(_, _, _), do: {:error, :invalid_query}
  defp filter_status(candidates, nil), do: candidates
  defp filter_status(candidates, status), do: Enum.filter(candidates, &(&1["status"] == status))

  defp candidates_current(state, scope, shown) do
    current = Map.new(Core.candidates(state, scope), &{&1["id"], Map.take(&1, @fresh_fields)})

    if Enum.all?(shown, fn candidate ->
         current[candidate["id"]] === Map.take(candidate, @fresh_fields)
       end), do: :ok, else: {:error, :stale_knowledge_preview}
  end

  defp candidate_versions(candidates), do: Enum.map(candidates, &Map.take(&1, @fresh_fields))

  defp target(state, {chapter, tenant, project}, %{"task_id" => id}),
    do: state.tasks[{chapter, tenant, project, id}]

  defp target(state, scope, %{"roadmap_key" => roadmap, "workflow_id" => workflow}),
    do: get_in(state.hierarchy, [scope, :roadmaps, roadmap, :workflows, workflow])

  defp scope(%{"chapter_id" => c, "tenant_id" => t, "project_id" => p}) do
    if Enum.all?([c, t, p], &(identifier(&1) == :ok)),
      do: {:ok, {c, t, p}},
      else: {:error, :bad_request}
  end

  defp identifier(value) when is_binary(value) do
    if Regex.match?(@segment, value), do: :ok, else: {:error, :bad_request}
  end

  defp identifier(_), do: {:error, :bad_request}
  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp envelope({chapter, tenant, project}, principal) do
    %{
      "schema_version" => 1,
      "scope" => %{"chapter_id" => chapter, "tenant_id" => tenant, "project_id" => project},
      "principal" => principal
    }
  end

  defp private_response(conn),
    do:
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header("vary", "Cookie, Authorization")

  defp refuse(conn, {:error, {:reject, _index, reason}}), do: refuse(conn, {:error, reason})
  defp refuse(conn, {:error, {:invalid, reason}}), do: refuse(conn, {:error, reason})

  defp refuse(conn, {:error, {:role_key_not_declared, "governance", _key_id}}),
    do: conn |> put_status(409) |> json(%{error: "governance_key_not_declared"})

  defp refuse(conn, {:error, reason}) when reason in [:unauthorized, :no_credentials],
    do: conn |> put_status(401) |> json(%{error: "unauthorized"})

  defp refuse(conn, {:error, reason}) when reason in [:no_grant, :needs_administrator],
    do: conn |> put_status(403) |> json(%{error: Atom.to_string(reason)})

  defp refuse(conn, {:error, reason})
       when reason in [
              :bad_request,
              :invalid_query,
              :invalid_knowledge_context,
              :invalid_knowledge_review
            ],
       do: conn |> put_status(400) |> json(%{error: Atom.to_string(reason)})

  defp refuse(conn, {:error, reason})
       when reason in [
              :unknown_knowledge_candidate,
              :unknown_task,
              :unknown_workflow,
              :unknown_project,
              :unknown_knowledge_context,
              :unknown_command
            ],
       do: conn |> put_status(404) |> json(%{error: Atom.to_string(reason)})

  defp refuse(conn, {:error, reason})
       when reason in [
              :stale_knowledge_preview,
              :knowledge_source_unavailable,
              :stale_knowledge_review,
              :knowledge_source_changed,
              :knowledge_draft_mismatch,
              :knowledge_already_reviewed,
              :knowledge_not_approved,
              :task_governance_not_declared
            ],
       do: conn |> put_status(409) |> json(%{error: Atom.to_string(reason)})

  defp refuse(conn, error), do: Requests.refuse(conn, error)
end
