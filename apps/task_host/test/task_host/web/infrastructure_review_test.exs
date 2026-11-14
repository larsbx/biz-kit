defmodule TaskHost.Web.InfrastructureReviewTest do
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.Log

  @path "/operations/workspaces/biz-kit/infrastructure-review"
  @manifest Path.expand("../../fixtures/keel-polyglot.manifest.toml", __DIR__)
  @commit String.duplicate("a", 40)
  @tree String.duplicate("b", 40)
  @bundle String.duplicate("c", 64)

  setup do
    providers!()

    for key <- [:operations, :keel_review_manifest] do
      old = Application.fetch_env(:task_host, key)

      on_exit(fn ->
        case old do
          {:ok, value} -> Application.put_env(:task_host, key, value)
          :error -> Application.delete_env(:task_host, key)
        end
      end)
    end

    world = world()
    reviewer = Principal.new_id()
    outsider = Principal.new_id()
    grant = grant!(world, "TaskReviewerGrantedV1", member("reviewer"), reviewer, "project-1")

    bind([
      {"https://idp.test", "reviewer", reviewer},
      {"https://idp.test", "outsider", outsider}
    ])

    Application.put_env(:task_host, :operations, %{
      "schema_version" => 1,
      "workspaces" => [
        %{
          "id" => "biz-kit",
          "label" => "Biz-kit",
          "chapter_id" => world.chapter,
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "infrastructure_review" => %{
            "origin" => "https://ship.example.test",
            "key" => "fixture",
            "record" => %{
              "repository" => "larsbx/biz-kit",
              "destination" => "fixture",
              "verifier" => String.duplicate("d", 40),
              "report" => %{
                "commit" => @commit,
                "tree" => @tree,
                "bundle_sha256" => @bundle,
                "status" => "integrity-only; receipt remains unsigned and unauthenticated"
              }
            }
          }
        }
      ]
    })

    Application.put_env(:task_host, :keel_review_manifest, @manifest)

    %{
      world: world,
      grant: grant,
      reviewer: [{"cookie", session!("second", "reviewer")}],
      outsider: [{"cookie", session!("second", "outsider")}]
    }
  end

  test "authorized navigation binds the configured revision and exposes no approval", ctx do
    head = Log.head()
    conn = call(:get, @path <> "?commit=other&evidence=other&approved=true", ctx.reviewer)
    assert conn.status == 200
    assert conn.resp_body =~ @commit
    assert conn.resp_body =~ @tree
    assert conn.resp_body =~ @bundle

    assert conn.resp_body =~
             "https://ship.example.test/graft/fixture/source?evidence=c9bd566eb69304a9576261edba3375925c5bf565d9e135780b9d18b69b817d30"

    assert conn.resp_body =~ "3a5f16476e8f0f5ed3290fa5c61b1d7be1b0badd"
    assert conn.resp_body =~ "Pure executable semantics and vector generation"
    assert conn.resp_body =~ "No approval is established"
    assert conn.resp_body =~ "No execution is performed"
    refute conn.resp_body =~ "<form"
    refute conn.resp_body =~ "approved=true"
    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["no-store"]
    assert Plug.Conn.get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    assert Log.head() == head

    snapshot = call(:get, "/api/v1/operations", ctx.reviewer)

    assert [%{"has_infrastructure_review" => true}] =
             Jason.decode!(snapshot.resp_body)["workspaces"]

    refute snapshot.resp_body =~ "ship.example.test"
  end

  test "anonymous, ungranted and revoked viewers receive no evidence", ctx do
    assert call(:get, @path, []).status == 401

    conn = call(:get, @path, ctx.outsider)
    assert conn.status == 404
    refute conn.resp_body =~ @commit

    revoke!(ctx.world, "TaskReviewerRevokedV1", ctx.grant)
    assert call(:get, @path, ctx.reviewer).status == 404
  end

  @tag :tmp_dir
  test "unavailable and incompatible manifests omit roles while keeping the Ship link", ctx do
    manifest = Path.join(ctx.tmp_dir, "keel.toml")
    Application.put_env(:task_host, :keel_review_manifest, manifest)

    for contents <- [nil, String.replace(File.read!(@manifest), "version = 1", "version = 2")] do
      if contents, do: File.write!(manifest, contents)
      conn = call(:get, @path, ctx.reviewer)
      assert conn.status == 200
      assert conn.resp_body =~ "manifest is unavailable or incompatible"
      assert conn.resp_body =~ "Open exact fixture review in Ship"
      refute conn.resp_body =~ "Pure executable semantics"
    end
  end
end
