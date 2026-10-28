defmodule Eatsbot.InputDependencyTest do
  use ExUnit.Case, async: false

  test "unrecognized enum strings cannot grow the atom table" do
    constraints = [one_of: [:enabled, :disabled]]
    assert {:ok, :enabled} = Ash.Type.cast_input(:atom, "enabled", constraints)
    assert {:error, _} = Ash.Type.cast_input(:atom, "warm_up_unknown_enum", constraints)

    suffix = Ash.UUID.generate()
    before_count = :erlang.system_info(:atom_count)

    Enum.each(1..1_000, fn i ->
      assert {:error, _} = Ash.Type.cast_input(:atom, "unknown_#{suffix}_#{i}", constraints)
    end)

    assert :erlang.system_info(:atom_count) - before_count < 8
  end

  test "string bounds count codepoints including combining marks" do
    value = String.duplicate("e\u0301", 16)
    assert String.length(value) == 16
    assert {:error, _} = Ash.Type.apply_constraints(:string, value, max_length: 16)
    assert {:ok, "bounded"} = Ash.Type.apply_constraints(:string, "bounded", max_length: 16)
  end
end
