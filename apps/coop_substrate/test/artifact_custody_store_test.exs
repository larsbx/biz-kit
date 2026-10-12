defmodule CoopSubstrate.ArtifactCustodyStoreTest do
  use ExUnit.Case, async: false
  alias CoopSubstrate.Harness.Artifacts

  test "exclusive storage verifies retries and refuses to overwrite corrupted historical bytes" do
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

  test "streaming verification enforces its byte budget and leaves no erasure aliases" do
    bytes = :binary.copy("x", 65537)
    hash = :crypto.hash(:sha256, bytes)
    root = Application.get_env(:coop_substrate, :artifact_dir, "priv/artifacts")
    path = Path.join(root, Base.encode16(hash, case: :lower))
    File.rm(path)
    on_exit(fn -> File.rm(path) end)
    assert {:ok, ^hash} = Artifacts.put(bytes)
    assert {:ok, 65537} = Artifacts.verify(hash, 65537)
    assert {:error, :artifact_too_large} = Artifacts.verify(hash, 65536)
    assert {:ok, ^bytes} = Artifacts.get_bounded(hash)
    assert Path.wildcard(path <> ".*") == []
    File.rm!(path)
    assert {:error, :not_found} = Artifacts.verify(hash)
  end

  test "crash-partial final paths fail closed and can be erased without hidden copies" do
    hash = :crypto.hash(:sha256, "complete artifact")
    root = Application.get_env(:coop_substrate, :artifact_dir, "priv/artifacts")
    path = Path.join(root, Base.encode16(hash, case: :lower))
    File.mkdir_p!(root)
    File.write!(path, "complete")
    on_exit(fn -> File.rm(path) end)
    assert {:error, :artifact_tampered} = Artifacts.verify(hash)
    assert {:error, :artifact_tampered} = Artifacts.put("complete artifact")
    File.rm!(path)
    assert Path.wildcard(path <> "*") == []
  end
end
