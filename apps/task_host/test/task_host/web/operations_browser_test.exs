defmodule TaskHost.Web.OperationsBrowserTest do
  @moduledoc """
  Real browser acceptance for the customizable operations read surface.

  The browser signs in through the existing identity endpoints and reads the
  real HTTP snapshot backed by signed ledger fixtures. No intercepted API or
  synthetic authorization route supplies the records. Separate chapters and
  principals exercise disclosure boundaries; the host revokes an actual grant
  between browser stages.

  Run with Node, Playwright and Chromium installed:
  `mix test test/task_host/web/operations_browser_test.exs --include browser`.
  """
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias BizKit.Identity.Providers.Development
  alias CoopSubstrate.Enrolments.Approver
  alias CoopSubstrate.Log

  @moduletag :browser
  @moduletag timeout: 180_000
  @script Path.expand("../../browser/operations.cjs", __DIR__)

  test "a development browser gains Operations access after signed administrator enrolment" do
    w = world()
    principal = Principal.new_id()
    base = serve!()
    development_provider!(base, principal)
    create_due!(w, "Synthetic bootstrap record", now() - 1_000)

    configure!(%{
      "schema_version" => 1,
      "title" => "Synthetic operations",
      "time_zone" => "Etc/UTC",
      "workspaces" => [workspace(w, "bootstrap-desk", "Bootstrap desk", "Synthetic")]
    })

    before = Log.head()
    assert {:error, {404, body}} = Approver.fetch(base, "ZZZZ-ZZZZ-ZZZZ")
    assert %{"error" => "unknown_code"} = Jason.decode!(body)

    port = browser!(base, w.chapter, "--bootstrap")
    assert %{"stage" => "bootstrap_pending", "code" => code} = read!(port)
    assert {:ok, details} = Approver.fetch(base, code)

    assert %{
             "chapter_id" => chapter,
             "tenant_id" => tenant_id,
             "project_id" => "project-1",
             "principal_id" => ^principal,
             "role" => "governance",
             "label" => "Synthetic bootstrap browser",
             "identity" => %{
               "issuer" => "biz-kit-development",
               "subject" => "synthetic-bootstrap"
             }
           } = details

    assert chapter == w.chapter
    assert tenant_id == tenant()
    assert Log.head() == before
    Port.command(port, "inspected\n")
    assert %{"stage" => "bootstrap_still_pending"} = read!(port)
    assert Log.head() == before

    assert {:ok, %{"event_id" => _}} = Approver.approve(base, details, governance(w))
    approved = Log.head()
    assert approved != before
    Port.command(port, "approved\n")
    assert %{"stage" => "bootstrap_approved"} = read!(port)
    assert Log.head() == approved
    assert_exit!(port)
  end

  test "custom workspaces retain scope, refuse private records and clear revoked reads" do
    providers!()
    first = world()
    second = world()
    full = Principal.new_id()
    restricted = Principal.new_id()

    bind([
      {"https://idp.test", "sub-operations-full", full},
      {"https://idp.test", "sub-operations-restricted", restricted}
    ])

    grant!(first, "TaskOperatorGrantedV1", member("operator"), full, "project-1")

    second_grant =
      grant!(second, "TaskOperatorGrantedV1", member("operator"), full, "project-1")

    grant!(first, "TaskOperatorGrantedV1", member("operator"), restricted, "project-1")

    # Both scope and task identifiers matter: the same task ID intentionally
    # appears in different chapters, with different titles and disclosure.
    due = now() - 1_000
    create_due!(first, "Review <b>A</b> record", due)
    create_due!(second, "Private B record", due)

    configure!(%{
      "schema_version" => 1,
      "title" => "Custom desk",
      "time_zone" => "Etc/UTC",
      "workspaces" => [
        workspace(first, "workspace-a", "Custom <A> desk", "Alpha / any-work"),
        workspace(second, "workspace-b", "Private B desk", "Beta / confidential")
      ]
    })

    port = browser!(serve!(), first.chapter, second.chapter)
    head = Log.head()
    assert %{"stage" => "authorized_views"} = read!(port)
    assert Log.head() == head

    revoke!(second, "TaskOperatorRevokedV1", second_grant)
    revoked_head = Log.head()
    Port.command(port, "revoked\n")

    assert %{"stage" => "revocation_and_logout"} = read!(port)
    assert Log.head() == revoked_head
    assert_exit!(port)
  end

  defp workspace(w, id, label, category) do
    %{
      "id" => id,
      "label" => label,
      "category" => category,
      "chapter_id" => w.chapter,
      "tenant_id" => tenant(),
      "project_id" => "project-1"
    }
  end

  defp development_provider!(base, principal) do
    for {app, key, value} <- [
          {:biz_kit_identity, :allow_development_provider, true},
          {:biz_kit_identity, :providers,
           %{"bootstrap" => {Development, subject: "synthetic-bootstrap"}}},
          {:task_host, :public_url, base},
          {:task_host, :after_login_path, "/app"}
        ] do
      previous = Application.fetch_env(app, key)
      Application.put_env(app, key, value)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end)
    end

    previous = Application.fetch_env(:biz_kit_identity, :bindings)
    bind([{"biz-kit-development", "synthetic-bootstrap", principal}])

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:biz_kit_identity, :bindings, value)
        :error -> Application.delete_env(:biz_kit_identity, :bindings)
      end
    end)
  end

  defp create_due!(w, title, due) do
    append!(
      event(w, w.op, "TaskCreatedV1", %{
        "tenant_id" => tenant(),
        "project_id" => "project-1",
        "principal_id" => w.op_grant.payload["principal_id"],
        "authorization_event_id" => w.op_grant.event_id,
        "lifecycle_version" => 1,
        "task_id" => "shared-task",
        "title" => title,
        "timing" => %{"schedule" => nil, "due_ms" => due}
      })
    )
  end

  defp configure!(config) do
    previous = Application.fetch_env(:task_host, :operations)
    Application.put_env(:task_host, :operations, config)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:task_host, :operations, value)
        :error -> Application.delete_env(:task_host, :operations)
      end
    end)
  end

  defp browser!(base, first_chapter, second_chapter) do
    node = System.find_executable("node") || flunk("node is required")

    global =
      case System.find_executable("npm") do
        nil -> nil
        npm -> System.cmd(npm, ["root", "-g"]) |> elem(0) |> String.trim()
      end

    separator = if match?({:win32, _}, :os.type()), do: ";", else: ":"

    node_path =
      [System.get_env("NODE_PATH"), global]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.join(separator)

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        {:line, 1_000_000},
        {:env, [{~c"NODE_PATH", String.to_charlist(node_path)}]},
        args: [@script, base, first_chapter, second_chapter, tenant()]
      ])

    on_exit(fn -> if Port.info(port), do: Port.close(port) end)
    port
  end

  defp read!(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode!(line) do
          %{"error" => error} -> flunk(error)
          message -> message
        end

      {^port, {:exit_status, status}} ->
        flunk("operations browser exited before completing: #{status}")
    after
      60_000 -> flunk("operations browser did not report progress within 60s")
    end
  end

  defp assert_exit!(port) do
    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> flunk("operations browser exited: #{status}")
      {^port, {:data, {:eol, line}}} -> flunk("unexpected browser result: #{line}")
    after
      15_000 -> flunk("operations browser did not stop after acceptance")
    end
  end
end
