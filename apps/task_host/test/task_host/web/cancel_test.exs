defmodule TaskHost.Web.CancelTest do
  @moduledoc """
  Calling a task off over HTTP (docs/architecture/2026-10-19-cancel-reopen.md):
  a person cancels from their device before the work starts; an
  administrator cancels any task short of completed with a governance key,
  through governance-signed requests to a running server.
  """
  use ExUnit.Case, async: false

  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias CoopSubstrate.{Cancellation, Canonical, Crypto, Log}
  alias CoopSubstrate.Governance.Client

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

  test "a person cancels from their device, with a reason; reopening needs work under way", w do
    assert {409, %{"error" => "invalid_reason"}} =
             step(w, %{"action" => "cancel", "task_id" => "task-1", "reason" => ""})

    assert {201, _} =
             step(w, %{"action" => "cancel", "task_id" => "task-1", "reason" => "Duplicate"})

    assert %{state: "cancelled", cancellation: %{reason: "Duplicate", principal_id: principal}} =
             task(w, "task-1")

    assert principal == w.person

    assert {409, %{"error" => "invalid_task_transition"}} =
             step(w, %{"action" => "reopen", "task_id" => "task-2", "reason" => "Again"})

    assert {400, %{"error" => "bad_action"}} =
             step(w, %{"action" => "cancel", "task_id" => "task-2"})
  end

  test "a governance key cancels over signed requests, the same any holder of it uses", w do
    url = w.base <> path(w) <> "/tasks/task-2"
    reason = "Client withdrew"

    assert {:ok, %{"title" => "Task task-2", "state" => "inbox"}} =
             Client.get_signed(url, governance(w))

    cancels? = fn core ->
      core["type"] == "TaskCancelledByGovernanceV1" and core["payload"]["task_id"] == "task-2" and
        core["payload"]["reason"] == reason
    end

    assert {:ok, %{"event_id" => _}} =
             Client.sign_held(url <> "/cancellation", governance(w), cancels?, %{
               "reason" => reason
             })

    assert %{state: "cancelled", cancellation: %{principal_id: nil, reason: ^reason}} =
             task(w, "task-2")
  end

  test "the task and its cancellation are for governance only", w do
    url = w.base <> path(w) <> "/tasks/task-1"

    # Unsigned, or signed by a key that governs nothing: refused.
    assert {:error, {401, _}} = Client.get(url)
    stranger = member("governance")

    assert {:error, {401, _}} =
             Client.get_signed(url, %{
               key_id: stranger.signer.key_id,
               pubkey: stranger.signer.pubkey,
               seed: stranger.seed
             })

    assert {:error, {401, _}} =
             Client.sign_held(
               url <> "/cancellation",
               %{
                 key_id: stranger.signer.key_id,
                 pubkey: stranger.signer.pubkey,
                 seed: stranger.seed
               },
               fn _ -> true end,
               %{"reason" => "Mine now"}
             )

    assert {:ok, %{"task_id" => "task-1", "state" => "inbox"}} =
             Client.get_signed(url, governance(w))

    assert {:error, {409, ~s({"error":"unknown_task"})}} =
             Client.get_signed(w.base <> path(w) <> "/tasks/nope", governance(w))
  end

  test "mix coop.task.cancel signs the reviewed task version and returns the appended event", w do
    governance_keys!(w)
    scope = "#{w.chapter}/#{tenant()}/project-1"
    args = [scope, "task-2", "Duplicate", "--server", w.base, "--yes"]

    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    before = Log.head()
    send(self(), {:mix_shell_input, :yes?, false})
    assert :ok = Mix.Tasks.Coop.Task.Cancel.run(List.delete(args, "--yes"))
    assert_received {:mix_shell, :info, ["cancellation declined"]}
    assert Log.head() == before

    assert :ok = Mix.Tasks.Coop.Task.Cancel.run(args)
    assert_received {:mix_shell, :info, ["cancelled: event " <> id]}

    assert %{state: "cancelled", last_event_id: ^id, cancellation: %{reason: "Duplicate"}} =
             task(w, "task-2")

    before = Log.head()

    assert_raise Mix.Error, ~r/cancellation refused/, fn ->
      Mix.Tasks.Coop.Task.Cancel.run(args)
    end

    assert Log.head() == before
  end

  test "a governance cancellation prepared before a task changes appends nothing", w do
    url = w.base <> path(w) <> "/tasks/task-2/cancellation"
    reason = "Client withdrew"
    key = {w.chapter, tenant(), "project-1", "task-2"}

    # Advance the task after its version was shown, while the CLI's exact
    # envelope check still expects version 1.
    assert {:ok, %{"version" => 1}} =
             Client.get_signed(String.replace_suffix(url, "/cancellation", ""), governance(w))

    assert {201, _} = step(w, %{"action" => "propose", "task_id" => "task-2"})
    before = Log.head()

    assert {:error, :not_what_was_shown} =
             Client.sign_held(
               url,
               governance(w),
               &Cancellation.expected?(&1, key, 1, reason),
               %{"reason" => reason}
             )

    assert Log.head() == before
    assert task(w, "task-2").state == "proposed"
  end

  test "the Mix signer checks every requested cancellation field against canonical bytes", w do
    key = {w.chapter, tenant(), "project-1", "task-2"}
    reason = "Duplicate"
    assert {:ok, held} = Cancellation.prepare(key, reason, w.gov.signer.key_id)
    assert {:ok, core} = Canonical.decode(held.signing_bytes)
    assert Cancellation.expected?(core, key, 1, reason)

    for {path, substitute} <- [
          {["type"], "TaskCancelledV1"},
          {["auth_ref"], {:bytes, <<0::256>>}},
          {["chapter_id"], "another-chapter"},
          {["payload", "tenant_id"], "another-tenant"},
          {["payload", "project_id"], "project-2"},
          {["payload", "task_id"], "task-1"},
          {["payload", "expected_version"], 2},
          {["payload", "reason"], "another reason"}
        ] do
      refute Cancellation.expected?(put_in(core, path, substitute), key, 1, reason)
    end
  end
end
