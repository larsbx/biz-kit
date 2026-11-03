defmodule BizKit.Extension.UpgradeTest do
  use ExUnit.Case, async: true

  alias BizKit.Extension.Upgrade

  defp baseline do
    %{
      id: "school_ops",
      contract_version: 1,
      version: "1.2.0",
      dependencies: [%{id: "task_adapter", min_version: "1.0.0"}],
      capabilities: ["school_ops.course.read"],
      requested_grants: ["school_ops.workflow.propose"],
      commands: [
        %{
          name: "school_ops.workflow.propose",
          writer: "school_ops",
          required_grants: ["school_ops.workflow.propose"]
        }
      ],
      events: [%{name: "school_ops.workflow.proposed", writer: "school_ops"}],
      projections: [
        %{
          name: "school_ops.workflow_view",
          source_event: "school_ops.workflow.proposed"
        }
      ],
      migrations: [],
      deployment: :integrated,
      activation: :manual,
      health: :host
    }
  end

  test "identical manifest is unchanged, never a deployment approval" do
    assert {:ok, result} = Upgrade.assess(baseline(), baseline())
    assert result.classification == :unchanged
    refute result.requires_review
    assert result.added.capabilities == []
    assert result.added.commands == []
  end

  test "additive upgrade is deterministic and always requires review" do
    old = baseline()

    candidate =
      %{old | version: "1.3.0"}
      |> Map.update!(:capabilities, &["school_ops.lessons.read" | &1])
      |> Map.update!(:requested_grants, &["school_ops.review.perform" | &1])
      |> Map.update!(:events, fn events ->
        [%{name: "school_ops.lesson.reviewed", writer: "school_ops"} | events]
      end)

    assert {:ok, result} = Upgrade.assess(old, candidate)
    assert result.classification == :compatible_additive
    assert result.requires_review
    assert result.added.capabilities == ["school_ops.lessons.read"]
    assert result.added.requested_grants == ["school_ops.review.perform"]
    assert result.added.events == ["school_ops.lesson.reviewed"]
    assert result.added.commands == []
  end

  test "reordered command grants are semantically identical" do
    base = baseline()
    grants = ["school_ops.review.perform", "school_ops.workflow.propose"]
    command = hd(base.commands)

    previous = %{
      base
      | requested_grants: grants,
        commands: [%{command | required_grants: grants}]
    }

    reordered = %{
      previous
      | commands: [%{command | required_grants: Enum.reverse(grants)}]
    }

    assert {:ok, %{classification: :unchanged, requires_review: false}} =
             Upgrade.assess(previous, reordered)

    assert {:ok, %{classification: :compatible_additive, requires_review: true}} =
             Upgrade.assess(previous, %{reordered | version: "1.3.0"})
  end

  test "same-version changes, downgrades, identity swaps and major changes refuse" do
    old = baseline()

    changed = %{old | capabilities: ["school_ops.course.read", "school_ops.new.read"]}

    assert {:error, :manifest_changed_without_version_bump} =
             Upgrade.assess(old, changed)

    assert {:error, :version_downgrade} =
             Upgrade.assess(old, %{old | version: "1.1.9"})

    other = %{
      old
      | id: "dispatch",
        capabilities: ["dispatch.course.read"],
        requested_grants: ["dispatch.workflow.propose"],
        commands: [
          %{
            name: "dispatch.workflow.propose",
            writer: "dispatch",
            required_grants: ["dispatch.workflow.propose"]
          }
        ],
        events: [%{name: "dispatch.workflow.proposed", writer: "dispatch"}],
        projections: [
          %{name: "dispatch.workflow_view", source_event: "dispatch.workflow.proposed"}
        ]
    }

    assert {:error, :extension_identity_changed} = Upgrade.assess(old, other)

    assert {:error, :major_upgrade_requires_separate_migration} =
             Upgrade.assess(old, %{old | version: "2.0.0"})
  end

  test "removing or changing a command contract fails closed" do
    old = baseline()

    for commands <- [
          [],
          [
            %{
              name: "school_ops.workflow.propose",
              writer: "school_ops",
              required_grants: []
            }
          ]
        ] do
      assert {:error, {:removed_or_changed_contract, :commands, "school_ops.workflow.propose"}} =
               Upgrade.assess(old, %{old | version: "1.3.0", commands: commands})
    end
  end

  test "deleting events, projections, dependencies or grant requests refuses" do
    old = baseline()

    assert {:error, {:removed_or_changed_contract, :events, "school_ops.workflow.proposed"}} =
             Upgrade.assess(old, %{old | version: "1.3.0", events: []})

    assert {:error, {:removed_or_changed_contract, :projections, "school_ops.workflow_view"}} =
             Upgrade.assess(old, %{old | version: "1.3.0", projections: []})

    assert {:error, {:removed_or_changed_dependency, "task_adapter"}} =
             Upgrade.assess(old, %{old | version: "1.3.0", dependencies: []})

    assert {:error, {:invalid_field, :commands}} =
             Upgrade.assess(old, %{old | version: "1.3.0", requested_grants: []})
  end

  test "deployment mode cannot silently change under the same contract" do
    old = baseline()

    assert {:error, :execution_contract_changed} =
             Upgrade.assess(old, %{old | version: "1.3.0", deployment: :external})
  end

  test "changing dependency range is not an automatically compatible upgrade" do
    old = baseline()

    candidate =
      %{old | version: "1.3.0", dependencies: [%{id: "task_adapter", min_version: "1.1.0"}]}

    assert {:error, {:removed_or_changed_dependency, "task_adapter"}} =
             Upgrade.assess(old, candidate)
  end

  test "refuse malformed inputs instead of using loosely typed manifest data" do
    assert {:error, {:invalid_field, :manifest}} = Upgrade.assess(nil, baseline())

    assert {:error, {:invalid_fields, :manifest}} =
             Upgrade.assess(baseline(), Map.put(baseline(), :unexpected, true))
  end
end
