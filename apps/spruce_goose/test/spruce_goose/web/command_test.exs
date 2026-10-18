defmodule SpruceGoose.Web.CommandTest do
  @moduledoc """
  The first workflow end to end at the HTTP boundary
  (docs/architecture/2026-10-18-decide.md): an agent suggests, a signed-in
  person prepares a decision, their device signs it, the ledger admits it.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Log}

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    device = member("operator")
    grant = grant!(w, "TaskOperatorGrantedV1", device, person, "project-1")
    create!(w, grant, "task-1", "project-1", device)

    suggestion =
      suggest!(w, w.agent_grant, "task-1", %{"schedule" => nil, "due_ms" => 1_792_396_800_000}, 1)

    bind([{"https://idp.test", "sub-person", person}])

    Map.merge(w, %{
      person: person,
      device: device,
      suggestion: suggestion,
      session: session!("second", "sub-person")
    })
  end

  defp commands_path(w),
    do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1/commands"

  defp post_json(path, cookie, body) do
    headers = [
      {"content-type", "application/json"} | if(cookie, do: [{"cookie", cookie}], else: [])
    ]

    conn = call(:post, path, headers, Jason.encode!(body))
    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp prepare(w, decision, opts \\ []) do
    post_json(
      commands_path(w),
      Keyword.get(opts, :cookie, w.session),
      Map.merge(
        %{"suggestion_event_id" => w.suggestion.event_id, "key_id" => w.device.signer.key_id},
        decision
      )
    )
  end

  # What the browser does with a prepared command.
  defp sign(%{"signing_bytes" => b64}, member),
    do:
      b64
      |> Base.url_decode64!(padding: false)
      |> Crypto.sign(member.seed)
      |> Base.url_encode64(padding: false)

  defp submit(w, prepared, member, cookie \\ nil),
    do:
      post_json("/api/v1/commands/#{prepared["id"]}", cookie || w.session, %{
        "signature" => sign(prepared, member)
      })

  defp status(w), do: Log.gate().orchestration.suggestions[w.suggestion.event_id].status

  test "accept: prepared, signed on the device, admitted", w do
    assert {201, prepared} = prepare(w, %{"decision" => "accept"})
    assert prepared["type"] == "TaskTimingRevisedV1"
    assert prepared["payload"]["principal_id"] == w.person

    assert {201, %{"event_id" => _, "global_seq" => seq}} = submit(w, prepared, w.device)
    assert seq == Log.head().global_seq
    assert status(w) == :accepted
  end

  test "decline, with the reason", w do
    assert {201, prepared} = prepare(w, %{"decision" => "decline", "reason" => "Not this week"})
    assert {201, _} = submit(w, prepared, w.device)
    assert status(w) == :declined
  end

  test "who is signed in", w do
    conn = call(:get, "/auth/me", [{"cookie", w.session}])
    assert {conn.status, Jason.decode!(conn.resp_body)} == {200, %{"principal" => w.person}}
    assert call(:get, "/auth/me", []).status == 401
  end

  describe "refused" do
    test "without a session, or without JSON", w do
      assert {401, _} = prepare(w, %{"decision" => "accept"}, cookie: nil)

      conn = call(:post, commands_path(w), [{"cookie", w.session}], "decision=accept")
      assert conn.status == 400
    end

    test "for a key the principal holds no operator grant for", w do
      assert {403, %{"error" => "no_operator_grant"}} =
               post_json(commands_path(w), w.session, %{
                 "decision" => "accept",
                 "suggestion_event_id" => w.suggestion.event_id,
                 "key_id" => w.agent.signer.key_id
               })
    end

    test "for a malformed decision or an unknown suggestion", w do
      assert {400, _} = prepare(w, %{"decision" => "maybe"})

      assert {409, %{"error" => "unknown_suggestion"}} =
               prepare(w, %{"decision" => "accept", "suggestion_event_id" => "nope"})
    end

    test "a signature by another key, and the command is spent", w do
      {201, prepared} = prepare(w, %{"decision" => "accept"})

      assert {422, %{"error" => "invalid_signature"}} = submit(w, prepared, w.agent)
      assert {404, _} = submit(w, prepared, w.device)
      assert status(w) == :pending
    end

    test "another person's prepared command", w do
      {201, prepared} = prepare(w, %{"decision" => "accept"})
      other = Principal.new_id()

      bind([
        {"https://idp.test", "sub-person", w.person},
        {"https://idp.test", "sub-other", other}
      ])

      assert {404, _} = submit(w, prepared, w.device, session!("second", "sub-other"))
      assert {201, _} = submit(w, prepared, w.device)
    end
  end

  describe "the web view" do
    test "is served with a strict content security policy" do
      conn = call(:get, "/app", [])

      assert conn.status == 200
      assert conn.resp_body =~ "<script type=\"module\" src=\"/app/app.js\">"
      assert [csp] = Plug.Conn.get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self'"

      for file <- ~w(app.js cbor.js device.js view.js),
          do: assert(call(:get, "/app/#{file}", []).status == 200)

      assert call(:get, "/app/secrets.exs", []).status == 404
    end
  end
end
