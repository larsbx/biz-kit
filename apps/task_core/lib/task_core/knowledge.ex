defmodule TaskCore.Knowledge do
  @moduledoc """
  Project knowledge derived from retained, accepted task and workflow facts.

  Candidate generation reads only replay state. It does not copy evidence
  bodies, write a draft, publish to Git, or authorize execution. Governance
  reviews the exact generated snapshot through `KnowledgeCandidateReviewedV1`.
  Approval, rejection and withdrawal share an independently versioned aggregate.

  Read values use string keys and hexadecimal digests. Only the two top-level
  event digest fields use protocol byte strings. Replay retains the exact signed
  snapshot and never reads artifacts. Approval and live approved-item selection
  verify source availability through the existing host callback.
  """

  alias TaskCore.{Admission, Blueprint, State}

  @type_name "KnowledgeCandidateReviewedV1"
  @snapshot_fields ~w(generator_version kind title summary body source)
  @fields ~w(tenant_id project_id candidate_id expected_review_version generator_version
             source_fingerprint draft_digest snapshot decision reason)
  @statuses ~w(pending approved rejected withdrawn stale)
  @body_limit 16_384
  @id ~r/\A(?:task|workflow)-[0-9a-f]{64}\z/

  def init, do: %{knowledge_reviews: %{}}

  def event_types do
    %{
      @type_name => %{
        required_roles: ["governance"],
        disclosure_class: :edges,
        stream: {:payload_fields, "project_knowledge", ~w(tenant_id project_id candidate_id)},
        payload: %{
          required: %{
            "tenant_id" => :string,
            "project_id" => :string,
            "candidate_id" => :string,
            "expected_review_version" => :int,
            "generator_version" => :int,
            "source_fingerprint" => :hash,
            "draft_digest" => :hash,
            "snapshot" => :any,
            "decision" => :string,
            "reason" => :string
          },
          optional: %{}
        }
      }
    }
  end

  @doc "Current generated candidates and retained decisions, ordered by stable ID; no artifact reads."
  def candidates(state, {chapter, tenant, project} = scope) do
    generated = task_candidates(state, scope) ++ workflow_candidates(state, scope)
    current = Map.new(generated, &{&1["id"], &1})

    reviews =
      for {{^chapter, ^tenant, ^project, id}, review} <- Map.get(state, :knowledge_reviews, %{}),
          into: %{},
          do: {id, review}

    (Map.keys(current) ++ Map.keys(reviews))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn id -> decorate(id, current[id], reviews[id]) end)
  end

  @doc "A source-scoped candidate. IDs confer no authority."
  def candidate(state, scope, id) do
    case Enum.find(candidates(state, scope), &(&1["id"] == id)) do
      nil -> {:error, :unknown_knowledge_candidate}
      value -> {:ok, value}
    end
  end

  @doc "Decision/currentness counts; availability is checked separately, without changing historical status."
  def counts(state, scope) do
    Enum.reduce(candidates(state, scope), Map.new(@statuses, &{&1, 0}), fn item, counts ->
      Map.update!(counts, item["status"], &(&1 + 1))
    end)
  end

  @doc "Only current approved snapshots whose pinned source artifacts are available now."
  def approved(state, scope) do
    Enum.filter(candidates(state, scope), fn candidate ->
      candidate["current"] and candidate["status"] == "approved" and
        verify_availability(state, candidate) == :ok
    end)
  end

  @doc "Build the exact payload to review; the host must compare the caller's shown pins before holding it."
  def review_payload(state, {_chapter, tenant, project} = scope, id, decision, reason) do
    with true <- decision in ~w(approve reject withdraw) or {:error, :invalid_knowledge_review},
         true <- text?(reason, 2_048) or {:error, :invalid_knowledge_review},
         {:ok, candidate} <- candidate(state, scope, id),
         {:ok, basis} <- review_basis(candidate, decision) do
      {:ok,
       %{
         "tenant_id" => tenant,
         "project_id" => project,
         "candidate_id" => id,
         "expected_review_version" => candidate["review_version"],
         "generator_version" => 1,
         "source_fingerprint" => bytes(basis["source_fingerprint"]),
         "draft_digest" => bytes(basis["draft_digest"]),
         "snapshot" => Map.take(basis, @snapshot_fields),
         "decision" => decision,
         "reason" => reason
       }}
    end
  end

  @doc false
  def check(%{type: @type_name, payload: p} = env, state, keys) do
    with :ok <- Admission.governance_declared(env, keys),
         :ok <- valid_payload(p),
         {:ok, candidate} <- candidate(state, State.scope(env), p["candidate_id"]),
         true <-
           candidate["review_version"] == p["expected_review_version"] or
             {:error, :stale_knowledge_review},
         {:ok, basis} <- review_basis(candidate, p["decision"]),
         true <-
           bytes(basis["source_fingerprint"]) == p["source_fingerprint"] or
             {:error, :knowledge_source_changed},
         true <-
           (bytes(basis["draft_digest"]) == p["draft_digest"] and
              Map.take(basis, @snapshot_fields) === p["snapshot"]) or
             {:error, :knowledge_draft_mismatch},
         :ok <- approval_availability(state, candidate, p["decision"]),
         do: :ok
  end

  defp valid_payload(p) do
    snapshot = p["snapshot"]

    valid =
      Enum.sort(Map.keys(p)) == Enum.sort(@fields) and p["generator_version"] === 1 and
        is_binary(p["candidate_id"]) and byte_size(p["candidate_id"]) <= 80 and
        Regex.match?(@id, p["candidate_id"]) and
        is_integer(p["expected_review_version"]) and p["expected_review_version"] >= 0 and
        p["expected_review_version"] < 9_223_372_036_854_775_807 and
        p["decision"] in ~w(approve reject withdraw) and text?(p["reason"], 2_048) and
        match?({:bytes, <<_::256>>}, p["source_fingerprint"]) and
        match?({:bytes, <<_::256>>}, p["draft_digest"]) and is_map(snapshot) and
        Enum.sort(Map.keys(snapshot)) == Enum.sort(@snapshot_fields) and
        snapshot["generator_version"] === 1 and
        snapshot["kind"] in ~w(completed_task adopted_workflow) and
        text?(snapshot["title"], 300) and text?(snapshot["summary"], 600) and
        text?(snapshot["body"], @body_limit) and is_map(snapshot["source"]) and
        map_size(snapshot["source"]) <= 20

    if valid, do: :ok, else: {:error, :invalid_knowledge_review}
  end

  defp review_basis(%{"review" => %{"decision" => "approve"} = review}, "withdraw") do
    {:ok,
     Map.merge(
       review["snapshot"],
       Map.take(review, ~w(source_fingerprint draft_digest))
     )}
  end

  defp review_basis(_candidate, "withdraw"), do: {:error, :knowledge_not_approved}

  defp review_basis(%{"current" => false}, _decision),
    do: {:error, :knowledge_source_changed}

  defp review_basis(%{"status" => status} = candidate, "approve")
       when status in ~w(rejected withdrawn),
       do: {:ok, candidate}

  defp review_basis(%{"status" => "pending"} = candidate, _decision), do: {:ok, candidate}
  defp review_basis(_candidate, _decision), do: {:error, :knowledge_already_reviewed}

  defp approval_availability(state, candidate, "approve"),
    do: verify_availability(state, candidate)

  defp approval_availability(_state, _candidate, _decision), do: :ok

  @doc "Verify artifacts for an authorized canonical candidate, without reading or returning their bodies."
  def verify_availability(state, %{"kind" => "completed_task", "source" => source}) do
    scope = source["scope"]
    evidence = source["evidence"]
    receipts = source["custody_receipts"]

    if is_map(scope) and is_map(evidence) and map_size(evidence) in 1..32 and
         is_map(receipts) and Enum.sort(Map.keys(evidence)) == Enum.sort(Map.keys(receipts)) do
      evidence
      |> Enum.reduce_while({:ok, 16 * 1024 * 1024}, fn {criterion, digest}, {:ok, budget} ->
        with %{digest: {:bytes, raw}} = receipt <- state.custody_receipts[receipts[criterion]],
             true <-
               scope_map({receipt.chapter_id, receipt.tenant_id, receipt.project_id}) == scope,
             true <- hex(raw) == digest,
             {:ok, size} when is_integer(size) and size >= 0 and size <= budget <-
               state.host.verify_artifact(raw, min(budget, 8 * 1024 * 1024)) do
          {:cont, {:ok, budget - size}}
        else
          _ -> {:halt, {:error, :knowledge_source_unavailable}}
        end
      end)
      |> case do
        {:ok, _budget} -> :ok
        error -> error
      end
    else
      {:error, :knowledge_source_unavailable}
    end
  end

  def verify_availability(state, %{"kind" => "adopted_workflow", "source" => source}) do
    with digest when is_binary(digest) <- source["manifest_digest"],
         {:ok, <<_::256>> = raw} <- Base.decode16(digest, case: :lower),
         {:ok, size} when is_integer(size) and size >= 0 and size <= 1_048_576 <-
           state.host.verify_artifact(raw, 1_048_576),
         do: :ok,
         else: (_ -> {:error, :knowledge_source_unavailable})
  end

  def verify_availability(_state, _candidate), do: {:error, :knowledge_source_unavailable}

  @doc false
  def handle_event(%{type: @type_name, payload: p, signers: [signer]} = env, state) do
    review = %{
      "event_id" => env.event_id,
      "decision" => p["decision"],
      "reason" => p["reason"],
      "key_id" => signer.key_id,
      "version" => p["expected_review_version"] + 1,
      "source_fingerprint" => hex(elem(p["source_fingerprint"], 1)),
      "draft_digest" => hex(elem(p["draft_digest"], 1)),
      "snapshot" => p["snapshot"]
    }

    key = Tuple.insert_at(State.scope(env), 3, p["candidate_id"])
    put_in(state, [:knowledge_reviews, Access.key(key)], review)
  end

  def handle_event(_env, state), do: state

  defp task_candidates(state, {chapter, tenant, project} = scope) do
    # Timing commands can change last_event_id after completion. Pin the actual
    # accepted completion, whose review and lifecycle version still match.
    completions =
      for {_id, %{type: "TaskCompletedV1", chapter_id: ^chapter, payload: p} = env} <-
            state.dod_commands,
          p["tenant_id"] == tenant and p["project_id"] == project,
          into: %{},
          do: {{p["task_id"], p["expected_version"] + 1, p["review_event_id"]}, env.event_id}

    for {{^chapter, ^tenant, ^project, id}, %{state: "completed", dod: dod} = task} <- state.tasks,
        is_map(dod),
        %{event_id: submission_id, evidence: evidence, custody_receipts: receipts} <- [
          dod.submission
        ],
        %{event_id: review_id, decision: "accept", submission_event_id: ^submission_id} <- [
          dod.review
        ],
        is_map(evidence) and is_map(receipts) and map_size(evidence) in 1..32,
        Enum.sort(Map.keys(evidence)) == Enum.sort(Map.keys(receipts)),
        completion when is_binary(completion) <- [completions[{id, task.version, review_id}]] do
      blueprint =
        task
        |> Map.get(:blueprint, %{})
        |> Map.take(~w(revision_event_id roadmap_key workflow_id definition_id)a)
        |> strings()

      source = %{
        "scope" => scope_map(scope),
        "task_id" => id,
        "task_version" => task.version,
        "completion_event_id" => completion,
        "definition_event_id" => dod.event_id,
        "definition_ref" => strings(dod.definition_ref),
        "submission_event_id" => submission_id,
        "review_event_id" => review_id,
        "evidence" => strings(evidence),
        "custody_receipts" => receipts,
        "blueprint" => blueprint,
        "record_digest" =>
          digest(state, %{
            "title" => task.title,
            "description" => task.description,
            "criteria" => dod.criteria
          })
      }

      title = bounded(task.title || "Completed task #{id}", 300)
      summary = "Recorded completion with an accepted review of #{length(dod.criteria)} criteria."

      body =
        "Completed task: #{title}\n\n" <>
          (task.description || "") <>
          "\n\nAccepted completion criteria:\n" <>
          criteria_text(dod.criteria) <>
          "\n\nThis is a record of accepted work. Evidence remains in its project custody; this summary grants no execution authority."

      make(state, "task", id, "completed_task", title, summary, body, source)
    end
  end

  defp workflow_candidates(state, scope) do
    for {roadmap_key, roadmap} <- get_in(state, [:hierarchy, scope, :roadmaps]) || %{},
        {workflow_id, %{revision: revision_id}} <- roadmap.workflows,
        %{scope: ^scope, blueprint: blueprint, source: pins} = revision <- [
          state.blueprints[revision_id]
        ],
        {:ok, workflow} <- [Blueprint.workflow(blueprint, roadmap_key, workflow_id)] do
      source =
        pins
        |> Map.take(~w(repository commit tree path manifest_digest)a)
        |> strings()
        |> Map.merge(%{
          "scope" => scope_map(scope),
          "roadmap_key" => roadmap_key,
          "workflow_id" => workflow_id,
          "revision_event_id" => revision_id,
          "workflow_digest" => digest(state, workflow)
        })
        |> then(fn source ->
          case get_in(revision, [:readiness_contracts, {roadmap_key, workflow_id}]) do
            nil -> source
            contract -> Map.put(source, "readiness_contract", strings(contract))
          end
        end)

      title = workflow["name"]
      summary = "Adopted workflow with #{length(workflow["tasks"])} task definitions."

      body =
        "Adopted workflow: #{title}\n\n" <>
          Enum.map_join(workflow["tasks"], "\n\n", fn task ->
            "#{task["id"]}: #{task["title"]}\n" <>
              (task["description"] || "") <>
              "\nPredecessors: #{Enum.join(task["depends_on"], ", ")}\n" <>
              criteria_text(task["definition_of_done"])
          end) <>
          "\n\nThis describes an adopted template, not completed work. Run creation, readiness and execution remain separately authorized."

      make(
        state,
        "workflow",
        [roadmap_key, workflow_id],
        "adopted_workflow",
        title,
        summary,
        body,
        source
      )
    end
  end

  defp make(state, prefix, key, kind, title, summary, body, source) do
    snapshot = %{
      "generator_version" => 1,
      "kind" => kind,
      "title" => title,
      "summary" => summary,
      "body" => bounded(body, @body_limit),
      "source" => source
    }

    Map.merge(snapshot, %{
      "id" => prefix <> "-" <> digest(state, ["knowledge-id/1", source["scope"], kind, key]),
      "source_fingerprint" => digest(state, ["knowledge-source/1", kind, source]),
      "draft_digest" => digest(state, ["knowledge-draft/1", snapshot])
    })
  end

  defp decorate(id, nil, review) do
    review["snapshot"]
    |> Map.merge(Map.take(review, ~w(source_fingerprint draft_digest)))
    |> Map.merge(%{
      "id" => id,
      "current" => false,
      "status" => if(review["decision"] == "approve", do: "stale", else: status(review)),
      "review_version" => review["version"],
      "review" => review
    })
  end

  defp decorate(_id, candidate, review) do
    matches =
      not is_nil(review) and review["source_fingerprint"] == candidate["source_fingerprint"] and
        review["draft_digest"] == candidate["draft_digest"]

    Map.merge(candidate, %{
      "current" => true,
      "status" => if(matches, do: status(review), else: "pending"),
      "review_version" => if(review, do: review["version"], else: 0),
      "review" => review
    })
  end

  defp status(%{"decision" => "approve"}), do: "approved"
  defp status(%{"decision" => "reject"}), do: "rejected"
  defp status(%{"decision" => "withdraw"}), do: "withdrawn"

  defp criteria_text(criteria),
    do: Enum.map_join(criteria, "\n", &"- #{&1["id"]}: #{&1["description"]}")

  defp scope_map({chapter, tenant, project}),
    do: %{"chapter_id" => chapter, "tenant_id" => tenant, "project_id" => project}

  defp digest(state, term), do: state.host.hash(term) |> hex()
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
  defp bytes(hex), do: {:bytes, Base.decode16!(hex, case: :lower)}
  defp strings({:bytes, bytes}), do: hex(bytes)

  defp strings(%{} = value),
    do: Map.new(value, fn {key, value} -> {to_string(key), strings(value)} end)

  defp strings(values) when is_list(values), do: Enum.map(values, &strings/1)
  defp strings(value), do: value

  defp text?(value, limit),
    do:
      is_binary(value) and String.valid?(value) and byte_size(value) in 1..limit and
        String.trim(value) != ""

  defp bounded(value, limit) when byte_size(value) <= limit, do: value

  defp bounded(value, limit) do
    suffix = "\n[Excerpt truncated; inspect the pinned source for the full record.]"
    prefix = binary_part(value, 0, limit - byte_size(suffix))
    utf8_prefix(prefix) <> suffix
  end

  defp utf8_prefix(value) do
    if String.valid?(value),
      do: value,
      else: utf8_prefix(binary_part(value, 0, byte_size(value) - 1))
  end
end
