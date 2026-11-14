defmodule TaskHost.Web.KnowledgeTest do
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias BizOpsKB.Catalog
  alias CoopSubstrate.Log

  setup do
    providers!()
    previous = Application.fetch_env(:task_host, :operations)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:task_host, :operations, value)
        :error -> Application.delete_env(:task_host, :operations)
      end
    end)

    world = world()
    reader = Principal.new_id()
    outsider = Principal.new_id()
    grant = grant!(world, "TaskOperatorGrantedV1", member("operator"), reader, "project-1")

    bind([
      {"https://idp.test", "kb-reader", reader},
      {"https://idp.test", "kb-outsider", outsider}
    ])

    Application.put_env(:task_host, :operations, %{
      "schema_version" => 1,
      "title" => "Synthetic workspace",
      "workspaces" => [
        %{
          "id" => "kb-scope",
          "label" => "Synthetic project",
          "chapter_id" => world.chapter,
          "tenant_id" => tenant(),
          "project_id" => "project-1"
        }
      ]
    })

    {:ok, catalog} = Catalog.load()
    [document | _] = Catalog.search(catalog, limit: 1)["documents"]

    %{
      world: world,
      grant: grant,
      reader: reader,
      catalog: catalog,
      document: document,
      session: session!("second", "kb-reader"),
      outsider_session: session!("second", "kb-outsider")
    }
  end

  defp get(path, session), do: call(:get, path, [{"cookie", session}])
  defp body(conn), do: Jason.decode!(conn.resp_body)
  defp index, do: "/api/v1/operations/knowledge"
  defp detail(id), do: index() <> "/documents/" <> URI.encode(id, &URI.char_unreserved?/1)

  test "the static page contains no source corpus and anonymous API reads are refused", w do
    for path <- ["/operations/knowledge", "/app/knowledge.html"] do
      conn = call(:get, path, [])
      assert conn.status == 200
      assert conn.resp_body =~ "Procedures require separate workflow approval"
      refute conn.resp_body =~ w.document["path"]
    end

    for path <- [index(), detail(w.document["id"])],
        headers <- [[], [{"cookie", "bizkit_session=forged"}]] do
      conn = call(:get, path, headers)
      assert conn.status == 401
      assert body(conn) == %{"error" => "unauthorized"}
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "a session alone is insufficient and an empty Operations configuration does not grant access",
       w do
    assert get(index(), w.outsider_session).status == 403
    assert get(detail(w.document["id"]), w.outsider_session).status == 403
    Application.put_env(:task_host, :operations, TaskHost.Operations.default_config())
    assert body(get(index(), w.session)) == %{"error" => "workspace_access_required"}
  end

  test "current Operations readers browse a pinned nonauthoritative catalog without ledger writes",
       w do
    before = Log.head()
    conn = get(index(), w.session)
    assert conn.status == 200
    assert body(conn)["principal"] == w.reader
    assert body(conn)["catalog"] == Catalog.summary(w.catalog)
    assert body(conn)["catalog"]["read_only"]
    assert length(body(conn)["results"]["documents"]) <= 40
    refute conn.resp_body =~ "Synthetic project"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert Plug.Conn.get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert Log.head() == before
  end

  test "document reads preserve original bytes and source identity without an executable endpoint",
       w do
    before = Log.head()
    conn = get(detail(w.document["id"]), w.session)
    {:ok, expected} = Catalog.document(w.catalog, w.document["id"])
    assert conn.status == 200
    assert body(conn)["document"] == expected
    assert body(conn)["source"] == Catalog.summary(w.catalog)["source"]
    assert body(conn)["read_only"]
    assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert_raise Phoenix.Router.NoRouteError, fn ->
      call(:post, detail(w.document["id"]), [{"cookie", w.session}])
    end

    assert Log.head() == before
  end

  test "area/category search and pagination are applied before results are returned", w do
    options = [area: w.document["area"], category: w.document["category"], limit: 2, offset: 1]
    query = URI.encode_query(Map.new(options))
    conn = get(index() <> "?" <> query, w.session)
    assert conn.status == 200
    assert body(conn)["results"] == Catalog.search(w.catalog, options)

    assert get(index() <> "?query=no-such-document-xyz123", w.session)
           |> body()
           |> get_in(["results", "documents"]) == []
  end

  test "request scopes and filesystem paths cannot change the reader or document selection", w do
    conn =
      get(
        index() <> "?principal=forged&chapter_id=other&root=/tmp/private&path=../../mix.lock",
        w.session
      )

    assert conn.status == 200
    assert body(conn)["principal"] == w.reader
    assert body(conn)["catalog"] == Catalog.summary(w.catalog)

    for id <- ["missing-id", "..", "mix.lock", "source-manifest.json"] do
      response = get(detail(id), w.session)
      assert response.status == 404
      assert body(response) == %{"error" => "not_found"}
    end
  end

  test "malformed and oversized queries are rejected without widening results", w do
    for query <- [
          "query[]=bad",
          "query=" <> String.duplicate("x", 161),
          "offset=-1",
          "offset=1001",
          "limit=0",
          "limit=101",
          "area[]=bad",
          "category[]=bad"
        ] do
      conn = get(index() <> "?" <> query, w.session)
      assert conn.status == 400
      assert body(conn) == %{"error" => "invalid_query"}
    end
  end

  test "revoking the sole workspace grant removes catalog and document access", w do
    assert get(index(), w.session).status == 200
    revoke!(w.world, "TaskOperatorRevokedV1", w.grant)

    for path <- [index(), detail(w.document["id"])] do
      conn = get(path, w.session)
      assert conn.status == 403
      assert body(conn) == %{"error" => "workspace_access_required"}
      refute conn.resp_body =~ w.document["title"]
    end
  end

  test "logout and identity unbinding invalidate source reads", w do
    assert call(:post, "/auth/logout", [{"cookie", w.session}]).status == 204
    assert get(index(), w.session).status == 401
    assert get(detail(w.document["id"]), w.session).status == 401
    fresh = session!("second", "kb-reader")
    bind([])
    assert get(index(), fresh).status == 401
  end

  test "invalid Operations configuration fails closed without leaking configuration", w do
    Application.put_env(:task_host, :operations, %{"private" => "hidden-config"})
    conn = get(index(), w.session)
    assert conn.status == 503
    assert body(conn) == %{"error" => "operations_unavailable"}
    refute conn.resp_body =~ "hidden-config"
    assert call(:get, index(), []).status == 401
  end
end
