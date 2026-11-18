defmodule TaskHost.Web.PluginBridgeTest do
  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2]
  import TaskHost.{IdentityFixtures, LedgerFixtures}
  alias BizKit.Identity.Principal
  alias CoopSubstrate.Log
  alias CoopSubstrate.Harness.Artifacts
  alias TaskCore.Knowledge
  alias TaskHost.PluginBridge.Auth
  alias TaskHost.PluginBridgeFixtures, as: Bridge

  @workspace "warehouse"
  @foreign "foreign"
  @operations "get_operations_view"
  @reference "search_business_knowledge"
  @knowledge "get_approved_task_knowledge"
  @evidence "get_task_evidence"
  @preview "preview_task_due_date"

  setup do
    providers!()
    w = world()
    principal = Principal.new_id()
    suggester = Principal.new_id()
    outsider = Principal.new_id()

    bind([
      {Bridge.issuer(), "reader", principal},
      {Bridge.issuer(), "suggester", suggester},
      {Bridge.issuer(), "outsider", outsider},
      {"https://idp.test", "browser", principal}
    ])

    grant = grant!(w, "TaskOperatorGrantedV1", w.op, principal, "project-1")
    grant!(w, "TaskSuggesterGrantedV1", w.agent, suggester, "project-1")
    task = create!(w, grant, "release", "project-1")
    create!(w, w.op_grant_2, "private-foreign-record", "project-2")

    previous = Application.get_env(:task_host, :operations)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:task_host, :operations, previous),
        else: Application.delete_env(:task_host, :operations)
    end)

    Application.put_env(:task_host, :operations, %{
      "schema_version" => 1,
      "workspaces" => [workspace(w, @workspace, "project-1"), workspace(w, @foreign, "project-2")]
    })

    Bridge.configure!()

    Bridge.introspect(fn
      "test-access" -> Bridge.claims()
      "suggest-access" -> Bridge.claims("suggester")
      "outsider-access" -> Bridge.claims("outsider")
      _ -> %{"active" => false}
    end)

    %{world: w, grant: grant, task: task, principal: principal}
  end

  test "disabled by default and exposes only static discovery and tools", w do
    config = Application.fetch_env!(:task_host, :plugin_bridge)
    Application.delete_env(:task_host, :plugin_bridge)
    assert Bridge.rpc("tools/list").status == 404
    assert Bridge.request(:get, Auth.metadata_path()).status == 404
    Application.put_env(:task_host, :plugin_bridge, %{config | workspace_ids: []})
    assert Bridge.rpc("tools/list").status == 404
    Application.put_env(:task_host, :plugin_bridge, config)

    metadata = Bridge.request(:get, Auth.metadata_path())
    assert metadata.status == 200

    assert Jason.decode!(metadata.resp_body) == %{
             "resource" => Bridge.resource(),
             "authorization_servers" => [Bridge.issuer()],
             "scopes_supported" => [Auth.scope()],
             "bearer_methods_supported" => ["header"]
           }

    refused = Bridge.rpc("tools/list", %{}, nil)
    assert refused.status == 401
    assert [challenge] = get_resp_header(refused, "www-authenticate")
    assert challenge =~ Auth.metadata_path()
    assert challenge =~ Auth.scope()
    assert Bridge.request(:get, "/mcp").status == 405

    origin = [{"origin", "https://untrusted.example.test"}]
    assert Bridge.rpc("tools/list", %{}, "test-access", origin).status == 403
    assert Bridge.request(:get, Auth.metadata_path(), origin).status == 403

    initialized = Bridge.rpc("initialize", %{protocolVersion: "2025-11-25"})

    assert %{
             "result" => %{
               "protocolVersion" => "2025-11-25",
               "capabilities" => %{"tools" => _},
               "serverInfo" => %{"name" => "biz-kit"}
             }
           } = Jason.decode!(initialized.resp_body)

    notification =
      Bridge.request(
        :post,
        "/mcp",
        [
          {"authorization", "Bearer test-access"},
          {"content-type", "application/json"}
        ],
        ~s({"jsonrpc":"2.0","method":"notifications/initialized"})
      )

    assert {notification.status, notification.resp_body} == {202, ""}

    listed = Bridge.rpc("tools/list")
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(listed.resp_body)

    assert Enum.map(tools, & &1["name"]) == [
             @operations,
             @reference,
             @knowledge,
             @evidence,
             @preview
           ]

    assert Enum.all?(tools, &(&1["annotations"]["readOnlyHint"] == true))

    assert Enum.all?(
             tools,
             &(&1["securitySchemes"] == [%{"type" => "oauth2", "scopes" => [Auth.scope()]}])
           )

    for method <- ~w(resources/list resources/read prompts/list) do
      assert %{"error" => %{"code" => -32601}} = Jason.decode!(Bridge.rpc(method).resp_body)
    end

    refute listed.resp_body =~ w.principal
    refute listed.resp_body =~ w.world.chapter
    refute metadata.resp_body =~ "private-foreign-record"
  end

  test "requires an audience-bound, current, scoped identity; cookies do not substitute" do
    assert Bridge.rpc("tools/list", %{}, "revoked").status == 401

    assert Bridge.rpc("tools/list", %{}, nil, [{"cookie", session!("second", "browser")}]).status ==
             401

    claims = Bridge.claims()

    for overrides <- [
          %{"active" => false},
          %{"iss" => "https://spoofed.example.test"},
          %{"aud" => "https://unrelated.example.test/mcp"},
          %{"exp" => 0},
          %{"nbf" => claims["exp"]},
          %{"token_type" => "refresh_token"},
          %{"sub" => "unbound"}
        ] do
      Bridge.introspect(fn _ -> Map.merge(claims, overrides) end)
      assert Bridge.rpc("tools/list").status == 401
    end

    Bridge.introspect(fn _ -> Map.put(claims, "scope", "bizkit.plugin.read.extra") end)
    response = Bridge.rpc("tools/list")
    assert response.status == 403
    assert [challenge] = get_resp_header(response, "www-authenticate")
    assert challenge =~ ~s(error="insufficient_scope")
  end

  test "an unavailable issuer fails closed" do
    Req.Test.stub(Bridge, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)
    response = Bridge.tool(@operations, args())
    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{"error" => "identity_unavailable"}
  end

  test "rejects malformed protocol, oversized requests and caller authority fields" do
    headers = [{"authorization", "Bearer test-access"}, {"content-type", "application/json"}]
    assert Bridge.request(:post, "/mcp", headers, "[]").status == 400
    assert Bridge.request(:post, "/mcp", headers, "{").status == 400
    assert Bridge.request(:post, "/mcp", headers, String.duplicate("x", 16_385)).status == 413

    for field <- ~w(principal_id grant_id chapter_id project_id tenant_id scope) do
      response = Bridge.tool(@operations, Map.put(args(), field, "spoofed"))
      assert %{"error" => %{"code" => -32602}} = Jason.decode!(response.resp_body)
    end

    unknown = Bridge.tool("submit_signed_command", args())
    assert %{"error" => %{"code" => -32602}} = Jason.decode!(unknown.resp_body)
  end

  test "operations and catalog reads return exact scoped source pins", w do
    assert %{"kind" => "operations_tasks", "tasks" => [task], "revision" => hash, "total" => 1} =
             Bridge.source(Bridge.tool(@operations, args()))

    assert task["last_event_id"] == w.task.event_id
    assert task["task_id"] == "release"
    assert byte_size(hash) == 64
    refute Map.has_key?(task, "description")

    assert %{"revision" => ^hash, "tasks" => [], "total" => 1} =
             Bridge.source(Bridge.tool(@operations, Map.put(args(), "offset", 1)))

    assert %{"kind" => "reference_catalog", "revision" => pin, "documents" => [document | _]} =
             Bridge.source(Bridge.tool(@reference, Map.put(args(), "query", "business")))

    assert byte_size(pin["revision"]) == 40
    assert byte_size(pin["tree"]) == 40
    assert byte_size(document["sha256"]) == 64

    for workspace <- [@foreign, "unconfigured"] do
      reply = Bridge.tool(@operations, %{"workspace_id" => workspace})
      assert Bridge.tool_error(reply) == "access_denied"
      refute reply.resp_body =~ "private-foreign-record"
    end

    assert Bridge.tool_error(Bridge.tool(@operations, args(), "outsider-access")) ==
             "access_denied"

    assert Bridge.tool_error(
             Bridge.tool(@reference, Map.put(args(), "query", ""), "outsider-access")
           ) ==
             "access_denied"
  end

  test "a readable workspace still needs explicit plugin approval", w do
    grant!(w.world, "TaskOperatorGrantedV1", w.world.op, w.principal, "project-2")
    foreign = %{"workspace_id" => @foreign}

    assert %{"tasks" => [%{"task_id" => "private-foreign-record"}]} =
             Bridge.source(Bridge.tool(@operations, foreign))

    config = Application.fetch_env!(:task_host, :plugin_bridge)
    Application.put_env(:task_host, :plugin_bridge, %{config | workspace_ids: [@workspace]})
    assert Bridge.tool_error(Bridge.tool(@operations, foreign)) == "access_denied"
  end

  test "only available, current approved knowledge is suggested", %{world: world} do
    root = Path.join(System.tmp_dir!(), world.chapter)
    previous = Application.get_env(:coop_substrate, :artifact_dir)
    Application.put_env(:coop_substrate, :artifact_dir, root)

    on_exit(fn ->
      Application.put_env(:coop_substrate, :artifact_dir, previous)
      File.rm_rf!(root)
    end)

    revision = apply_blueprint!(world)
    scope = {world.chapter, tenant(), "project-1"}

    [%{"id" => candidate, "status" => "pending"}] =
      Knowledge.candidates(Log.gate().orchestration, scope)

    input = Map.put(args(), "task_id", "release")

    assert %{"items" => []} = Bridge.source(Bridge.tool(@knowledge, input))
    approval = review!(world, scope, candidate, "approve")

    assert %{"items" => [item]} = Bridge.source(Bridge.tool(@knowledge, input))
    assert item["approval_event_id"] == approval.event_id
    assert item["source"]["revision_event_id"] == revision.event_id
    assert item["id"] == candidate
    refute Map.has_key?(item, "body")

    {:bytes, digest} = revision.payload["manifest_digest"]
    hex = Base.encode16(digest, case: :lower)
    assert {:ok, bytes} = Artifacts.get(digest)

    on_second_introspection(fn ->
      File.rm!(Path.join(root, hex))
      Bridge.claims()
    end)

    assert Bridge.tool_error(Bridge.tool(@knowledge, input)) == "stale_source"
    Bridge.introspect(fn _ -> Bridge.claims() end)
    assert %{"items" => []} = Bridge.source(Bridge.tool(@knowledge, input))

    assert {:ok, ^digest} = Artifacts.put(bytes)
    review!(world, scope, candidate, "withdraw")
    assert %{"items" => []} = Bridge.source(Bridge.tool(@knowledge, input))
  end

  test "evidence applies stricter ACL and previews are pinned and never committed", w do
    before = Log.head()
    evidence = Map.put(args(), "task_id", "release")
    assert Bridge.tool_error(Bridge.tool(@evidence, evidence)) == "no_current_submission"

    assert Bridge.tool_error(Bridge.tool(@evidence, evidence, "suggest-access")) ==
             "access_denied"

    due =
      Map.merge(evidence, %{
        "expected_source_event_id" => w.task.event_id,
        "due_ms" => 1_800_000_000_000
      })

    assert %{
             "kind" => "task_due_date_proposal",
             "status" => "unsigned_preview",
             "requires_human_review" => true,
             "task" => %{"source_event_id" => source},
             "expected_timing_version" => 1,
             "current_timing" => %{"due_ms" => nil},
             "proposed_timing" => %{"due_ms" => 1_800_000_000_000}
           } = preview = Bridge.source(Bridge.tool(@preview, due))

    assert source == w.task.event_id
    assert preview == Bridge.source(Bridge.tool(@preview, due))
    assert Bridge.tool_error(Bridge.tool(@preview, due, "suggest-access")) == "access_denied"

    assert Bridge.tool_error(
             Bridge.tool(@preview, Map.put(due, "expected_source_event_id", "old"))
           ) ==
             "stale_source"

    assert Log.head() == before
  end

  test "a token or its OAuth scope revoked mid-read prevents disclosure" do
    for {changed, status} <- [
          {%{"active" => false}, 401},
          {Map.put(Bridge.claims(), "scope", ""), 403}
        ] do
      on_second_introspection(fn -> changed end)
      response = Bridge.tool(@operations, args())
      assert response.status == status
      refute response.resp_body =~ "release"
    end
  end

  test "an identity unbound during the call cannot release the result" do
    on_second_introspection(fn ->
      bind([])
      Bridge.claims()
    end)

    response = Bridge.tool(@operations, args())
    assert response.status == 401
    refute response.resp_body =~ "release"
  end

  test "a project grant revoked during the call is checked before disclosure", w do
    on_second_introspection(fn ->
      revoke!(w.world, "TaskOperatorRevokedV1", w.grant)
      Bridge.claims()
    end)

    response = Bridge.tool(@operations, args())
    assert Bridge.tool_error(response) == "access_denied"
    refute response.resp_body =~ "release"
  end

  test "an intervening ledger revision causes an explicit retry", w do
    on_second_introspection(fn ->
      create!(w.world, w.grant, "new-record", "project-1")
      Bridge.claims()
    end)

    assert Bridge.tool_error(Bridge.tool(@operations, args())) == "stale_source"

    Bridge.introspect(fn _ -> Bridge.claims() end)
    assert %{"total" => 2} = Bridge.source(Bridge.tool(@operations, args()))
  end

  defp args, do: %{"workspace_id" => @workspace}

  defp workspace(w, id, project) do
    %{
      "id" => id,
      "label" => id,
      "chapter_id" => w.chapter,
      "tenant_id" => tenant(),
      "project_id" => project
    }
  end

  defp on_second_introspection(fun) do
    ref = make_ref()

    Bridge.introspect(fn _ ->
      if Process.get(ref) do
        fun.()
      else
        Process.put(ref, true)
        Bridge.claims()
      end
    end)
  end

  defp review!(world, scope, candidate, decision) do
    {:ok, payload} =
      Knowledge.review_payload(Log.gate().orchestration, scope, candidate, decision, "Reviewed")

    [event] = append!(event(world, world.gov, "KnowledgeCandidateReviewedV1", payload))
    event
  end
end
