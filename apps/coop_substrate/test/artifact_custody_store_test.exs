defmodule CoopSubstrate.ArtifactCustodyStoreTest do
  use ExUnit.Case, async: false
  alias CoopSubstrate.Harness.Artifacts

  test "atomic storage verifies retries and refuses to overwrite corrupted historical bytes" do
    bytes = "custody-store-test-unique"
    hash = :crypto.hash(:sha256, bytes)

    path =
      Path.join(
        Application.get_env(:coop_substrate, :artifact_dir, "priv/artifacts"),
        Base.encode16(hash, case: :lower)
      )

    File.rm(path)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, ^hash} = Artifacts.put(bytes)
    assert {:ok, ^hash} = Artifacts.put(bytes)
    assert {:ok, ^bytes} = Artifacts.get(hash)
    File.write!(path, "corruption")
    assert {:error, :artifact_tampered} = Artifacts.put(bytes)
    assert File.read!(path) == "corruption"
  end
end
