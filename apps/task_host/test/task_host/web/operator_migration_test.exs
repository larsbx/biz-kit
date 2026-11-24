defmodule TaskHost.Web.OperatorMigrationTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity
  alias BizKit.Identity.{Principal, Sessions}
  alias CoopSubstrate.Governance.Client, as: Governance
  alias CoopSubstrate.Log
  alias TaskHost.OperatorClient, as: Client

  setup do
    providers!()
    world = world()
    principal = Principal.new_id()
    device = member("operator")
    identity = %{issuer: "https://idp.test", subject: "migrated-operator"}
    bind([{identity.issuer, identity.subject, principal}])
    token = Sessions.create_native(principal, identity)
    grant = grant!(world, "TaskOperatorGrantedV1", device, principal, "project-1")

    dir = Path.join(System.tmp_dir!(), "migration-" <> world.chapter)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    seed_file = Path.join(dir, "device")
    token_file = Path.join(dir, "session")
    File.write!(seed_file, Base.encode16(device.seed, case: :lower))
    File.write!(token_file, token)
    for file <- [seed_file, token_file], do: File.chmod!(file, 0o600)
    on_exit(fn -> File.rm_rf!(dir) end)

    base = serve!()
    scope = {world.chapter, tenant(), "project-1"}

    opts = [
      server: base,
      grant: grant.event_id,
      key_id: device.signer.key_id,
      seed_file: seed_file,
      session_file: token_file
    ]

    %{
      w: world,
      principal: principal,
      grant: grant,
      device: device,
      token: token,
      dir: dir,
      scope: scope,
      base: base,
      opts: opts,
      signer: %{grant: grant.event_id, key: device.signer.key_id, seed: device.seed}
    }
  end

  defp args(w) do
    Enum.flat_map(w.opts, fn {key, value} ->
      ["--" <> String.replace(Atom.to_string(key), "_", "-"), value]
    end)
  end

  defp cli(w, command) do
    scope = w.scope |> Tuple.to_list() |> Enum.join("/")

    capture_io(fn -> Mix.Tasks.Coop.Task.run([hd(command), scope | tl(command)] ++ args(w)) end)
    |> Jason.decode!()
  end

  defp intent!(w, action, fields, expected) do
    file = Path.join(w.dir, "intent.json")

    File.write!(
      file,
      Jason.encode!(%{"request" => Map.put(fields, "action", action), "expect" => expected})
    )

    file
  end

  defp git!(checkout, args) do
    {result, 0} =
      System.cmd("git", ["-C", checkout] ++ args,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}],
        stderr_to_stdout: true
      )

    String.trim(result)
  end

  defp commit_source!(checkout, path, bytes) do
    File.write!(Path.join(checkout, path), bytes)
    git!(checkout, ["add", "--", path])
    git!(checkout, ["-c", "commit.gpgSign=false", "commit", "--quiet", "-m", "Pinned artifact"])
    git!(checkout, ["rev-parse", "HEAD"])
  end

  test "list and show use exact scope, stable IDs and one ledger snapshot", w do
    create!(w.w, w.grant, "a", "project-1", w.device)
    create!(w.w, w.grant, "b", "project-1", w.device)
    create!(w.w, w.w.op_grant_2, "private", "project-2")

    assert %{
             "tasks" => [%{"task_id" => "a"}],
             "total" => 2,
             "next_after" => "a",
             "snapshot" => snapshot
           } = cli(w, ["list", "--limit", "1"])

    assert %{"tasks" => [%{"task_id" => "b"}], "next_after" => nil} =
             cli(w, ["list", "--limit", "1", "--after", "a", "--snapshot", snapshot])

    assert %{"task_id" => "a", "version" => 1, "todos" => []} = cli(w, ["show", "a"])
    assert %{"task_id" => "a", "todos" => []} = cli(w, ["todo-list", "a"])

    assert %{"principal_id" => principal, "grant_event_id" => grant, "role" => "operator"} =
             cli(w, ["whoami"])

    assert {principal, grant} == {w.principal, w.grant.event_id}

    assert %{"projects" => [%{"project_id" => "project-1"}], "total" => 1} =
             capture_io(fn -> Mix.Tasks.Coop.Task.run(["projects" | args(w)]) end)
             |> Jason.decode!()

    assert {:error, {:http, 404, "unknown_task"}} =
             Client.get(w.base, w.scope, "/tasks/private/view", w.signer)

    assert {:error, {:http, 400, "unknown_filter"}} =
             Client.get(w.base, w.scope, "/tasks", w.signer, %{"priority" => "1"})

    create!(w.w, w.grant, "c", "project-1", w.device)

    assert {:error, {:http, 409, "stale_snapshot"}} =
             Client.get(w.base, w.scope, "/tasks", w.signer, %{
               "after" => "a",
               "snapshot" => snapshot
             })

    revoke!(w.w, "TaskOperatorRevokedV1", w.grant)

    assert {:error, {:http, 401, "unauthorized"}} =
             Client.get(w.base, w.scope, "/tasks", w.signer)
  end

  test "the Mix task reads open work in a fresh client without starting the host", w do
    for id <- ["a", "b"], do: create!(w.w, w.grant, id, "project-1", w.device)
    session = {"authorization", "Bearer " <> w.token}

    cancel = %{
      "request" => %{"action" => "cancel", "task_id" => "a", "reason" => "Superseded"},
      "expect" => %{
        "task_id" => "a",
        "expected_version" => 1,
        "lifecycle_version" => 1,
        "reason" => "Superseded"
      }
    }

    assert {:ok, held} = Client.prepare(w.base, w.scope, session, w.signer, cancel)
    assert {:ok, _} = Client.submit(w.base, session, w.signer, held)

    scope = w.scope |> Tuple.to_list() |> Enum.join("/")
    argv = ["coop.task", "list", scope, "--open", "--limit", "1"] ++ args(w)

    assert {result, 0} =
             System.cmd("mix", argv, env: [{"MIX_ENV", "test"}], stderr_to_stdout: true)

    assert %{"tasks" => [%{"task_id" => "b"}], "total" => 1} = Jason.decode!(result)
  end

  test "a new command-line device gets a fresh grant through governance approval", w do
    governance_keys!(w.w)
    path = Path.join(w.dir, "new-device")

    assert %{"key_id" => key_id} =
             capture_io(fn -> Mix.Tasks.Coop.Task.run(["keygen", path]) end) |> Jason.decode!()

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert_raise Mix.Error, ~r/eexist/, fn -> Mix.Tasks.Coop.Task.run(["keygen", path]) end

    new_device = %{w | opts: Keyword.put(w.opts, :seed_file, path)}
    assert %{"code" => code} = cli(new_device, ["enrol", "CLI on the new host"])
    assert %{"devices" => pending} = cli(w, ["devices"])
    refute Enum.any?(pending, &(&1["key_id"] == key_id))
    capture_io(fn -> Mix.Tasks.Coop.Enrol.run([code, "--server", w.base, "--yes"]) end)

    assert %{"devices" => approved} = cli(w, ["devices"])
    assert %{"grant_id" => grant_id} = Enum.find(approved, &(&1["key_id"] == key_id))
    refute grant_id == w.grant.event_id

    assert %{"grant_event_id" => ^grant_id, "principal_id" => principal} =
             cli(
               %{
                 new_device
                 | opts: Keyword.merge(new_device.opts, grant: grant_id, key_id: key_id)
               },
               ["whoami"]
             )

    assert principal == w.principal
  end

  test "governance audits active and historical grants in one exact scope", w do
    governance_keys!(w.w)
    scope = w.scope |> Tuple.to_list() |> Enum.join("/")
    url = w.base <> Client.project_path(w.scope) <> "/authority"
    signer = governance(w.w)

    argv = ["--server", w.base, "--principal", w.principal, "--role", "operator"]

    assert %{"authorities" => [%{"active" => true, "authority_event_id" => id}], "total" => 1} =
             capture_io(fn -> Mix.Tasks.Coop.Task.Authority.run([scope | argv]) end)
             |> Jason.decode!()

    assert id == w.grant.event_id
    assert {:error, {401, _}} = Governance.get(url)
    assert {:error, {401, _}} = Governance.get_signed(url, governance(world()))

    assert {:ok, %{"authorities" => [], "total" => 0}} =
             Governance.get_signed(
               w.base <>
                 Client.project_path({w.w.chapter, "other-tenant", "project-1"}) <>
                 "/authority?principal=" <> w.principal,
               signer
             )

    revoke!(w.w, "TaskOperatorRevokedV1", w.grant)

    assert %{"authorities" => [%{"active" => false, "authority_event_id" => ^id}]} =
             capture_io(fn -> Mix.Tasks.Coop.Task.Authority.run([scope | argv]) end)
             |> Jason.decode!()

    assert %{"authorities" => [], "total" => 0} =
             capture_io(fn ->
               Mix.Tasks.Coop.Task.Authority.run([scope | argv ++ ["--active", "true"]])
             end)
             |> Jason.decode!()
  end

  test "task IDs keep their published syntax and validate actual calendar dates" do
    assert %{"id" => id} =
             capture_io(fn -> Mix.Tasks.Coop.Task.run(["id"]) end) |> Jason.decode!()

    assert %{"id" => ^id, "valid" => true} =
             capture_io(fn -> Mix.Tasks.Coop.Task.run(["validate-id", id]) end) |> Jason.decode!()

    assert_raise Mix.Error, ~r/invalid task ID/, fn ->
      Mix.Tasks.Coop.Task.run(["validate-id", "tsk-20260231T012351Z-ea5ba1b1"])
    end
  end

  test "hierarchy preserves roadmap keys, workflow IDs and the pinned source", w do
    revision = apply_blueprint!(w.w)

    assert %{"roadmaps" => [%{"roadmap_key" => "q4", "workflows" => [workflow]}]} =
             cli(w, ["hierarchy"])

    assert workflow["revision_event_id"] == revision.event_id
    assert workflow["source"]["commit"] == revision.payload["commit"]
    assert workflow["source"]["tree"] == revision.payload["tree"]
    assert Enum.map(workflow["definitions"], & &1["id"]) == ["build", "ship"]

    fields = %{
      "revision_event_id" => revision.event_id,
      "roadmap_key" => "q4",
      "workflow_id" => workflow["workflow_id"],
      "task_ids" => %{"build" => "legacy-build", "ship" => "legacy-ship"}
    }

    assert %{"event_id" => run} =
             cli(w, [
               "act",
               intent!(w, "instantiate", fields, Map.put(fields, "lifecycle_version", 1)),
               "--yes"
             ])

    assert %{"blueprint" => %{"run_event_id" => ^run, "predecessor_ids" => ["legacy-build"]}} =
             cli(w, ["show", "legacy-ship"])
  end

  test "native commands need the exact active grant and the reviewed canonical payload", w do
    create!(w.w, w.grant, "old-task", "project-1", w.device)
    fields = %{"task_id" => "old-task"}
    pin = %{"task_id" => "old-task", "expected_version" => 1, "lifecycle_version" => 1}
    session = {"authorization", "Bearer " <> w.token}
    before = Log.head()
    intent = fn f, e -> %{"request" => Map.put(f, "action", "propose"), "expect" => e} end

    assert {:error, :not_what_was_reviewed} =
             Client.prepare(
               w.base,
               w.scope,
               session,
               w.signer,
               intent.(fields, Map.put(pin, "expected_version", 2))
             )

    assert {:error, {:http, 403, "no_operator_grant"}} =
             Client.prepare(
               w.base,
               w.scope,
               session,
               %{w.signer | grant: w.w.op_grant.event_id},
               intent.(fields, pin)
             )

    assert {:error, :unsupported_action} =
             Client.prepare(w.base, w.scope, session, w.signer, %{
               "request" => %{"action" => "revise"},
               "expect" => %{}
             })

    assert Log.head() == before

    file = intent!(w, "propose", fields, pin)
    assert %{"event_id" => event, "global_seq" => _} = cli(w, ["act", file, "--yes"])
    assert %{"state" => "proposed", "last_event_id" => ^event} = cli(w, ["show", "old-task"])

    :ok = Identity.logout(w.token)

    assert {:error, {:http, 401, "unauthorized"}} =
             Client.prepare(w.base, w.scope, session, w.signer, intent.(fields, pin))
  end

  test "the command line runs a task from SOP custody to independently reviewed completion", w do
    create!(w.w, w.grant, "old-task", "project-1", w.device)
    fields = %{"task_id" => "old-task"}
    pin = %{"task_id" => "old-task", "expected_version" => 1, "lifecycle_version" => 1}
    cli(w, ["act", intent!(w, "propose", fields, pin), "--yes"])

    contents = "Recovered SOP for #{w.w.chapter}"
    hash = :crypto.hash(:sha256, contents)

    append!(
      event(w.w, w.w.gov, "TaskReadinessDefinedV1", %{
        "tenant_id" => tenant(),
        "project_id" => "project-1",
        "task_id" => "old-task",
        "expected_version" => 2,
        "predecessor_ids" => [],
        "artifact_requirements" => %{},
        "sop_digest" => {:bytes, hash},
        "sop_version" => "1.0.0"
      })
    )

    file = Path.join(w.dir, "sop.txt")
    File.write!(file, contents)
    hex = Base.encode16(hash, case: :lower)

    assert %{"task_id" => "old-task", "sop_digest" => ^hex, "sop_version" => "1.0.0"} =
             cli(w, ["verify-sop", "old-task", file])

    substitute = Path.join(w.dir, "substitute.txt")
    File.write!(substitute, "A substitute SOP")

    assert_raise Mix.Error, ~r/sop_digest_mismatch/, fn ->
      cli(w, ["verify-sop", "old-task", substitute])
    end

    assert %{"digest" => ^hex} = cli(w, ["upload", file])
    bytes = %{"$bytes" => Base.url_encode64(hash, padding: false)}

    receipt_intent =
      intent!(w, "record_custody", %{"artifact_digest" => hex}, %{"artifact_digest" => bytes})

    assert %{"event_id" => receipt} = cli(w, ["act", receipt_intent, "--yes"])

    ack_fields = Map.merge(fields, %{"custody_receipt_id" => receipt})
    ack = Map.merge(ack_fields, %{"expected_version" => 3, "lifecycle_version" => 1})

    assert %{"event_id" => _} =
             cli(w, ["act", intent!(w, "acknowledge_sop", ack_fields, ack), "--yes"])

    assert %{
             "readiness" => %{
               "sop_digest" => ^hex,
               "sop_version" => "1.0.0",
               "acknowledgment" => %{"custody_receipt_id" => ^receipt}
             }
           } = cli(w, ["show", "old-task"])

    task = fn -> cli(w, ["show", "old-task"]) end

    [dod] =
      append!(
        event(w.w, w.w.gov, "TaskDoDDefinedV1", %{
          "tenant_id" => tenant(),
          "project_id" => "project-1",
          "task_id" => "old-task",
          "expected_version" => task.()["version"],
          "criteria" => [%{"id" => "report", "description" => "A report in custody"}]
        })
      )

    act = fn user, action, request, expected, lifecycle? ->
      target = %{"task_id" => "old-task", "expected_version" => task.()["version"]}
      target = if lifecycle?, do: Map.put(target, "lifecycle_version", 1), else: target
      file = intent!(user, action, Map.merge(fields, request), Map.merge(target, expected))
      cli(user, ["act", file, "--yes"])
    end

    act.(w, "queue", %{}, %{}, true)
    inputs = %{"custody_receipts" => %{}}
    act.(w, "ready", inputs, inputs, true)
    act.(w, "start", %{}, %{}, true)

    report = "Report for " <> w.w.chapter
    report_file = Path.join(w.dir, "report.txt")
    File.write!(report_file, report)
    report_digest = :crypto.hash(:sha256, report)
    report_hex = Base.encode16(report_digest, case: :lower)

    assert %{"digest" => ^report_hex} =
             cli(w, ["upload", report_file, "--evidence-for", "old-task"])

    report_bytes = %{"$bytes" => Base.url_encode64(report_digest, padding: false)}

    report_intent =
      intent!(
        w,
        "record_custody",
        %{"artifact_digest" => report_hex},
        %{"artifact_digest" => report_bytes}
      )

    assert %{"event_id" => report_receipt} = cli(w, ["act", report_intent, "--yes"])
    evidence = %{"custody_receipts" => %{"report" => report_receipt}}

    assert %{"event_id" => submission} =
             act.(
               w,
               "submit_evidence",
               evidence,
               Map.merge(evidence, %{
                 "evidence" => %{"report" => report_bytes},
                 "definition_event_id" => dod.event_id
               }),
               false
             )

    review_request = %{"decision" => "accept", "reason" => "Report verified"}

    review_fields =
      Map.merge(review_request, %{
        "definition_event_id" => dod.event_id,
        "submission_event_id" => submission
      })

    before = Log.head()

    assert_raise Mix.Error, ~r/no_reviewer_grant/, fn ->
      act.(w, "review", review_request, review_fields, false)
    end

    assert Log.head() == before

    reviewer = member("reviewer")
    principal = Principal.new_id()

    bind([
      {"https://idp.test", "migrated-operator", w.principal},
      {"https://idp.test", "reviewer", principal}
    ])

    token = Sessions.create_native(principal, %{issuer: "https://idp.test", subject: "reviewer"})
    grant = grant!(w.w, "TaskReviewerGrantedV1", reviewer, principal, "project-1")
    seed_path = Path.join(w.dir, "reviewer-seed")
    token_path = Path.join(w.dir, "reviewer-session")
    File.write!(seed_path, Base.encode16(reviewer.seed, case: :lower))
    File.write!(token_path, token)
    for path <- [seed_path, token_path], do: File.chmod!(path, 0o600)

    reviewer_opts =
      Keyword.merge(w.opts,
        grant: grant.event_id,
        key_id: reviewer.signer.key_id,
        seed_file: seed_path,
        session_file: token_path
      )

    assert %{"event_id" => review} =
             act.(%{w | opts: reviewer_opts}, "review", review_request, review_fields, false)

    completion = %{"review_event_id" => review}
    assert %{"event_id" => event_id} = act.(w, "complete", completion, completion, true)
    assert %{"state" => "completed", "last_event_id" => ^event_id} = task.()
  end

  test "a Git source receipt binds scope, origin and custody under a distinct reviewer", w do
    checkout = Path.join(w.dir, "source")
    path = "inputs/file.txt"
    File.mkdir_p!(Path.join(checkout, "inputs"))
    git!(checkout, ["init", "--quiet"])
    git!(checkout, ["config", "user.name", "Artifact fixture"])
    git!(checkout, ["config", "user.email", "fixture@example.invalid"])
    git!(checkout, ["config", "remote.origin.url", "https://github.com/org/sources.git"])

    content = :binary.copy(<<"x">>, 1_048_577)
    commit = commit_source!(checkout, path, content)
    substituted = commit_source!(checkout, path, "Substituted task input")

    create!(w.w, w.grant, "old-task", "project-1", w.device)
    fields = %{"task_id" => "old-task"}
    pin = %{"task_id" => "old-task", "expected_version" => 1, "lifecycle_version" => 1}
    cli(w, ["act", intent!(w, "propose", fields, pin), "--yes"])
    digest = :crypto.hash(:sha256, content)

    append!(
      event(w.w, w.w.gov, "TaskReadinessDefinedV1", %{
        "tenant_id" => tenant(),
        "project_id" => "project-1",
        "task_id" => "old-task",
        "expected_version" => 2,
        "predecessor_ids" => [],
        "artifact_requirements" => %{"input" => {:bytes, digest}},
        "sop_digest" => {:bytes, digest}
      })
    )

    file = Path.join(w.dir, "input.txt")
    File.write!(file, content)
    assert %{"digest" => hex} = cli(w, ["upload", file])
    expected = %{"artifact_digest" => %{"$bytes" => Base.url_encode64(digest, padding: false)}}

    assert %{"event_id" => custody} =
             cli(w, [
               "act",
               intent!(w, "record_custody", %{"artifact_digest" => hex}, expected),
               "--yes"
             ])

    reviewer = member("reviewer")
    principal = Principal.new_id()

    bind([
      {"https://idp.test", "migrated-operator", w.principal},
      {"https://idp.test", "reviewer", principal}
    ])

    token = Sessions.create_native(principal, %{issuer: "https://idp.test", subject: "reviewer"})
    grant = grant!(w.w, "TaskReviewerGrantedV1", reviewer, principal, "project-1")
    File.write!(w.opts[:seed_file], Base.encode16(reviewer.seed, case: :lower))
    File.write!(w.opts[:session_file], token)
    reviewer_opts = Keyword.merge(w.opts, grant: grant.event_id, key_id: reviewer.signer.key_id)

    attest = fn commit ->
      scope = w.scope |> Tuple.to_list() |> Enum.join("/")

      capture_io(fn ->
        Mix.Tasks.Coop.Task.Attest.run(
          [
            scope,
            "old-task",
            "input",
            custody,
            "org/sources",
            commit,
            path,
            "--source-checkout",
            checkout,
            "--yes"
          ] ++
            args(%{w | opts: reviewer_opts})
        )
      end)
    end

    assert [_, id] = Regex.run(~r/"event_id":"([^"]+)"/, attest.(commit))
    {chapter, tenant, project} = w.scope
    task = Log.gate().orchestration.tasks[{chapter, tenant, project, "old-task"}]
    assert task.version == 3

    assert %{
             name: "input",
             custody_receipt_id: ^custody,
             principal_id: ^principal,
             artifact_digest: {:bytes, ^digest},
             size_bytes: 1_048_577,
             source: %{"commit" => ^commit, "path" => ^path}
           } =
             task.artifact_sources[id]

    assert {:ok, replayed} = Log.replay_verified(CoopSubstrate.Projections.Membership, Log.head())

    assert replayed.orchestration.tasks[{chapter, tenant, project, "old-task"}].artifact_sources ==
             task.artifact_sources

    before = Log.head()
    assert_raise Mix.Error, ~r/artifact_source_already_attested/, fn -> attest.(commit) end

    assert_raise Mix.Error, ~r/artifact_not_attached/, fn ->
      attest.(substituted)
    end

    assert Log.head() == before

    grant!(w.w, "TaskOperatorGrantedV1", reviewer, principal, "project-1")
    before = Log.head()
    assert_raise Mix.Error, ~r/artifact_verifier_also_operator/, fn -> attest.(commit) end
    assert Log.head() == before
  end
end
