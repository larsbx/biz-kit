defmodule CoopSubstrate.OpsTest do
  @moduledoc """
  Phase 3A (docs/phase3a_plan.md P1–P6): key custody (0600, no seed ever
  returned or echoed), the TOFU genesis ceremony with a verifiable external
  checkpoint, constants declaration, and the consent ceremony — ephemeral
  seed shown once, nothing persisted, revocation only with the seed the
  interviewee brings back. Rejections pass through verbatim.
  """

  use CoopSubstrate.LogCase, async: false

  import Bitwise
  import ExUnit.CaptureIO

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Log
  alias CoopSubstrate.Projections.Membership

  setup do
    dir = Path.join(System.tmp_dir!(), "ops_keys_#{System.unique_integer([:positive])}")
    previous = Application.get_env(:coop_substrate, :harness_keys_dir)
    Application.put_env(:coop_substrate, :harness_keys_dir, dir)

    on_exit(fn ->
      Application.put_env(:coop_substrate, :harness_keys_dir, previous)
      File.rm_rf(dir)
    end)

    %{keys_dir: dir}
  end

  test "key custody: 0600 files, no seed in any return, unknown roles refused", ctx do
    assert {:ok, %{role: "steward", key_id: "k-" <> _, path: path}} = Ops.gen_key("steward")

    # 0600, and the return carries no seed material.
    assert (File.stat!(path).mode &&& 0o777) == 0o600
    assert {:error, {:key_exists, "steward"}} = Ops.gen_key("steward")
    assert {:error, {:unknown_role, "member"}} = Ops.gen_key("member")
    assert {:error, {:no_key, "governance"}} = Ops.load_signer("governance")

    {:ok, keys} = Ops.list_keys()
    assert [%{role: "steward", key_id: "k-" <> _}] = keys
    refute Enum.any?(keys, &Map.has_key?(&1, :seed))

    # Custody is explicit: no dir configured ⇒ a named error.
    Application.delete_env(:coop_substrate, :harness_keys_dir)
    assert {:error, :keys_dir_unset} = Ops.keys_dir()
    Application.put_env(:coop_substrate, :harness_keys_dir, ctx.keys_dir)
  end

  test "genesis: registry populated, checkpoint blob externally verifiable, re-run safe",
       ctx do
    blob_path = Path.join(ctx.keys_dir, "genesis_checkpoint.bin")

    {:ok, %{declared: declared, checkpoint_path: ^blob_path}} = Ops.genesis(blob_path)
    assert Enum.all?(declared, fn {_role, status} -> status == :ok end)

    {:ok, state} = Log.replay(Membership)

    for role <- ["governance", "steward", "checkpoint"] do
      assert map_size(state.role_keys[{"chapter-genesis", role}]) == 1
    end

    assert :ok = Log.verify_checkpoint(File.read!(blob_path))

    # Re-run: declarations already made are reported, not retried into errors
    # that abort; a fresh checkpoint still lands.
    {:ok, %{declared: redeclared}} = Ops.genesis(blob_path)
    assert Enum.all?(redeclared, fn {_role, status} -> status == :error end)
    assert :ok = Log.verify_checkpoint(File.read!(blob_path))
  end

  test "constants + consent ceremony + revocation, end to end without iex", ctx do
    {:ok, _} = Ops.genesis(Path.join(ctx.keys_dir, "g.bin"))
    {:ok, names} = Ops.declare_constants("D", 5, 4, 5, 2)
    assert names == ["harness/D/n", "harness/D/c", "harness/D/d", "k"]

    {:ok, %{version: 1}} = Ops.instrument_publish()

    # The ceremony persists NOTHING: keys-dir contents are unchanged by it.
    before_files = File.ls!(ctx.keys_dir) |> Enum.sort()

    {:ok, %{interviewee_ref: "IV-1", key_id: key_id, seed_hex: seed_hex}} =
      Ops.consent_ceremony("IV-1", ["synthesis", "prospect_record"], false)

    assert File.ls!(ctx.keys_dir) |> Enum.sort() == before_files
    refute seed_hex in Enum.map(before_files, &File.read!(Path.join(ctx.keys_dir, &1)))

    {:ok, state} = Log.replay(Membership)
    assert %{active: true, key_id: ^key_id} = state.consents[{"chapter-genesis", "IV-1"}]

    # Revocation only with the seed the interviewee brings back — a wrong
    # seed surfaces the gate's term verbatim.
    {_pub, wrong_seed} = CoopSubstrate.Crypto.generate_keypair()

    assert {:error, {:reject, _, {:wrong_key_for_role, "interviewee", _}}} =
             Ops.revoke_consent("IV-1", Base.encode16(wrong_seed))

    assert {:error, :malformed_seed} = Ops.revoke_consent("IV-1", "not-hex")

    {:ok, _} = Ops.revoke_consent("IV-1", seed_hex)
    {:ok, state} = Log.replay(Membership)
    assert %{active: false} = state.consents[{"chapter-genesis", "IV-1"}]
    assert :ok = Log.verify_chains()
  end

  test "rejections pass through verbatim (no translation layer)", ctx do
    {:ok, _} = Ops.gen_key("steward")

    # A gate rejection: unknown section — the exact validity term comes back.
    assert {:error, {:reject, 0, {:unknown_section, "Z"}}} =
             Ops.append("steward", "ResearchBriefFiled", %{
               "section" => "Z",
               "artifact_hash" => {:bytes, :crypto.strong_rand_bytes(32)}
             })

    _ = ctx
  end

  test "task layer: ceremony prints the seed exactly once; constants confirm via --yes" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, _} = Ops.gen_key("governance")

    Mix.Tasks.Harness.Constants.run(["--n", "5", "--c", "4", "--d", "5", "--k", "2", "--yes"])
    assert_received {:mix_shell, :info, ["declared harness/D/n"]}

    Mix.Tasks.Harness.Consent.run([
      "--ref",
      "IV-2",
      "--classes",
      "synthesis",
      "--recording"
    ])

    messages =
      Stream.repeatedly(fn ->
        receive do
          {:mix_shell, :info, [msg]} -> msg
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)

    seed_lines = Enum.filter(messages, &Regex.match?(~r/^[0-9a-f]{64}$/, &1))
    assert length(seed_lines) == 1

    # A task-level rejection prints REJECTED + the verbatim term, then raises.
    assert_raise Mix.Error, fn ->
      Mix.Tasks.Harness.Consent.run(["--ref", "IV-2", "--classes", "synthesis"])
    end

    assert_received {:mix_shell, :error, ["REJECTED: " <> rest]}
    assert rest =~ "consent_already_recorded"
  end

  test "instrument task publishes the seed tree and fetches it back" do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    {:ok, _} = Ops.gen_key("steward")

    Mix.Tasks.Harness.Instrument.run(["publish"])
    assert_received {:mix_shell, :info, ["published section=D version=1" <> _]}

    Mix.Tasks.Harness.Instrument.run(["fetch", "1"])
    assert_received {:mix_shell, :info, [json]}
    assert Jason.decode!(json)["section"] == "D"

    _ = capture_io(fn -> :ok end)
  end
end
