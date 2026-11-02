defmodule ProofBankCoreDispatchPilotTest do
  use ExUnit.Case, async: true

  alias ProofBankCore.DispatchPilot

  test "all transition proof and runtime anchors compile as inert, unverified obligations" do
    assert {:ok, packet} = DispatchPilot.compile()
    assert packet.blueprint.id == "dispatch-transition-pilot"
    assert packet.blueprint.verification_state == :unverified
    assert packet.blueprint.activation_state == :inert
    assert packet.review_state == :needs_owner_review
    assert packet.runtime_test_status == :not_run
    assert packet.formal_check_status == :not_run
    assert packet.extension_activation == :inert
    assert length(packet.links) == 4
    assert length(packet.blueprint.obligations) == 4

    for link <- packet.links do
      assert link.claim_status == :unverified
      assert link.implementation_refinement == :not_established
      assert String.starts_with?(link.lean_theorem, "BizKitDispatch.")
      assert String.ends_with?(link.runtime_test, "_test.exs")
    end
  end

  test "source-audit refuses absent checkout or wrong inputs" do
    assert {:error, :invalid_repo_root} = DispatchPilot.audit_sources(nil)
    assert {:error, {:unreadable_source, _, _}} =
             DispatchPilot.audit_sources(Path.join(System.tmp_dir!(), "missing-proof-bank-pilot"))
  end

  test "binds exact theorem and negative-control sources when checked out in umbrella" do
    root = Path.expand("../../..", __DIR__)

    if File.dir?(Path.join(root, "formal/lean")) do
      assert :ok = DispatchPilot.audit_sources(root)
    end
  end

  test "detects an altered model rather than promoting unsupported proof status" do
    root =
      Path.join(
        System.tmp_dir!(),
        "proof-bank-dispatch-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    try do
      File.mkdir_p!(Path.join(root, "apps/dispatch/lib/dispatch/operations"))

      File.write!(
        Path.join(root, "apps/dispatch/lib/dispatch/operations/board.ex"),
        "def transition("
      )

      assert {:error, {:missing_source_anchor, _, "lock_trip!("}} =
               DispatchPilot.audit_sources(root)
    after
      File.rm_rf!(root)
    end
  end
end
