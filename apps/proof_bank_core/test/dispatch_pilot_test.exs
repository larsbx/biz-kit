defmodule ProofBankCore.DispatchPilotTest do
  use ExUnit.Case, async: true

  alias ProofBankCore.DispatchPilot

  test "compiles five traceable, inert and unverified first-party obligations" do
    assert {:ok, packet} = DispatchPilot.compile()
    assert packet.blueprint.id == "dispatch-transition-current-grant"
    assert packet.blueprint.verification_state == :unverified
    assert packet.blueprint.activation_state == :inert
    assert packet.review_state == :needs_owner_review
    assert packet.activation_state == :inert
    assert length(packet.blueprint.obligations) == 5
    assert length(packet.correspondence) == 5

    for item <- packet.correspondence do
      assert item.formal_check == :not_executed
      assert item.runtime_check == :not_executed
      assert item.implementation_refinement == :not_established
    end

    assert Enum.count(packet.correspondence, &(&1.method == :lean)) == 4
    assert Enum.count(packet.correspondence, &(&1.method == :conformance)) == 1
  end

  test "grant revocation is an explicit runtime obligation, not a claimed Lean theorem" do
    assert %{id: "D-GRANT", method: :conformance, theorem: nil} =
             Enum.find(DispatchPilot.claims(), &(&1.id == "D-GRANT"))

    assert {:ok, packet} = DispatchPilot.compile()
    grant = Enum.find(packet.correspondence, &(&1.obligation_id == "O-D-GRANT"))
    assert grant.lean_theorem == nil
    assert String.ends_with?(grant.runtime_test, "board_authority_concurrency_test.exs")
    assert grant.runtime_check == :not_executed
    assert packet.blueprint.capabilities == []
  end

  test "refuses missing or altered sources without promoting a proof" do
    assert {:error, :invalid_repo_root} = DispatchPilot.audit_sources(nil)

    path =
      Path.join(
        System.tmp_dir!(),
        "proof-bank-dispatch-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    try do
      assert {:error, {:unreadable_source, _}} = DispatchPilot.audit_sources(path)
      file = Path.join(path, "apps/dispatch/lib/dispatch/operations/board.ex")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "def transition(")

      assert {:error, {:missing_anchor, _, _}} = DispatchPilot.audit_sources(path)
    after
      File.rm_rf!(path)
    end
  end

  test "current first-party checkout contains all referenced anchors" do
    root = Path.expand("../../..", __DIR__)

    if File.regular?(Path.join(root, "formal/lean/BizKitDispatch.lean")) do
      assert :ok = DispatchPilot.audit_sources(root)
    end
  end
end
