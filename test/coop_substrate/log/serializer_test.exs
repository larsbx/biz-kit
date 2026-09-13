defmodule CoopSubstrate.Log.SerializerTest do
  use ExUnit.Case, async: true

  alias CoopSubstrate.Log.Serializer

  describe "serialize/1" do
    test "returns nil for nil input" do
      assert Serializer.serialize(nil) == nil
    end

    test "returns the input binary exactly as provided" do
      bytes = <<1, 2, 3, 4, 255>>
      assert Serializer.serialize(bytes) == bytes

      text = "hello world"
      assert Serializer.serialize(text) == text
    end

    test "raises FunctionClauseError for non-binary input" do
      assert_raise FunctionClauseError, fn ->
        Serializer.serialize(%{some: "map"})
      end

      assert_raise FunctionClauseError, fn ->
        Serializer.serialize(123)
      end
    end
  end

  describe "deserialize/2" do
    test "returns the input binary exactly as provided, ignoring config" do
      bytes = <<1, 2, 3, 4, 255>>
      assert Serializer.deserialize(bytes, []) == bytes

      text = "hello world"
      assert Serializer.deserialize(text, %{some: "config"}) == text
    end
  end
end
