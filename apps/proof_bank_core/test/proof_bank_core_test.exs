defmodule ProofBankCoreTest do
  use ExUnit.Case, async: true

  defp candidate do
    %{
      id: "dispatch-planner",
      revision: 1,
      title: "Dispatch planning",
      idea: "Propose, never automatically commit, feasible assignments.",
      answers: [
        %{id: "A-2", question: "Who approves?", answer: "A dispatcher."},
        %{id: "A-1", question: "Can trips overlap?", answer: "No."}
      ],
      requirements: [
        %{id: "R-2", statement: "Only dispatcher approval commits.", kind: :behavior,
          answer_ids: ["A-2"]},
        %{id: "R-1", statement: "Active driver trips do not overlap.", kind: :invariant,
          answer_ids: ["A-1"]}
      ],
      obligations: [
        %{id: "O-2", claim: "Check approval-bound commands.", method: :conformance,
          requirement_ids: ["R-2"]},
        %{id: "O-1", claim: "Establish no overlapping active trips.", method: :lean,
          requirement_ids: ["R-1"]}
      ],
      capabilities: ["dispatch.assignment.read", "dispatch.assignment.plan"]
    }
  end

  test "compiles a traced, deterministic, inert blueprint" do
    assert {:ok, result} = ProofBankCore.compile(candidate())
    assert result.schema == "proof-bank.blueprint.v1"
    assert result.verification_state == :unverified
    assert result.activation_state == :inert
    assert Enum.map(result.answers, & &1.id) == ["A-1", "A-2"]
    assert Enum.map(result.obligations, & &1.status) == [:unverified, :unverified]
    assert {:ok, ^result} =
             candidate()
             |> Map.update!(:answers, &Enum.reverse/1)
             |> Map.update!(:requirements, &Enum.reverse/1)
             |> Map.update!(:obligations, &Enum.reverse/1)
             |> ProofBankCore.compile()
  end

  test "rejects unknown fields that might smuggle approval or authority" do
    assert {:error, {:unknown_fields, [:approved]}} =
             candidate() |> Map.put(:approved, true) |> ProofBankCore.compile()
  end

  test "rejects incomplete and malformed interviews" do
    assert {:error, {:invalid_collection, :answers}} =
             candidate() |> Map.put(:answers, []) |> ProofBankCore.compile()

    assert {:error, {:invalid_text, :answer}} =
             candidate()
             |> put_in([:answers, Access.at(0), :answer], "   ")
             |> ProofBankCore.compile()
  end

  test "requires traceability from requirements to answers" do
    assert {:error, {:unknown_answers, ["A-unknown"]}} =
             candidate()
             |> put_in([:requirements, Access.at(0), :answer_ids], ["A-unknown"])
             |> ProofBankCore.compile()
  end

  test "requires every requirement to have at least a pending obligation" do
    assert {:error, {:uncovered_requirements, ["R-2"]}} =
             candidate()
             |> Map.update!(:obligations, &Enum.filter(&1, fn x -> x.id != "O-2" end))
             |> ProofBankCore.compile()
  end

  test "rejects obligations referencing unknown requirements" do
    assert {:error, {:unknown_requirements, ["R-absent"]}} =
             candidate()
             |> put_in([:obligations, Access.at(0), :requirement_ids], ["R-absent"])
             |> ProofBankCore.compile()
  end

  test "rejects duplicate IDs and duplicate references" do
    assert {:error, {:duplicate_ids, :answers}} =
             candidate()
             |> Map.update!(:answers, fn [first, second] -> [first, %{second | id: first.id}] end)
             |> ProofBankCore.compile()

    assert {:error, {:duplicate_references, :answer_ids}} =
             candidate()
             |> put_in([:requirements, Access.at(0), :answer_ids], ["A-2", "A-2"])
             |> ProofBankCore.compile()
  end

  test "rejects fabricated proof statuses and invalid methods" do
    assert {:error, {:unknown_fields, [:status]}} =
             candidate()
             |> update_in([:obligations, Access.at(0)], &Map.put(&1, :status, :proven))
             |> ProofBankCore.compile()

    assert {:error, :invalid_obligation_method} =
             candidate()
             |> put_in([:obligations, Access.at(0), :method], :trust_me)
             |> ProofBankCore.compile()
  end

  test "rejects nonmap, empty IDs and revisions" do
    assert {:error, :expected_map} = ProofBankCore.compile("not a specification")
    assert {:error, {:invalid_identifier, ""}} =
             candidate() |> Map.put(:id, "") |> ProofBankCore.compile()
    assert {:error, :invalid_revision} =
             candidate() |> Map.put(:revision, 0) |> ProofBankCore.compile()
  end
end
