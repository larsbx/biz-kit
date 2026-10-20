defmodule CoopSubstrate.Tasks.DoDRulesTest do
  use ExUnit.Case, async: true
  alias TaskCore.DoD

  @criteria [%{"id" => "report", "description" => "Inspection report reviewed"}]

  test "criteria require nonempty unique bounded identifiers and descriptions" do
    assert :ok = DoD.validate_criteria(@criteria)

    for criteria <- [
          nil,
          %{},
          [],
          ["report"],
          [%{"id" => "report", "description" => ""}],
          [%{"id" => "report", "description" => "  "}],
          [%{"id" => "report/1", "description" => "review"}],
          @criteria ++ @criteria,
          [%{"id" => "report", "description" => "review", "approved" => true}]
        ] do
      assert {:error, :invalid_dod_criteria} = DoD.validate_criteria(criteria)
    end
  end

  test "evidence must cover exactly the criteria with artifact digest references" do
    assert :ok = DoD.validate_evidence(@criteria, %{"report" => {:bytes, <<1::256>>}})

    for evidence <- [
          nil,
          [],
          %{},
          %{"other" => {:bytes, <<1::256>>}},
          %{"report" => "uploaded"},
          %{"report" => {:bytes, <<1>>}},
          %{"report" => true},
          %{"report" => {:bytes, <<1::256>>}, "extra" => {:bytes, <<2::256>>}}
        ] do
      assert {:error, :invalid_dod_evidence} = DoD.validate_evidence(@criteria, evidence)
    end
  end

  test "multi-criterion submissions cannot silently omit one criterion" do
    criteria = @criteria ++ [%{"id" => "photo", "description" => "Photographic record"}]

    assert {:error, :invalid_dod_evidence} =
             DoD.validate_evidence(criteria, %{"report" => {:bytes, <<1::256>>}})

    assert :ok =
             DoD.validate_evidence(criteria, %{
               "report" => {:bytes, <<1::256>>},
               "photo" => {:bytes, <<2::256>>}
             })
  end
end
