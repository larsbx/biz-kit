# What a deployed orchestration release must do, run inside it by
# scripts/release-smoke.sh (`bin/orchestration rpc`): signed task commands on
# the release's own ledger, refused where the rules refuse them, the feed view
# of a task's todos, and replay reproducing the state admission saw. Each
# check is a match: a mismatch raises, and the script never prints SMOKE OK.
alias CoopSubstrate.{Crypto, Log}
alias CoopSubstrate.Protocol.Envelope

chapter = "smoke-#{System.unique_integer([:positive])}"
scope = {chapter, "tenant-1", "project-1"}
where = %{"tenant_id" => "tenant-1", "project_id" => "project-1"}

member = fn role ->
  {pubkey, seed} = Crypto.generate_keypair()

  %{
    seed: seed,
    signer: %{
      role: role,
      pubkey: pubkey,
      key_id: "k-" <> Base.encode16(binary_part(pubkey, 0, 4), case: :lower)
    }
  }
end

sign = fn m, type, payload ->
  {:ok, env} =
    Envelope.new(%{
      event_id: CoopSubstrate.ULID.generate(),
      chapter_id: chapter,
      type: type,
      payload: payload,
      signers: [m.signer],
      auth_ref: nil,
      timestamp_ms: System.system_time(:millisecond)
    })

  {:ok, signed} = Envelope.sign(env, m.signer.key_id, m.seed)
  signed
end

append = fn m, type, payload -> Log.append(sign.(m, type, payload)) end
ok! = fn {:ok, [e]} -> e end

gov = member.("governance")
op = member.("operator")

ok!.(
  append.(gov, "RoleKeyDeclared", %{
    "role" => "governance",
    "key_id" => gov.signer.key_id,
    "pubkey" => {:bytes, gov.signer.pubkey}
  })
)

grant =
  ok!.(
    append.(
      gov,
      "TaskOperatorGrantedV1",
      Map.merge(where, %{
        "principal_id" => "alice",
        "key_id" => op.signer.key_id,
        "pubkey" => {:bytes, op.signer.pubkey}
      })
    )
  )

actor = %{
  "principal_id" => "alice",
  "authorization_event_id" => grant.event_id,
  "lifecycle_version" => 1
}

for id <- ~w(t1 t2),
    do:
      ok!.(
        append.(
          op,
          "TaskCreatedV1",
          Map.merge(
            where,
            Map.merge(actor, %{
              "task_id" => id,
              "title" => "Smoke #{id}",
              "timing" => %{"schedule" => nil, "due_ms" => nil}
            })
          )
        )
      )

step = fn action ->
  {:ok, type, payload} = TaskCore.Steps.command(Log.gate().orchestration, scope, action, actor)
  append.(op, type, payload)
end

ok!.(step.({:add_todo, "t1", "read", "Read the brief", []}))
ok!.(step.({:add_todo, "t1", "answer", "Answer it", ["read"]}))
{:error, {:reject, 0, :todo_dependencies_open}} = step.({:complete_todo, "t1", "answer"})
ok!.(step.({:complete_todo, "t1", "read"}))
ok!.(step.({:drop_todo, "t1", "answer", "Answered by phone"}))

%{tasks: %{"t1" => t1}} = CoopSubstrate.Feed.View.select(Log.gate(), scope)

[%{"id" => "read", "state" => "completed"}, %{"id" => "answer", "state" => "dropped"}] =
  Enum.map(t1.todos, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))

for id <- ~w(t1 t2), do: ok!.(step.({:propose, id}))

define = fn id, preds, version ->
  task = Log.gate().orchestration.tasks[{chapter, "tenant-1", "project-1", id}]

  payload =
    Map.merge(where, %{
      "task_id" => id,
      "expected_version" => task.version,
      "artifact_requirements" => %{},
      "predecessor_ids" => preds,
      "sop_digest" => {:bytes, :crypto.hash(:sha256, "SOP")}
    })

  append.(
    gov,
    "TaskReadinessDefinedV1",
    if(version, do: Map.put(payload, "sop_version", version), else: payload)
  )
end

ok!.(define.("t2", ["t1"], "1.1.0"))
{:error, {:reject, 0, :predecessor_cycle}} = define.("t1", ["t2"], nil)
{:error, {:reject, 0, :sop_version_regressed}} = define.("t2", ["t1"], "1.0.9")
{:error, {:reject, 0, :sop_version_required}} = define.("t2", ["t1"], nil)
ok!.(define.("t2", ["t1"], "1.2.0"))

{:ok, replayed} = Log.replay(CoopSubstrate.Projections.Membership)
true = replayed.orchestration.tasks == Log.gate().orchestration.tasks

IO.puts("SMOKE OK #{chapter}: todos, feed view, cycle refusal, SOP versions, replay parity")
