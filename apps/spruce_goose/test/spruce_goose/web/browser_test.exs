defmodule SpruceGoose.Web.BrowserTest do
  @moduledoc """
  The first workflow in a real browser (docs/architecture/2026-10-18-decide.md):
  a person signs in, their browser makes its device key, an administrator
  grants it, an agent suggests, and the person accepts in the web view. The
  ledger then holds the decision, signed by the key the browser made.

  Needs Node and Playwright with Chromium, so it is excluded by default:
  `mix test --include browser`.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.Log

  @moduletag :browser

  @script Path.expand("../../browser/decide.cjs", __DIR__)

  test "accepting a suggestion in the web view signs it on the device" do
    providers!()
    w = world()
    person = Principal.new_id()
    bind([{"https://idp.test", "sub-person", person}])

    port = browser!(serve!(), w)
    assert %{"device" => %{"public_key" => pub_hex, "key_id" => key_id}} = read!(port)

    # The administrator enrols the browser's key; an agent suggests.
    device = %{
      signer: %{role: "operator", key_id: key_id, pubkey: Base.decode16!(pub_hex, case: :lower)}
    }

    grant = grant!(w, "TaskOperatorGrantedV1", device, person, "project-1")
    create!(w, w.op_grant, "task-1")

    suggestion =
      suggest!(w, w.agent_grant, "task-1", %{"schedule" => nil, "due_ms" => 1_792_396_800_000}, 1)

    Port.command(port, "go\n")
    assert %{"done" => "Recorded on the ledger" <> _} = read!(port)

    assert Log.gate().orchestration.suggestions[suggestion.event_id].status == :accepted

    {:ok, events} = Log.read_all(from: suggestion.global_seq + 1)

    [decision] =
      for e <- events, e.type == "TaskTimingRevisedV1", e.chapter_id == w.chapter, do: e

    assert decision.payload["principal_id"] == person
    assert decision.payload["authorization_event_id"] == grant.event_id
    assert hd(decision.signers).pubkey == device.signer.pubkey
  end

  defp browser!(base, w) do
    node = System.find_executable("node") || flunk("node is not installed")
    global = System.cmd("npm", ["root", "-g"]) |> elem(0) |> String.trim()

    Port.open({:spawn_executable, node}, [
      :binary,
      :exit_status,
      {:line, 1_000_000},
      {:env, [{~c"NODE_PATH", String.to_charlist(global)}]},
      args: [@script, base, w.chapter, tenant(), "project-1"]
    ])
  end

  defp read!(port) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"error" => error}} -> flunk("browser: " <> error)
          {:ok, message} -> message
          {:error, _} -> read!(port)
        end

      {^port, {:exit_status, status}} ->
        flunk("browser exited with #{status}")
    after
      30_000 -> flunk("no word from the browser in 30s")
    end
  end
end
