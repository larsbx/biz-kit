defmodule ProofBankCorePortfolioTest do
  use ExUnit.Case, async: true

  alias ProofBankCore.Portfolio

  test "covers the platform and every reviewed inventory row, with no duplicate IDs" do
    entries = Portfolio.entries()
    ids = Enum.map(entries, & &1.id)
    assert length(entries) == 30
    assert length(Enum.uniq(ids)) == length(ids)
    assert "biz-kit" in ids
    assert "proof_bank_core" in ids
    assert "biz_kit_extension" in ids
    assert "dispatch" in ids
    assert "school_ops" in ids
    assert "eatsbot" in ids
  end

  test "all portfolio baselines are structurally traced, draft, inert and unverified" do
    assert {:ok, baselines} = Portfolio.compile_all()
    assert length(baselines) == 30

    for blueprint <- baselines do
      assert blueprint.schema == "proof-bank.blueprint.v1"
      assert blueprint.verification_state == :unverified
      assert blueprint.activation_state == :inert
      assert blueprint.portfolio.review_state == :needs_owner_review
      assert blueprint.portfolio.formal_equivalence == :not_established
      assert blueprint.portfolio.deployment_conformance == :not_established
      assert blueprint.capabilities == []
      assert [%{id: "O-1", status: :unverified}] = blueprint.obligations
      assert [%{id: "R-1", answer_ids: ["A-1"]}] = blueprint.requirements
    end
  end

  test "source model references never produce proven status" do
    assert {:ok, baselines} = Portfolio.compile_all()
    assert Enum.any?(baselines, &is_binary(&1.portfolio.model_candidate))

    for blueprint <- baselines, blueprint.portfolio.model_candidate != nil do
      assert blueprint.verification_state == :unverified
      assert Enum.all?(blueprint.obligations, &(&1.status == :unverified))
    end
  end

  test "audit fails closed on missing repo and exact app membership drift" do
    assert {:error, :missing_umbrella_apps_directory} =
             Portfolio.audit_repo(Path.join(System.tmp_dir!(), "nonexistent-proof-bank-check"))

    root =
      Path.join(
        System.tmp_dir!(),
        "proof-bank-portfolio-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    try do
      File.mkdir_p!(Path.join(root, "apps"))

      assert {:error, {:inventory_drift, %{missing_apps: missing, unregistered_apps: []}}} =
               Portfolio.audit_repo(root)

      assert "dispatch" in missing
      File.mkdir_p!(Path.join([root, "apps", "unknown_plugin"]))
      File.write!(Path.join([root, "apps", "unknown_plugin", "mix.exs"]), "")

      assert {:error, {:inventory_drift, %{unregistered_apps: ["unknown_plugin"]}}} =
               Portfolio.audit_repo(root)
    after
      File.rm_rf!(root)
    end
  end

  test "checked-out umbrella inventory and known model lead paths exist, when available" do
    root = Path.expand("../../..", __DIR__)

    if File.dir?(Path.join(root, "apps")) do
      assert {:ok, %{app_count: 29, verified: 0, activated: 0}} =
               Portfolio.audit_repo(root)

      for entry <- Portfolio.entries() do
        assert File.regular?(Path.join(root, entry.source))

        if entry.model_candidate do
          assert File.regular?(Path.join(root, entry.model_candidate))
        end
      end
    end
  end
end
