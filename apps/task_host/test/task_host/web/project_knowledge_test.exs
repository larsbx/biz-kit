defmodule TaskHost.Web.ProjectKnowledgeTest do
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Knowledge, Log}
  alias CoopSubstrate.Governance.{Authorization, Client, Read}
  alias CoopSubstrate.Harness.Artifacts
  alias TaskCore.Knowledge, as: Core
  alias TaskHost.Web.ProjectKnowledgeController

  # Pause only the read-side artifact verification to interleave an actual
  # signed withdrawal/revocation. All domain state still comes from the Log.
  defmodule PausingHost do
    @behaviour TaskCore.Host
    def hash(term) do
      case :persistent_term.get({__MODULE__, :hash_pause}, nil) do
        observer when is_pid(observer) ->
          :persistent_term.erase({__MODULE__, :hash_pause})
          pause(observer)

        _ ->
          :ok
      end

      CoopSubstrate.TaskHost.hash(term)
    end

    defdelegate read_blueprint(digest), to: CoopSubstrate.TaskHost
    defdelegate read_catalogue(digest), to: CoopSubstrate.TaskHost

    def verify_artifact(digest, limit) do
      case :persistent_term.get({__MODULE__, :pause}, nil) do
        {^digest, observer} ->
          :persistent_term.erase({__MODULE__, :pause})
          pause(observer)

        _ ->
          :ok
      end

      CoopSubstrate.TaskHost.verify_artifact(digest, limit)
    end

    defp pause(observer) do
      send(observer, {:knowledge_read_paused, self()})

      receive do
        :resume_knowledge_read -> :ok
      after
        5_000 -> raise "knowledge read test did not resume"
      end
    end
  end

  setup do
    providers!()
    w = world()
    principal = Principal.new_id()
    admin = Principal.new_id()
    browser = member("governance")
    grant = grant!(w, "TaskOperatorGrantedV1", w.op, principal, "project-1")

    append!(
      event(w, w.gov, "RoleKeyDeclared", %{
        "role" => "governance",
        "key_id" => browser.signer.key_id,
        "pubkey" => {:bytes, browser.signer.pubkey},
        "member_id" => admin
      })
    )

    bind([{"https://idp.test", "reader", principal}, {"https://idp.test", "admin", admin}])

    artifact_dir = Path.join(System.tmp_dir!(), "project-knowledge-" <> w.chapter)
    previous = Application.get_env(:coop_substrate, :artifact_dir)
    Application.put_env(:coop_substrate, :artifact_dir, artifact_dir)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:coop_substrate, :artifact_dir, previous),
        else: Application.delete_env(:coop_substrate, :artifact_dir)

      File.rm_rf!(artifact_dir)
    end)

    revision = apply_blueprint!(w)
    [candidate] = Core.candidates(Log.gate().orchestration, {w.chapter, tenant(), "project-1"})

    Map.merge(w, %{
      principal: principal,
      admin: admin,
      browser: browser,
      reader_grant: grant,
      session: session!("second", "reader"),
      admin_session: session!("second", "admin"),
      base: serve!(),
      candidate_id: candidate["id"],
      revision: revision,
      artifact_dir: artifact_dir
    })
  end

  test "drafts appear from adopted facts without a write and remain scoped, bounded and private",
       w do
    before = Log.head()
    response = request(w, :get, path(w), cookie: w.session)
    assert response.status == 200
    assert response.body["scope"] == scope_map(w)
    assert response.body["principal"] == w.principal
    assert response.body["counts"]["pending"] == 1
    assert [%{"id" => id, "status" => "pending", "review_version" => 0}] = response.body["items"]
    assert id == w.candidate_id
    assert response.headers["cache-control"] == ["no-store"]

    detail = request(w, :get, candidate_path(w), cookie: w.session)
    assert detail.status == 200
    assert detail.body["candidate"]["source_available"]
    assert detail.body["candidate"]["kind"] == "adopted_workflow"
    assert Log.head() == before

    assert request(w, :get, path(w)).status == 401
    assert request(w, :get, path(w, "project-2"), cookie: w.session).status == 403
    assert request(w, :get, path(w) <> "?status=approved", cookie: w.session).body["items"] == []
    assert request(w, :get, path(w) <> "?offset=1&limit=1", cookie: w.session).body["items"] == []

    for query <- [
          "status=published",
          "limit=101",
          "offset=-1",
          "query=private",
          "status[]=pending"
        ] do
      assert request(w, :get, path(w) <> "?" <> query, cookie: w.session).status == 400
    end

    grant!(w, "TaskOperatorGrantedV1", w.op, w.principal, "project-2")
    foreign = request(w, :get, path(w, "project-2") <> "/" <> id, cookie: w.session)
    assert foreign.status == 404
    refute Map.has_key?(foreign.body, "candidate")
    assert request(w, :get, path(w, "project-2"), cookie: w.session).body["items"] == []
  end

  test "only reviewed current knowledge is suggested for an exact existing target", w do
    before = Log.head()
    suggestions = path(w) <> "/suggestions?roadmap_key=q4&workflow_id=release"
    assert request(w, :get, suggestions, cookie: w.session).body["items"] == []

    assert request(w, :get, path(w) <> "/suggestions?task_id=missing", cookie: w.session).status ==
             404

    assert request(w, :get, path(w) <> "/suggestions?query=release", cookie: w.session).status ==
             400

    assert Log.head() == before

    assert {:ok, %{"event_id" => event_id}} = review_cli(w, "approve")
    response = request(w, :get, suggestions, cookie: w.session)
    assert response.status == 200

    assert [%{"id" => id, "reason" => reason, "score" => score, "review" => review}] =
             response.body["items"]

    assert id == w.candidate_id
    assert is_binary(reason) and reason != ""
    assert is_integer(score) and score > 0
    assert review["event_id"] == event_id
    assert response.body["context"]["revision_event_id"] == w.revision.event_id
    assert response.body["scope"] == scope_map(w)

    assert {:ok, _} = review_cli(w, "withdraw")
    assert request(w, :get, suggestions, cookie: w.session).body["items"] == []
    assert request(w, :get, path(w) <> "?status=withdrawn", cookie: w.session).body["total"] == 1
  end

  test "the signer refuses a different scope or snapshot and an operator cannot review", w do
    payload = payload(w, "approve")
    before = Log.head()
    url = w.base <> reviews_path(w)
    body = params(payload)

    assert {:error, :not_what_was_shown} =
             Client.sign_held(
               url,
               governance(w),
               &Knowledge.expected?(&1, {w.chapter, tenant(), "project-2"}, payload),
               body
             )

    altered = put_in(payload["snapshot"]["title"], "Not the preview")

    assert {:error, :not_what_was_shown} =
             Client.sign_held(
               url,
               governance(w),
               &Knowledge.expected?(&1, scope(w), altered),
               body
             )

    operator =
      request(w, :post, reviews_path(w),
        cookie: w.session,
        signer: w.op,
        body: Map.put(body, "governance_key_id", w.op.signer.key_id)
      )

    assert operator.status == 401

    # Even a valid governance signature may not claim an unrelated browser session.
    not_admin =
      request(w, :post, reviews_path(w),
        cookie: w.session,
        signer: w.gov,
        body: Map.put(body, "governance_key_id", w.gov.signer.key_id)
      )

    assert not_admin.status == 403
    assert Log.head() == before
  end

  test "the browser signs and submits exactly its session-bound review", w do
    payload = payload(w, "approve")
    response = prepare_browser(w, payload)
    assert response.status == 201
    signature = sign_prepared(response.body, w.browser)
    submit_path = reviews_path(w) <> "/" <> response.body["id"]
    before = Log.head()

    assert request(w, :post, submit_path, body: %{"signature" => signature}).status == 404

    assert request(w, :post, submit_path, cookie: w.session, body: %{"signature" => signature}).status ==
             404

    assert Log.head() == before

    assert request(w, :post, submit_path,
             cookie: w.admin_session,
             body: %{"signature" => signature}
           ).status == 201

    assert candidate(w)["status"] == "approved"
    assert candidate(w)["review_version"] == 1

    assert request(w, :post, submit_path,
             cookie: w.admin_session,
             body: %{"signature" => signature}
           ).status == 404
  end

  test "logout revokes a held browser review, including at the serialized admission guard", w do
    prepared = prepare_browser(w, payload(w, "approve"))
    assert prepared.status == 201
    signature = sign_prepared(prepared.body, w.browser)
    before = Log.head()
    assert request(w, :post, "/auth/logout", cookie: w.admin_session).status == 204
    submit_path = reviews_path(w) <> "/" <> prepared.body["id"]

    assert request(w, :post, submit_path,
             cookie: w.admin_session,
             body: %{"signature" => signature}
           ).status == 401

    assert request(w, :post, submit_path, body: %{"signature" => signature}).status == 404

    session_id = String.replace_prefix(w.admin_session, "bizkit_session=", "")
    binding = {:session, w.admin, BizKit.Identity.Sessions.reference(session_id)}

    assert {:error, :unauthorized} =
             Knowledge.submit(
               scope(w),
               w.candidate_id,
               prepared.body["id"],
               Base.url_decode64!(signature, padding: false),
               binding,
               guard:
                 {ProjectKnowledgeController, :review_binding_current,
                  [scope(w), binding, w.browser.signer.key_id]}
             )

    assert Log.head() == before
    assert candidate(w)["status"] == "pending"
  end

  test "changed previews and source revisions cannot be approved by a stale signature", w do
    payload = payload(w, "approve")
    before = Log.head()
    altered = Map.put(params(payload), "draft_digest", String.duplicate("0", 64))

    response =
      request(w, :post, reviews_path(w),
        signer: w.gov,
        body: Map.put(altered, "governance_key_id", w.gov.signer.key_id)
      )

    assert response.status == 409
    assert response.body["error"] == "stale_knowledge_preview"
    assert Log.head() == before

    prepared =
      request(w, :post, reviews_path(w),
        signer: w.gov,
        body: Map.put(params(payload), "governance_key_id", w.gov.signer.key_id)
      )

    assert prepared.status == 201
    apply_new_revision!(w)
    after_revision = Log.head()

    response =
      request(w, :post, reviews_path(w) <> "/" <> prepared.body["id"],
        body: %{"signature" => sign_prepared(prepared.body, w.gov)}
      )

    assert response.status == 409
    assert response.body["error"] == "knowledge_source_changed"
    assert Log.head() == after_revision
    assert candidate(w)["status"] == "pending"
  end

  test "source deletion blocks approval and suggestions but permits rejection and withdrawal",
       w do
    assert {:ok, _} = review_cli(w, "approve")
    {:bytes, digest} = w.revision.payload["manifest_digest"]
    File.rm!(Path.join(w.artifact_dir, Base.encode16(digest, case: :lower)))
    detail = request(w, :get, candidate_path(w), cookie: w.session)
    assert detail.status == 200
    refute detail.body["candidate"]["source_available"]
    assert detail.body["candidate"]["review"]["decision"] == "approve"

    suggestions =
      request(w, :get, path(w) <> "/suggestions?roadmap_key=q4&workflow_id=release",
        cookie: w.session
      )

    assert suggestions.body["items"] == []
    assert {:ok, _} = review_cli(w, "withdraw")
    assert candidate(w)["status"] == "withdrawn"
    before = Log.head()
    assert {:error, {409, body}} = review_cli(w, "approve")
    assert body =~ "knowledge_source_unavailable"
    assert Log.head() == before

    apply_new_revision!(w)
    updated = candidate(w)
    File.rm!(Path.join(w.artifact_dir, updated["source"]["manifest_digest"]))
    assert {:ok, _} = review_cli(w, "reject")
    assert candidate(w)["status"] == "rejected"
  end

  test "revoking the governance key invalidates even an already signed script review", w do
    prepared =
      request(w, :post, reviews_path(w),
        signer: w.browser,
        body: Map.put(params(payload(w, "approve")), "governance_key_id", w.browser.signer.key_id)
      )

    assert prepared.status == 201

    append!(
      event(w, w.gov, "RoleKeyRevoked", %{
        "role" => "governance",
        "key_id" => w.browser.signer.key_id,
        "reason" => "Revoked before submission"
      })
    )

    before = Log.head()

    response =
      request(w, :post, reviews_path(w) <> "/" <> prepared.body["id"],
        body: %{"signature" => sign_prepared(prepared.body, w.browser)}
      )

    assert response.status == 409
    assert response.body["error"] == "governance_key_not_declared"
    assert Log.head() == before
    assert request(w, :get, path(w), cookie: w.admin_session).status == 403
  end

  test "lists, detail and recommendations refuse a withdrawal during selection", w do
    install_pausing_host!()

    index = path(w) <> "?status=approved"

    for url <- [
          index,
          candidate_path(w),
          path(w) <> "/suggestions?roadmap_key=q4&workflow_id=release"
        ] do
      assert {:ok, _} = review_cli(w, "approve")

      if url == index,
        do: :persistent_term.put({PausingHost, :hash_pause}, self()),
        else: pause_next_verification(w)

      read = Task.async(fn -> request(w, :get, url, cookie: w.session) end)
      assert_receive {:knowledge_read_paused, reader}, 2_000
      assert {:ok, _} = review_cli(w, "withdraw")
      send(reader, :resume_knowledge_read)
      response = Task.await(read)
      assert response.status == 409
      assert response.body == %{"error" => "stale_knowledge_preview"}
    end
  end

  test "revoking a reader during source verification releases no knowledge content", w do
    assert {:ok, _} = review_cli(w, "approve")
    install_pausing_host!()
    pause_next_verification(w)
    read = Task.async(fn -> request(w, :get, candidate_path(w), cookie: w.session) end)
    assert_receive {:knowledge_read_paused, reader}, 2_000
    revoke!(w, "TaskOperatorRevokedV1", w.reader_grant)
    send(reader, :resume_knowledge_read)
    response = Task.await(read)
    assert response.status == 403
    assert response.body == %{"error" => "no_grant"}
    assert response.headers["cache-control"] == ["no-store"]
  end

  defp candidate(w) do
    {:ok, result} = Core.candidate(Log.gate().orchestration, scope(w), w.candidate_id)
    result
  end

  defp payload(w, decision) do
    {:ok, result} =
      Core.review_payload(
        Log.gate().orchestration,
        scope(w),
        w.candidate_id,
        decision,
        "Reviewed the source-bound project knowledge"
      )

    result
  end

  defp params(payload),
    do: Map.merge(Knowledge.shown(payload), Map.take(payload, ~w(decision reason)))

  defp review_cli(w, decision) do
    payload = payload(w, decision)

    Client.sign_held(
      w.base <> reviews_path(w),
      governance(w),
      &Knowledge.expected?(&1, scope(w), payload),
      params(payload)
    )
  end

  defp prepare_browser(w, payload) do
    request(w, :post, reviews_path(w),
      cookie: w.admin_session,
      signer: w.browser,
      body: Map.put(params(payload), "governance_key_id", w.browser.signer.key_id)
    )
  end

  defp sign_prepared(prepared, signer),
    do:
      prepared["signing_bytes"]
      |> Base.url_decode64!(padding: false)
      |> Crypto.sign(signer.seed)
      |> Base.url_encode64(padding: false)

  defp request(w, method, path, opts \\ []) do
    headers = if opts[:cookie], do: [{"cookie", opts[:cookie]}], else: []

    headers =
      if opts[:signer],
        do: [{"authorization", authorization(method, path, opts[:signer])} | headers],
        else: headers

    options = [method: method, url: w.base <> path, headers: headers, retry: false]
    options = if opts[:body], do: Keyword.put(options, :json, opts[:body]), else: options
    Req.request!(options)
  end

  defp authorization(method, path, signer) do
    request = %{
      method: method |> Atom.to_string() |> String.upcase(),
      path: URI.parse(path).path,
      timestamp_ms: now(),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      key_id: signer.signer.key_id
    }

    Authorization.encode(request, Crypto.sign(Read.signing_bytes(request), signer.seed))
  end

  defp apply_new_revision!(w) do
    blueprint = put_in(w.revision.payload["blueprint"], ["project", "name"], "Updated project")
    bytes = Jason.encode!(blueprint)
    {:ok, digest} = Artifacts.put(bytes)

    append!(
      event(
        w,
        w.gov,
        "TaskBlueprintAppliedV1",
        w.revision.payload
        |> Map.put("blueprint", blueprint)
        |> Map.put("manifest_digest", {:bytes, digest})
        |> Map.put("commit", String.duplicate("c", 40))
        |> Map.put("tree", String.duplicate("d", 40))
      )
    )
  end

  defp install_pausing_host! do
    old = Log.gate().orchestration.host

    :sys.replace_state(GenServer.whereis(Log.server()), fn state ->
      put_in(state, [:gate, :orchestration, :host], PausingHost)
    end)

    on_exit(fn ->
      :persistent_term.erase({PausingHost, :pause})
      :persistent_term.erase({PausingHost, :hash_pause})

      :sys.replace_state(GenServer.whereis(Log.server()), fn state ->
        put_in(state, [:gate, :orchestration, :host], old)
      end)
    end)
  end

  defp pause_next_verification(w) do
    {:bytes, digest} = w.revision.payload["manifest_digest"]
    :persistent_term.put({PausingHost, :pause}, {digest, self()})
  end

  defp scope(w), do: {w.chapter, tenant(), "project-1"}

  defp scope_map(w),
    do: %{"chapter_id" => w.chapter, "tenant_id" => tenant(), "project_id" => "project-1"}

  defp path(w, project \\ "project-1"),
    do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/#{project}/knowledge"

  defp candidate_path(w), do: path(w) <> "/" <> w.candidate_id
  defp reviews_path(w), do: candidate_path(w) <> "/reviews"
end
