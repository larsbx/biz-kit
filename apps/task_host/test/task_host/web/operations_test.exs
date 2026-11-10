defmodule TaskHost.Web.OperationsTest do
  @moduledoc """
  The operations endpoint through the real task-host router and canonical
  ledger: authorization limits descriptors, data and counts to live grants.
  """
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.Log

  setup do
    providers!()
    old_config = Application.fetch_env(:task_host, :operations)

    on_exit(fn ->
      case old_config do
        {:ok, config} -> Application.put_env(:task_host, :operations, config)
        :error -> Application.delete_env(:task_host, :operations)
      end
    end)

    a = world()
    b = world()
    person_a = Principal.new_id()
    person_b = Principal.new_id()
    device_a = member("operator")
    device_b = member("operator")
    grant_a = grant!(a, "TaskOperatorGrantedV1", device_a, person_a, "project-1")
    grant_b = grant!(b, "TaskOperatorGrantedV1", device_b, person_b, "project-1")

    bind([
      {"https://idp.test", "operations-a", person_a},
      {"https://idp.test", "operations-b", person_b}
    ])

    create!(a, grant_a, "task-a", "project-1", device_a)
    create!(a, a.op_grant_2, "task-a-other", "project-2")
    create!(b, grant_b, "task-b-private", "project-1", device_b)

    Application.put_env(:task_host, :operations, %{
      "schema_version" => 1,
      "title" => "Operations",
      "time_zone" => "Etc/UTC",
      "workspaces" => [
        workspace("a", "Workspace A", a),
        workspace("a-other", "Another project", a, "project-2"),
        workspace("b", "Private workspace B", b)
      ]
    })

    %{
      a: a,
      b: b,
      person_a: person_a,
      person_b: person_b,
      grant_a: grant_a,
      grant_b: grant_b,
      session_a: session!("second", "operations-a"),
      session_b: session!("second", "operations-b")
    }
  end

  defp workspace(id, label, w, project \\ "project-1") do
    %{
      "id" => id,
      "label" => label,
      "category" => "general",
      "chapter_id" => w.chapter,
      "tenant_id" => tenant(),
      "project_id" => project
    }
  end

  defp get(session), do: call(:get, "/api/v1/operations", [{"cookie", session}])
  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "anonymous and forged sessions get no configuration or task data" do
    for headers <- [[], [{"cookie", "bizkit_session=forged"}]] do
      conn = call(:get, "/api/v1/operations", headers)
      assert conn.status == 401
      assert body(conn) == %{"error" => "unauthorized"}
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    end
  end

  test "two principals see only their exact project and chapter", w do
    head = Log.head()
    conn_a = get(w.session_a)
    conn_b = get(w.session_b)
    assert conn_a.status == 200
    assert conn_b.status == 200
    assert body(conn_a)["principal"] == w.person_a
    assert body(conn_b)["principal"] == w.person_b

    assert [a] = body(conn_a)["workspaces"]
    assert [b] = body(conn_b)["workspaces"]
    assert a["id"] == "a"
    assert b["id"] == "b"
    assert Map.keys(a["view"]["tasks"]) == ["task-a"]
    assert Map.keys(b["view"]["tasks"]) == ["task-b-private"]
    assert Enum.sort(Map.keys(a["view"])) == ~w(suggestions tasks workflows)

    for private <- [
          "Private workspace B",
          w.b.chapter,
          "task-b-private",
          "Another project",
          "task-a-other"
        ] do
      refute conn_a.resp_body =~ private
    end

    refute conn_b.resp_body =~ w.a.chapter
    refute conn_a.resp_body =~ "public_key"
    refute conn_a.resp_body =~ "pubkey"
    refute conn_a.resp_body =~ "receipt"
    assert Plug.Conn.get_resp_header(conn_a, "cache-control") == ["no-store"]
    assert Plug.Conn.get_resp_header(conn_a, "referrer-policy") == ["no-referrer"]
    assert Log.head() == head
  end

  test "an explicit grant in both chapters permits a combined view", w do
    grant!(w.b, "TaskReviewerGrantedV1", member("reviewer"), w.person_a, "project-1")
    conn = get(w.session_a)
    assert conn.status == 200
    assert Enum.map(body(conn)["workspaces"], & &1["id"]) == ["a", "b"]
  end

  test "revocation removes the descriptor and every record on the next read", w do
    assert [%{"id" => "a"}] = body(get(w.session_a))["workspaces"]
    revoke!(w.a, "TaskOperatorRevokedV1", w.grant_a)
    conn = get(w.session_a)

    assert conn.status == 200
    assert body(conn)["workspaces"] == []
    refute conn.resp_body =~ "task-a"
    refute conn.resp_body =~ w.a.chapter
    refute conn.resp_body =~ "Workspace A"
  end

  test "logout and identity unbinding invalidate reads despite unchanged ledger grants", w do
    assert call(:post, "/auth/logout", [{"cookie", w.session_a}]).status == 204
    assert get(w.session_a).status == 401
    assert get(w.session_b).status == 200

    bind([])
    assert get(w.session_b).status == 401
  end

  test "a declared chapter administrator sees its projects, never the other chapter", w do
    browser = member("governance")

    append!(
      event(w.a, w.a.gov, "RoleKeyDeclared", %{
        "role" => "governance",
        "key_id" => browser.signer.key_id,
        "pubkey" => {:bytes, browser.signer.pubkey},
        "member_id" => w.person_a
      })
    )

    assert Enum.map(body(get(w.session_a))["workspaces"], & &1["id"]) == ["a", "a-other"]

    append!(
      event(w.a, w.a.gov, "RoleKeyRevoked", %{
        "role" => "governance",
        "key_id" => browser.signer.key_id,
        "reason" => "End administrator access"
      })
    )

    assert Enum.map(body(get(w.session_a))["workspaces"], & &1["id"]) == ["a"]
  end

  test "query parameters cannot inject a scope, principal, or configuration", w do
    conn =
      call(
        :get,
        "/api/v1/operations?chapter_id=#{w.b.chapter}&principal=#{w.person_b}&config=/tmp/private",
        [
          {"cookie", w.session_a}
        ]
      )

    assert conn.status == 200
    assert body(conn)["principal"] == w.person_a
    assert [%{"id" => "a"}] = body(conn)["workspaces"]
    refute conn.resp_body =~ w.b.chapter
  end

  test "invalid configuration fails closed without echoing its contents", w do
    for bad <- [:invalid, %{"schema_version" => 2, "secret" => "secret-file-content"}] do
      Application.put_env(:task_host, :operations, bad)
      conn = get(w.session_a)
      assert conn.status == 503
      assert body(conn) == %{"error" => "operations_unavailable"}
      assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
      refute conn.resp_body =~ "secret-file-content"
      assert call(:get, "/api/v1/operations", []).status == 401
    end
  end
end
