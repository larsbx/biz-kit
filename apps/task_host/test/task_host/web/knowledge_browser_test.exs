defmodule TaskHost.Web.KnowledgeBrowserTest do
  @moduledoc "Real identity, scoped ledger grants and source reads in a mobile browser."
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias BizOpsKB.Catalog
  alias CoopSubstrate.Log

  @moduletag :browser
  @moduletag timeout: 180_000
  @script Path.expand("../../browser/knowledge.cjs", __DIR__)

  test "a reader browses references, retains work filters, and loses reads after revocation" do
    providers!()
    w = world()
    principal = Principal.new_id()
    outsider = Principal.new_id()

    bind([
      {"https://idp.test", "kb-browser", principal},
      {"https://idp.test", "kb-browser-outsider", outsider}
    ])

    grant = grant!(w, "TaskOperatorGrantedV1", member("operator"), principal, "project-1")
    previous = Application.fetch_env(:task_host, :operations)

    Application.put_env(:task_host, :operations, %{
      "schema_version" => 1,
      "title" => "Reference acceptance",
      "workspaces" => [
        %{
          "id" => "knowledge-desk",
          "label" => "Knowledge desk",
          "chapter_id" => w.chapter,
          "tenant_id" => tenant(),
          "project_id" => "project-1"
        }
      ]
    })

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:task_host, :operations, value)
        :error -> Application.delete_env(:task_host, :operations)
      end
    end)

    {:ok, catalog} = Catalog.load()
    documents = Catalog.search(catalog, query: "24.12a", limit: 100)["documents"]
    document = Enum.find(documents, &(&1["jd_id"] == "24.12a")) || hd(documents)
    port = browser!(serve!(), document)
    before = Log.head()
    assert %{"stage" => "knowledge_browsed"} = read!(port)
    assert Log.head() == before
    revoke!(w, "TaskOperatorRevokedV1", grant)
    revoked = Log.head()
    Port.command(port, "revoked\n")
    assert %{"stage" => "knowledge_revoked"} = read!(port)
    assert Log.head() == revoked

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> flunk("knowledge browser exited: #{status}")
    after
      15_000 -> flunk("knowledge browser did not stop")
    end
  end

  defp browser!(base, document) do
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
        args: [@script, base, Jason.encode!(document)]
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
        flunk("knowledge browser stopped early: #{status}")
    after
      60_000 -> flunk("knowledge browser did not report progress")
    end
  end
end
