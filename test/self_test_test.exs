defmodule CoopSubstrate.SelfTestTest do
  # Not async: manipulates global application env and restarts the app.
  use ExUnit.Case, async: false

  alias CoopSubstrate.SelfTest

  setup do
    on_exit(fn ->
      Application.delete_env(:coop_substrate, :self_test_overrides)
      {:ok, _} = Application.ensure_all_started(:coop_substrate)
    end)
  end

  test "self-test passes against the committed vectors" do
    assert SelfTest.run() == :ok
  end

  test "each corrupted known answer is detected" do
    corruptions = [
      {[rfc8032_sig_hex: String.duplicate("00", 64)], :rfc8032_sign_mismatch},
      {[envelope_canonical_hex: "a0"], :envelope_vector_encode_mismatch},
      {[envelope_sha256_hex: String.duplicate("00", 32)], :envelope_vector_hash_mismatch},
      {[envelope_sig_hex: String.duplicate("00", 64)], :envelope_vector_sig_invalid}
    ]

    for {overrides, expected} <- corruptions do
      Application.put_env(:coop_substrate, :self_test_overrides, overrides)
      assert SelfTest.run() == {:error, expected}
    end
  end

  test "corrupting a known-answer vector makes boot fail" do
    :ok = Application.stop(:coop_substrate)

    Application.put_env(:coop_substrate, :self_test_overrides,
      envelope_sig_hex: String.duplicate("00", 64)
    )

    assert {:error, reason} = Application.ensure_all_started(:coop_substrate)
    assert inspect(reason) =~ "crypto_self_test_failed"
    assert inspect(reason) =~ "envelope_vector_sig_invalid"

    Application.delete_env(:coop_substrate, :self_test_overrides)
    assert {:ok, _} = Application.ensure_all_started(:coop_substrate)
  end
end
