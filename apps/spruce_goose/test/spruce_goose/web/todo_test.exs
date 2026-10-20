defmodule SpruceGoose.Web.TodoTest do
  @moduledoc """
  A task's todos over HTTP (docs/architecture/2026-10-20-sprucegoose-salvage.md):
  a person adds, completes and drops them from their device, and the
  project's feed carries them in order.
  """
  use ExUnit.Case, async: false

  import SpruceGoose.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Crypto, Log}
  alias CoopSubstrate.Feed.View

  setup do
    providers!()
    w = world()
    person = Principal.new_id()
    device = member("operator")
    grant = grant!(w, "TaskOperatorGrantedV1", device, person, "project-1")
    for id <- ["task-1", "task-2"], do: create!(w, grant, id, "project-1", device)
    bind([{"https://idp.test", "sub-person", person}])

    Map.merge(w, %{
      person: person,
      device: device,
      session: session!("second", "sub-person"),
      base: serve!()
    })
  end

  defp path(w), do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/project-1"

  defp step(w, body) do
    body = Map.put(body, "key_id", w.device.signer.key_id)

    with {201, held} <- post(path(w) <> "/commands", w.session, body) do
      signature =
        held["signing_bytes"]
        |> Base.url_decode64!(padding: false)
        |> Crypto.sign(w.device.seed)
        |> Base.url_encode64(padding: false)

      post("/api/v1/commands/#{held["id"]}", w.session, %{"signature" => signature})
    end
  end

  defp post(path, cookie, body) do
    conn =
      call(
        :post,
        path,
        [{"content-type", "application/json"}, {"cookie", cookie}],
        Jason.encode!(body)
      )

    {conn.status, Jason.decode!(conn.resp_body)}
  end

  defp task(w, id), do: Log.gate().orchestration.tasks[{w.chapter, tenant(), "project-1", id}]

  test "a person adds, completes and drops todos; the feed carries them in order", w do
    add = fn id, title, deps ->
      step(w, %{
        "action" => "add_todo",
        "task_id" => "task-1",
        "todo_id" => id,
        "title" => title,
        "depends_on" => deps
      })
    end

    assert {201, _} = add.("read", "Read the brief", [])
    assert {201, _} = add.("answer", "Answer it", ["read"])
    assert {409, %{"error" => "todo_exists"}} = add.("read", "Again", [])
    assert {400, %{"error" => "bad_action"}} = add.("x", "X", "read")

    assert {409, %{"error" => "todo_dependencies_open"}} =
             step(w, %{"action" => "complete_todo", "task_id" => "task-1", "todo_id" => "answer"})

    assert {201, _} =
             step(w, %{"action" => "complete_todo", "task_id" => "task-1", "todo_id" => "read"})

    assert {201, _} =
             step(w, %{
               "action" => "revise_todo",
               "task_id" => "task-1",
               "todo_id" => "answer",
               "title" => "Answer the brief",
               "depends_on" => ["read"]
             })

    assert {201, _} =
             step(w, %{
               "action" => "drop_todo",
               "task_id" => "task-1",
               "todo_id" => "answer",
               "reason" => "Answered by phone"
             })

    %{tasks: %{"task-1" => task}} = View.select(Log.gate(), {w.chapter, tenant(), "project-1"})

    assert [
             %{id: "read", title: "Read the brief", state: "completed", version: 2},
             %{id: "answer", title: "Answer the brief", depends_on: ["read"], state: "dropped"} =
               answer
           ] = task.todos

    assert answer.reason == "Answered by phone"
    assert answer.principal_id == w.person
  end
end
