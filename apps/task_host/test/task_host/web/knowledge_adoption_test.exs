defmodule TaskHost.Web.KnowledgeAdoptionTest do
  @moduledoc """
  The actual knowledge workflow crosses the governance boundary through a
  verified Git source and signed HTTP commands. All principals, scopes, Git
  objects and retained artifacts in these tests are temporary fixtures.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import TaskHost.{IdentityFixtures, LedgerFixtures}

  alias BizKit.Identity.Principal
  alias BizOpsKB.{Catalog, Workflows}
  alias CoopSubstrate.{Blueprints, Crypto, Log}
  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Artifacts

  @workflow "office-assistant-onboarding-v1"
  @project "office-assistant"

  setup do
    providers!()
    w = world()
    governance_keys!(w)
    owner_device = member("operator")
    grant!(w, "TaskOperatorGrantedV1", owner_device, "owner", @project)

    append!(
      event(w, w.gov, "TaskProjectOwnerAssignedV1", %{
        "tenant_id" => tenant(),
        "project_id" => @project,
        "principal_id" => "owner"
      })
    )

    alice = Principal.new_id()
    grant = grant!(w, "TaskOperatorGrantedV1", w.op, alice, @project)
    bind([{"https://idp.test", "synthetic-alice", alice}])

    {:ok, catalog} = Catalog.load()
    {:ok, preview} = Workflows.preview(catalog, @workflow)
    {:ok, manifest} = Workflows.artifact(catalog, @workflow, :manifest)
    {:ok, sop} = Workflows.artifact(catalog, @workflow, :sop)
    root = Path.join(System.tmp_dir!(), "knowledge-adoption-" <> w.chapter)
    File.mkdir_p!(root)
    previous = Application.fetch_env(:coop_substrate, :artifact_dir)
    artifact_dir = Path.join(root, "artifacts")
    Application.put_env(:coop_substrate, :artifact_dir, artifact_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:coop_substrate, :artifact_dir, value)
        :error -> Application.delete_env(:coop_substrate, :artifact_dir)
      end

      File.rm_rf!(root)
    end)

    {checkout, source} = git_fixture!(root, preview["adoption"], manifest.bytes)

    Map.merge(w, %{
      alice: alice,
      office_grant: grant,
      session: session!("second", "synthetic-alice"),
      base: serve!(),
      catalog: catalog,
      preview: preview,
      manifest: manifest.bytes,
      sop: sop.bytes,
      checkout: checkout,
      source: source,
      artifact_dir: artifact_dir,
      task_ids: Map.new(preview["tasks"], &{&1["id"], "office-" <> &1["id"]})
    })
  end

  test "the CLI adopts the verified manifest without creating work; an operator creates its exact DAG",
       w do
    before = Log.head()

    # Unknown options cannot silently select another provider. Wrong Git
    # identity and path, and a wrong target project, admit no ledger event.
    for {fixture, extra} <- [
          {w, ["--provider", "github"]},
          {%{w | source: %{w.source | "repository" => "larsbx/other"}}, []},
          {%{w | source: %{w.source | "commit" => String.duplicate("f", 40)}}, []},
          {%{w | source: %{w.source | "path" => "missing.json"}}, []}
        ] do
      assert_raise Mix.Error, fn -> blueprint!(fixture, @project, extra) end
      assert Log.head() == before
    end

    assert_raise Mix.Error, ~r/blueprint_project_mismatch/, fn ->
      blueprint!(w, "project-2")
    end

    assert Log.head() == before

    # A held envelope containing different bytes is refused by the signer,
    # even when the server could otherwise admit that blueprint.
    params = Map.put(w.source, "manifest", Base.url_encode64(w.manifest, padding: false))

    assert {:error, :not_what_was_shown} =
             Client.sign_held(
               w.base <> path(w) <> "/blueprints",
               governance(w),
               &Blueprints.expected?(&1, scope(w), w.source, w.manifest <> "\n"),
               params
             )

    assert Log.head() == before
    w = adopt!(w)
    state = Log.gate().orchestration
    revision = state.blueprints[w.revision]
    manifest_digest = digest(w.preview["adoption"]["manifest_sha256"])

    assert revision.scope == scope(w)

    assert revision.source == %{
             repository: w.source["repository"],
             commit: w.source["commit"],
             tree: w.source["tree"],
             path: w.source["path"],
             manifest_digest: manifest_digest
           }

    assert {:ok, w.manifest} == Artifacts.get(elem(manifest_digest, 1))
    assert scoped_tasks(w) == %{}

    assert state.hierarchy[scope(w)].roadmaps["office-setup"].workflows["office-onboarding"].revision ==
             w.revision

    # Possession of an operator key in a different project grants no right
    # to instantiate this workflow in the office project.
    before = Log.head()

    assert {:error, {:reject, 0, :task_grant_scope_mismatch}} =
             Log.append(
               event(
                 w,
                 w.op,
                 "TaskWorkflowInstantiatedV1",
                 run_payload(w)
                 |> Map.put("authorization_event_id", w.op_grant.event_id)
                 |> Map.put("principal_id", "alice")
               )
             )

    assert Log.head() == before
    assert scoped_tasks(w) == %{}
    w = instantiate!(w)
    assert map_size(scoped_tasks(w)) == 8

    for definition <- w.preview["tasks"] do
      task = task(w, definition["id"])
      assert task.state == "inbox"
      assert task.title == definition["title"]
      assert task.dod.criteria == definition["definition_of_done"]
      refute Map.has_key?(task, :readiness)
      assert task.blueprint.run_event_id == w.run
      assert task.blueprint.revision_event_id == w.revision
      assert task.blueprint.definition_id == definition["id"]
      assert Enum.sort(task.blueprint.predecessor_ids) == predecessors(w, definition)
      assert task.blueprint.readiness_contract == contract(w)
    end
  end

  test "generic governance signatures and the HTTP batch cannot replace the adopted SOP or inputs",
       w do
    w = w |> adopt!() |> instantiate!() |> propose!()
    before = Log.head()
    original = readiness_payload(w, "owner-scope")
    other = digest(sha256("unreviewed replacement"))

    mutations = [
      Map.put(original, "sop_digest", other),
      Map.put(original, "sop_version", "2.0.0"),
      put_in(original, ["artifact_requirements", "source_24_12"], other),
      put_in(original, ["artifact_requirements", "workflow_manifest"], other)
    ]

    # These are ordinary correctly signed events, deliberately bypassing
    # the run-readiness preparation helper. Admission still enforces pins.
    for payload <- mutations do
      assert {:error, {:reject, 0, :blueprint_readiness_contract_mismatch}} =
               Log.append(event(w, w.gov, "TaskReadinessDefinedV1", payload))

      assert Log.head() == before
    end

    params = readiness_params(w)
    owner = w.task_ids["owner-scope"]
    other_hex = sha256("unreviewed replacement")

    for changed <- [
          Map.put(params, "sop_digest", other_hex),
          put_in(params, ["inputs", owner, "source_24_12"], other_hex),
          put_in(params, ["inputs", owner, "workflow_manifest"], other_hex)
        ] do
      # Even a client willing to sign the changed batch cannot admit it.
      assert {:error, {409, body}} =
               Client.sign_batch(readiness_url(w), governance(w), fn _ -> true end, changed)

      assert body =~ "blueprint_readiness_contract_mismatch"
      assert Log.head() == before
      assert Enum.all?(scoped_tasks(w), fn {_, task} -> not Map.has_key?(task, :readiness) end)
    end

    define_readiness!(w)

    for definition <- w.preview["tasks"] do
      task = task(w, definition["id"])
      assert task.state == "proposed"
      assert Map.take(task.readiness, Map.keys(contract(w))) == contract(w)
      assert Enum.sort(task.readiness.predecessor_ids) == predecessors(w, definition)
    end
  end

  test "the exact retained source bytes, own SOP acknowledgment and completed predecessors gate execution",
       w do
    w = w |> adopt!() |> instantiate!() |> propose!()
    define_readiness!(w)
    before = Log.head()

    assert {409, %{"error" => "sop_acknowledgment_required"}} =
             step(w, "owner-scope", %{"action" => "queue"})

    assert {409, %{"error" => "unknown_custody_receipt"}} =
             step(w, "owner-scope", %{
               "action" => "acknowledge_sop",
               "custody_receipt_id" => "no-such-receipt"
             })

    assert Log.head() == before
    assert task(w, "owner-scope").state == "proposed"

    # The preview's pins name the original documents, not rewritten copies.
    input_bytes =
      Map.new(w.preview["sources"], fn source ->
        {:ok, document} = Catalog.document(w.catalog, source["id"])
        assert sha256(document["body"]) == source["sha256"]
        name = "source_" <> String.replace(source["id"], ".", "_")
        {name, document["body"]}
      end)
      |> Map.put("workflow_manifest", w.manifest)

    for {name, bytes} <- input_bytes do
      assert sha256(bytes) == w.preview["required_inputs"][name]
    end

    # A source's valid digest cannot be used to upload different bytes.
    source_digest = w.preview["required_inputs"]["source_24_12"]

    assert {422, %{"error" => "digest_mismatch"}} =
             upload(w, "changed source", source_digest)

    assert {403, _} = upload(w, w.sop, sha256(w.sop), "ungranted-project")
    assert Log.head() == before
    sop_receipt = retain!(w, w.sop)

    assert {201, _} =
             step(w, "owner-scope", %{
               "action" => "acknowledge_sop",
               "custody_receipt_id" => sop_receipt
             })

    assert {201, _} = step(w, "owner-scope", %{"action" => "queue"})
    before = Log.head()

    assert {409, %{"error" => "invalid_readiness_receipts"}} =
             step(w, "owner-scope", %{"action" => "ready", "custody_receipts" => %{}})

    assert Log.head() == before
    receipts = Map.new(input_bytes, fn {name, bytes} -> {name, retain!(w, bytes)} end)

    assert {201, _} =
             step(w, "owner-scope", %{"action" => "ready", "custody_receipts" => receipts})

    # A receipt does not excuse loss of its bytes between readiness and start.
    File.rm!(Path.join(w.artifact_dir, source_digest))
    before = Log.head()
    assert {409, %{"error" => "not_found"}} = step(w, "owner-scope", %{"action" => "start"})
    assert Log.head() == before
    assert task(w, "owner-scope").state == "ready"
    assert {201, _} = upload(w, input_bytes["source_24_12"], source_digest)
    assert {201, _} = step(w, "owner-scope", %{"action" => "start"})
    assert task(w, "owner-scope").state == "in_progress"

    assert {201, _} =
             step(w, "preflight", %{
               "action" => "acknowledge_sop",
               "custody_receipt_id" => sop_receipt
             })

    assert {201, _} = step(w, "preflight", %{"action" => "queue"})
    before = Log.head()

    assert {409, %{"error" => "incomplete_predecessors"}} =
             step(w, "preflight", %{"action" => "ready", "custody_receipts" => receipts})

    assert Log.head() == before
    assert task(w, "preflight").state == "queued"
    assert Enum.count(scoped_tasks(w), fn {_, task} -> task.state == "in_progress" end) == 1
  end

  defp git_fixture!(root, adoption, bytes) do
    checkout = Path.join(root, "source")
    File.mkdir_p!(checkout)
    git!(checkout, ["init", "-q", "--object-format=sha1"])
    git!(checkout, ["config", "user.name", "Synthetic acceptance"])
    git!(checkout, ["config", "user.email", "acceptance@example.invalid"])
    git!(checkout, ["config", "core.autocrlf", "false"])
    git!(checkout, ["remote", "add", "origin", "https://github.com/larsbx/biz-kit.git"])
    destination = Path.join(checkout, adoption["path"])
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, bytes)
    File.chmod!(destination, 0o644)
    git!(checkout, ["add", "--", adoption["path"]])

    git!(checkout, [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "-q",
      "-m",
      "Synthetic pinned workflow acceptance"
    ])

    source = %{
      "repository" => adoption["repository"],
      "commit" => git!(checkout, ["rev-parse", "HEAD"]),
      "tree" => git!(checkout, ["rev-parse", "HEAD^{tree}"]),
      "path" => adoption["path"]
    }

    {checkout, source}
  end

  defp git!(checkout, args) do
    {output, status} = System.cmd("git", ["-C", checkout | args], stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end

  defp blueprint!(w, project, extra \\ []) do
    capture_io(fn ->
      Mix.Tasks.Coop.Blueprint.run(
        [
          "#{w.chapter}/#{tenant()}/#{project}",
          w.source["repository"],
          w.source["commit"],
          w.source["path"],
          "--source-checkout",
          w.checkout,
          "--server",
          w.base,
          "--yes"
        ] ++ extra
      )
    end)
  end

  defp adopt!(w) do
    output = blueprint!(w, @project)
    assert output =~ "office-onboarding  Office assistant onboarding  (8 tasks)"
    assert [_, event_id] = Regex.run(~r/applied: event (\S+)/, output)
    Map.put(w, :revision, event_id)
  end

  defp run_payload(w) do
    %{
      "tenant_id" => tenant(),
      "project_id" => @project,
      "principal_id" => w.alice,
      "authorization_event_id" => w.office_grant.event_id,
      "lifecycle_version" => 1,
      "revision_event_id" => w.revision,
      "roadmap_key" => "office-setup",
      "workflow_id" => "office-onboarding",
      "task_ids" => w.task_ids
    }
  end

  defp instantiate!(w) do
    [run] = append!(event(w, w.op, "TaskWorkflowInstantiatedV1", run_payload(w)))
    Map.put(w, :run, run.event_id)
  end

  defp propose!(w) do
    for definition <- w.preview["tasks"] do
      assert {201, _} = step(w, definition["id"], %{"action" => "propose"})
    end

    w
  end

  defp contract(w) do
    %{
      sop_digest: digest(w.preview["sop"]["sha256"]),
      sop_version: w.preview["sop"]["version"],
      artifact_requirements:
        Map.new(w.preview["required_inputs"], fn {k, v} -> {k, digest(v)} end)
    }
  end

  defp readiness_payload(w, definition_id) do
    task = task(w, definition_id)

    %{
      "tenant_id" => tenant(),
      "project_id" => @project,
      "task_id" => w.task_ids[definition_id],
      "expected_version" => task.version,
      "predecessor_ids" => task.blueprint.predecessor_ids,
      "artifact_requirements" => contract(w).artifact_requirements,
      "sop_digest" => contract(w).sop_digest,
      "sop_version" => contract(w).sop_version
    }
  end

  defp readiness_params(w) do
    %{
      "sop_digest" => w.preview["sop"]["sha256"],
      "sop_version" => w.preview["sop"]["version"],
      "inputs" => Map.new(w.task_ids, fn {_, id} -> {id, w.preview["required_inputs"]} end)
    }
  end

  defp define_readiness!(w) do
    expected =
      w.preview["tasks"]
      |> Enum.map(&readiness_payload(w, &1["id"]))
      |> Enum.sort_by(& &1["task_id"])

    # Compare every field, including scope, versions, dependencies and exact
    # digest bytes, before the governance device signs any held command.
    check = fn cores ->
      Enum.all?(
        cores,
        &(&1["chapter_id"] == w.chapter and &1["type"] == "TaskReadinessDefinedV1")
      ) and
        Enum.map(cores, & &1["payload"]) == expected
    end

    assert {:ok, %{"events" => events}} =
             Client.sign_batch(readiness_url(w), governance(w), check, readiness_params(w))

    assert length(events) == 8
  end

  defp step(w, definition_id, body) do
    body = Map.put(body, "task_id", w.task_ids[definition_id])
    command(w, body)
  end

  defp command(w, body) do
    body = Map.put(body, "key_id", w.op.signer.key_id)

    with {201, held} <- post(w, path(w) <> "/commands", body) do
      signature =
        held["signing_bytes"]
        |> Base.url_decode64!(padding: false)
        |> Crypto.sign(w.op.seed)
        |> Base.url_encode64(padding: false)

      post(w, "/api/v1/commands/#{held["id"]}", %{"signature" => signature})
    end
  end

  defp post(w, path, body) do
    response =
      Req.post!(w.base <> path, json: body, headers: [{"cookie", w.session}], retry: false)

    {response.status, response.body}
  end

  defp upload(w, bytes, claimed, project \\ @project) do
    response =
      Req.post!(w.base <> path(w, project) <> "/artifacts",
        body: bytes,
        headers: [
          {"content-type", "application/octet-stream"},
          {"x-content-sha256", claimed},
          {"cookie", w.session}
        ],
        retry: false
      )

    {response.status, response.body}
  end

  defp retain!(w, bytes) do
    hex = sha256(bytes)
    assert {201, %{"digest" => ^hex}} = upload(w, bytes, hex)

    assert {201, %{"event_id" => receipt}} =
             command(w, %{"action" => "record_custody", "artifact_digest" => hex})

    receipt
  end

  defp scoped_tasks(w) do
    {chapter, tenant, project} = scope(w)

    for {{^chapter, ^tenant, ^project, id}, task} <- Log.gate().orchestration.tasks,
        into: %{},
        do: {id, task}
  end

  defp task(w, definition_id), do: scoped_tasks(w)[w.task_ids[definition_id]]
  defp scope(w), do: {w.chapter, tenant(), @project}

  defp path(w, project \\ @project),
    do: "/api/v1/chapters/#{w.chapter}/tenants/#{tenant()}/projects/#{project}"

  defp readiness_url(w), do: w.base <> path(w) <> "/runs/#{w.run}/readiness"

  defp predecessors(w, definition),
    do: definition["depends_on"] |> Enum.map(&w.task_ids[&1]) |> Enum.sort()

  defp digest(hex), do: {:bytes, Base.decode16!(hex, case: :lower)}
  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
