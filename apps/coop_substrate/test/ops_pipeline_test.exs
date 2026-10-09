defmodule CoopSubstrate.OpsPipelineTest do
  @moduledoc """
  Phase 3B acceptance [3B] (docs/phase3b_plan.md P1–P4): the 2D end-to-end
  scenario driven ENTIRELY through the mix task modules — keys/genesis →
  constants → instrument → consents (seed captured from the shell output
  like a real handover) → interviews → findings (batch file) → documents →
  corroboration → status (short legs) → model → spec (hashes captured) →
  adopt → fixtures (dir + denylist) → prospect → gate true → build_started
  → revocation → gate false. No iex, no Ops calls from the test body.
  """

  use CoopSubstrate.LogCase, async: false

  @scratch Path.join(System.tmp_dir!(), "ops_pipeline_#{System.unique_integer([:positive])}")

  setup do
    keys_dir = Path.join(@scratch, "keys")
    previous = Application.get_env(:coop_substrate, :harness_keys_dir)
    Application.put_env(:coop_substrate, :harness_keys_dir, keys_dir)
    File.mkdir_p!(@scratch)

    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Application.put_env(:coop_substrate, :harness_keys_dir, previous)
      File.rm_rf(@scratch)
    end)

    :ok
  end

  defp drain do
    Stream.repeatedly(fn ->
      receive do
        {:mix_shell, :info, [msg]} -> msg
      after
        0 -> nil
      end
    end)
    |> Enum.take_while(& &1)
  end

  defp capture(regex) do
    messages = drain()

    case Enum.find_value(messages, &(Regex.run(regex, &1) |> then(fn m -> m && List.last(m) end))) do
      nil -> flunk("expected #{inspect(regex)} in #{inspect(messages)}")
      value -> value
    end
  end

  defp write!(name, content) do
    path = Path.join(@scratch, name)
    File.write!(path, content)
    path
  end

  test "the runbook end to end through the tasks; short legs; revocation flips it" do
    # Phase 0.2–0.4
    Mix.Tasks.Harness.Keys.run(["genesis", Path.join(@scratch, "genesis.bin"), "--yes"])
    drain()

    Mix.Tasks.Harness.Constants.run(["--n", "2", "--c", "1", "--d", "1", "--k", "2", "--yes"])
    drain()

    Mix.Tasks.Harness.Instrument.run(["publish"])
    drain()

    # Status before any interviews: every leg named (P2).
    Mix.Tasks.Harness.Status.run([])
    status = drain()
    assert "gate=false" in status
    assert Enum.any?(status, &(&1 =~ "interviews 0/2"))
    assert Enum.any?(status, &(&1 =~ "spec not adopted"))

    # Phase 2 — two ceremonies; seeds captured exactly as a handover would.
    Mix.Tasks.Harness.Consent.run(["--ref", "IV-1", "--classes", "synthesis,anonymized_fixtures,prospect_record"])
    alice_seed = capture(~r/^([0-9a-f]{64})$/)

    Mix.Tasks.Harness.Consent.run(["--ref", "IV-2", "--classes", "synthesis,anonymized_fixtures,prospect_record"])
    _bob_seed = capture(~r/^([0-9a-f]{64})$/)

    # Phase 3
    Mix.Tasks.Harness.Interview.run(["--id", "I-1", "--interviewee", "IV-1", "--mode", "form"])
    Mix.Tasks.Harness.Interview.run(["--id", "I-2", "--interviewee", "IV-2", "--mode", "chat"])
    drain()

    batch =
      write!(
        "findings.json",
        Jason.encode!([
          %{"finding_id" => "F-1", "interview_ref" => "I-1", "kind" => "process_step", "body" => "email tenders, gut-feel accepts"},
          %{"finding_id" => "F-2", "interview_ref" => "I-2", "kind" => "process_step", "body" => "email tenders, answered from the cab"},
          %{"finding_id" => "F-3", "interview_ref" => "I-2", "kind" => "exception", "body" => "no-show driver, load re-brokered"}
        ])
      )

    Mix.Tasks.Harness.Findings.run([batch])
    assert "appended 3 findings" in drain()

    # A mid-batch rejection stops there and names the entry (P3).
    bad =
      write!(
        "bad.json",
        Jason.encode!([
          %{"finding_id" => "F-4", "interview_ref" => "I-1", "kind" => "pain", "body" => "detention unpaid"},
          %{"finding_id" => "F-5", "interview_ref" => "I-1", "kind" => "vibes", "body" => "nope"}
        ])
      )

    assert_raise Mix.Error, fn -> Mix.Tasks.Harness.Findings.run([bad]) end
    assert_received {:mix_shell, :error, ["REJECTED: " <> rejected]}
    assert rejected =~ "F-5" and rejected =~ "unknown_finding_kind"
    drain()

    Mix.Tasks.Harness.Document.run([
      "--interview", "I-1", "--kind", "rate_confirmation",
      write!("ratecon.txt", "redacted rate con body")
    ])

    Mix.Tasks.Harness.Corroborate.run(["C-1", "F-1", "F-2"])
    drain()

    # Phase 5
    Mix.Tasks.Harness.Model.run(["publish"])
    drain()

    classifier = write!("classifier.json", Jason.encode!(%{"C-1" => %{"enveloped" => true}}))
    Mix.Tasks.Harness.Spec.run(["publish", classifier])
    spec_hash = capture(~r/^spec_hash=([0-9a-f]{64})$/)

    Mix.Tasks.Harness.Spec.run(["publish", classifier])
    messages = drain()
    defaults_hash = Enum.find_value(messages, &(Regex.run(~r/^defaults_hash=([0-9a-f]{64})$/, &1) |> then(fn m -> m && List.last(m) end)))
    model_hash = Enum.find_value(messages, &(Regex.run(~r/^model_hash=([0-9a-f]{64})$/, &1) |> then(fn m -> m && List.last(m) end)))

    Mix.Tasks.Harness.Adopt.run([
      "--spec", spec_hash, "--defaults", defaults_hash, "--model", model_hash, "--yes"
    ])

    drain()

    # Phase 6
    fixtures_dir = Path.join(@scratch, "fixtures")
    File.mkdir_p!(fixtures_dir)
    File.write!(Path.join(fixtures_dir, "rate_con_1.txt"), "carrier [REDACTED] lane at floor")
    denylist = write!("denylist.txt", "Malik\n")

    Mix.Tasks.Harness.Fixtures.run(["publish", fixtures_dir, "--denylist", denylist, "--sources", "I-1,I-2"])
    drain()

    Mix.Tasks.Harness.Prospect.run(["--ref", "P-1", "--interviewee", "IV-1", "--interview", "I-1"])
    drain()

    # Phase 7 — gate true, no short legs (P2), marker lands.
    Mix.Tasks.Harness.Status.run([])
    status = drain()
    assert "gate=true" in status
    refute Enum.any?(status, &String.starts_with?(&1, "short:"))

    Mix.Tasks.Harness.BuildStarted.run([])
    drain()

    Mix.Tasks.Harness.Checkpoint.run([Path.join(@scratch, "cp.bin")])
    drain()
    assert :ok = CoopSubstrate.Log.verify_checkpoint(File.read!(Path.join(@scratch, "cp.bin")))

    # Revocation via --seed-file: the gate flips; status names what fell.
    Mix.Tasks.Harness.Revoke.run(["--ref", "IV-1", "--seed-file", write!("alice.seed", alice_seed)])
    drain()

    Mix.Tasks.Harness.Status.run([])
    status = drain()
    assert "gate=false" in status
    assert Enum.any?(status, &(&1 =~ "corroborated core 0/1"))

    assert_raise Mix.Error, fn -> Mix.Tasks.Harness.BuildStarted.run([]) end
    assert_received {:mix_shell, :error, ["REJECTED: " <> term]}
    assert term =~ "harness_gate_not_passed"
    assert :ok = CoopSubstrate.Log.verify_chains()
  end
end
