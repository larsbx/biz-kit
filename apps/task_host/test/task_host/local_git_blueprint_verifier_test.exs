defmodule TaskHost.LocalGitBlueprintVerifierTest do
  use ExUnit.Case, async: false

  alias TaskHost.Blueprints.{LocalGitVerifier, SourceVerifier}

  @repository "acme/plans"
  @path "plans/launch.yaml"
  @bytes "schema_version: 2\nproject: {key: launch, name: Launch}\nroadmaps: []\n"

  defmodule DefaultVerifier do
    def verify(repository, commit, path), do: {:default, repository, commit, path}
  end

  setup do
    checkout =
      Path.join(System.tmp_dir!(), "local-blueprint-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(checkout, "plans"))
    git!(checkout, ["init", "--quiet", "--initial-branch=main"])
    git!(checkout, ["config", "user.name", "Blueprint verifier fixture"])
    git!(checkout, ["config", "user.email", "fixture@example.invalid"])
    git!(checkout, ["config", "remote.origin.url", "https://github.com/acme/plans.git"])
    File.write!(Path.join(checkout, @path), @bytes)
    git!(checkout, ["add", "--", @path])
    git!(checkout, ["-c", "commit.gpgSign=false", "commit", "--quiet", "-m", "Pinned blueprint"])

    fixture = %{
      checkout: checkout,
      commit: git!(checkout, ["rev-parse", "HEAD"]),
      tree: git!(checkout, ["rev-parse", "HEAD^{tree}"]),
      subtree: git!(checkout, ["rev-parse", "HEAD:plans"]),
      blob: git!(checkout, ["rev-parse", "HEAD:" <> @path])
    }

    on_exit(fn -> File.rm_rf!(checkout) end)
    fixture
  end

  test "verifies the raw commit, trees and exact manifest bytes", fixture do
    assert {:ok, %{tree: tree, digest: digest, bytes: @bytes}} = verify(fixture)
    assert tree == fixture.tree
    assert digest == Base.encode16(:crypto.hash(:sha256, @bytes), case: :lower)
  end

  test "reads committed bytes even if the worktree changes or has a symlink", fixture do
    manifest = Path.join(fixture.checkout, @path)
    File.write!(manifest, "uncommitted changes")
    assert {:ok, %{bytes: @bytes}} = verify(fixture)
    File.rm!(manifest)
    File.ln_s!("../outside.yaml", manifest)
    assert {:ok, %{bytes: @bytes}} = verify(fixture)
  end

  test "normalizes the supported GitHub origin labels", fixture do
    for url <- [
          "https://github.com/acme/plans",
          "git@github.com:acme/plans.git",
          "ssh://git@github.com/ACME/PLANS.git"
        ] do
      git!(fixture.checkout, ["config", "remote.origin.url", url])
      assert {:ok, %{bytes: @bytes}} = verify(fixture)
    end
  end

  test "refuses mismatched, credential-bearing and ambiguous origins", fixture do
    assert {:error, _} = verify(fixture, repository: "someone/else")

    for url <- [
          "https://github.com/acme/other.git",
          "https://not-github.example/acme/plans.git",
          "https://secret@github.com/acme/plans.git",
          "https://github.com/acme/plans.git?token=secret",
          "ssh://git@github.com:2222/acme/plans.git"
        ] do
      git!(fixture.checkout, ["config", "remote.origin.url", url])
      assert {:error, message} = verify(fixture)
      refute message =~ "secret"
    end

    git!(fixture.checkout, ["config", "remote.origin.url", "https://github.com/acme/plans.git"])

    git!(fixture.checkout, [
      "config",
      "--add",
      "remote.origin.url",
      "https://github.com/acme/plans.git"
    ])

    assert {:error, _} = verify(fixture)
  end

  test "requires the checkout root and a full lowercase commit pin", fixture do
    for commit <- ["HEAD", String.slice(fixture.commit, 0, 12), String.upcase(fixture.commit)] do
      assert {:error, message} = verify(fixture, commit: commit)
      assert message =~ "40 lowercase"
    end

    assert {:error, _} = verify(fixture, commit: String.duplicate("f", 40))
    assert {:error, _} = verify(fixture, commit: fixture.blob)
    assert {:error, _} = verify(fixture, checkout: Path.join(fixture.checkout, "plans"))
    assert {:error, _} = verify(fixture, checkout: "")
  end

  test "refuses traversal, ambiguous paths, missing files and excessive depth", fixture do
    for path <- [
          "../launch.yaml",
          "/plans/launch.yaml",
          "plans//launch.yaml",
          "plans/./launch.yaml",
          "plans/../launch.yaml",
          "plans\\launch.yaml",
          "",
          String.duplicate("a/", 32) <> "x"
        ] do
      assert {:error, message} = verify(fixture, path: path)
      assert message =~ "relative Git path"
    end

    assert {:error, message} = verify(fixture, path: "plans/missing.yaml")
    assert message =~ "absent"
  end

  test "refuses selected symlinks, executable manifests, and non-tree parents", fixture do
    for mode <- ["120000", "100755", "160000"] do
      subtree = write_object!(fixture.checkout, "tree", entry(mode, "launch.yaml", fixture.blob))
      commit = commit_for_subtree!(fixture, subtree)
      assert {:error, message} = verify(fixture, commit: commit)
      assert message =~ "non-executable regular file"
    end

    tree = write_object!(fixture.checkout, "tree", entry("120000", "plans", fixture.blob))
    commit = commit_for_tree!(fixture, tree)
    assert {:error, message} = verify(fixture, commit: commit)
    assert message =~ "must traverse trees"
  end

  for {label, key, type} <- [
        {"commit", :commit, "commit"},
        {"root tree", :tree, "tree"},
        {"subtree", :subtree, "tree"},
        {"blob", :blob, "blob"}
      ] do
    test "refuses corrupt #{label} bytes stored under the pinned object identity", fixture do
      oid = Map.fetch!(fixture, unquote(key))
      type = unquote(type)
      {original, 0} = System.cmd("git", ["-C", fixture.checkout, "cat-file", type, oid])

      # Preserve valid structure and the entire selected path. Without this
      # object's hash check the verifier would still return a valid manifest.
      changed =
        if type == "tree",
          do: original <> entry("100644", "z-injected.yaml", fixture.blob),
          else: original <> "# substituted bytes\n"

      replace_object!(fixture.checkout, oid, type, changed)
      assert {:error, message} = verify(fixture)
      assert message =~ "does not hash to #{oid}"
    end
  end

  test "refuses duplicate, truncated, malformed and unordered raw tree entries", fixture do
    good = entry("100644", "launch.yaml", fixture.blob)

    for bytes <- [
          good <> good,
          binary_part(good, 0, byte_size(good) - 1),
          entry("999999", "launch.yaml", fixture.blob),
          entry("100644", "../launch.yaml", fixture.blob),
          entry("100644", "z.yaml", fixture.blob) <> good
        ] do
      subtree = write_object!(fixture.checkout, "tree", bytes)
      commit = commit_for_subtree!(fixture, subtree)
      assert {:error, message} = verify(fixture, commit: commit)
      assert message =~ "Git tree entry"
    end
  end

  test "hashes signed commit bytes without reconstructing dates or signatures", fixture do
    bytes = """
    tree #{fixture.tree}
    author Example <fixture@example.invalid> 1700000000 +0545
    committer Example <fixture@example.invalid> 1700000001 -0330
    gpgsig -----BEGIN PGP SIGNATURE-----
     fixture signature bytes; no signature trust is claimed
     -----END PGP SIGNATURE-----

    Exact commit message\n
    """

    commit = write_object!(fixture.checkout, "commit", bytes)
    assert {:ok, %{tree: tree, bytes: @bytes}} = verify(fixture, commit: commit)
    assert tree == fixture.tree
  end

  test "rejects a commit with more than one declared root tree", fixture do
    bytes = "tree #{fixture.tree}\ntree #{fixture.tree}\n\nambiguous commit\n"
    commit = write_object!(fixture.checkout, "commit", bytes)
    assert {:error, message} = verify(fixture, commit: commit)
    assert message =~ "exactly one root tree"
  end

  test "ignores replacement refs and refuses a missing original object", fixture do
    blob = write_object!(fixture.checkout, "blob", "replacement source\n")
    subtree = write_object!(fixture.checkout, "tree", entry("100644", "launch.yaml", blob))
    replacement = commit_for_subtree!(fixture, subtree)
    git!(fixture.checkout, ["replace", fixture.commit, replacement])
    assert {:ok, %{bytes: @bytes}} = verify(fixture)

    File.rm!(object_path(fixture.checkout, fixture.commit))
    assert {:error, _} = verify(fixture)
  end

  test "does not lazily fetch missing objects or invoke a configured remote helper", fixture do
    marker = Path.join(fixture.checkout, "remote-helper-was-run")
    helper = Path.join(fixture.checkout, "helper.sh")
    File.write!(helper, "#!/bin/sh\ntouch '#{marker}'\nexit 1\n")
    git!(fixture.checkout, ["config", "extensions.partialClone", "object-source"])
    git!(fixture.checkout, ["config", "remote.object-source.promisor", "true"])
    git!(fixture.checkout, ["config", "remote.object-source.url", "ext::/bin/sh #{helper}"])
    git!(fixture.checkout, ["config", "protocol.ext.allow", "always"])
    File.rm!(object_path(fixture.checkout, fixture.blob))

    assert {:error, _} = verify(fixture)
    refute File.exists?(marker)
  end

  test "ignores ambient Git directory overrides", fixture do
    previous = System.get_env("GIT_DIR")
    System.put_env("GIT_DIR", Path.join(fixture.checkout, "nonexistent"))
    on_exit(fn -> restore_env("GIT_DIR", previous) end)
    assert {:ok, %{bytes: @bytes}} = verify(fixture)
  end

  test "enforces both the configured limit and the hard 1 MiB manifest bound", fixture do
    previous = Application.get_env(:task_host, :blueprint_max_bytes)
    on_exit(fn -> restore(:blueprint_max_bytes, previous) end)
    Application.put_env(:task_host, :blueprint_max_bytes, 8)
    assert {:error, message} = verify(fixture)
    assert message =~ "exceeds 8 bytes"

    Application.put_env(:task_host, :blueprint_max_bytes, 10_000_000)
    blob = write_object!(fixture.checkout, "blob", String.duplicate("x", 1_048_577))
    subtree = write_object!(fixture.checkout, "tree", entry("100644", "launch.yaml", blob))
    commit = commit_for_subtree!(fixture, subtree)
    assert {:error, message} = verify(fixture, commit: commit)
    assert message =~ "exceeds 1048576 bytes"
  end

  test "local selection is explicit and never falls back on verification failure", fixture do
    previous = Application.get_env(:task_host, :blueprint_source_verifier)
    Application.put_env(:task_host, :blueprint_source_verifier, DefaultVerifier)
    on_exit(fn -> restore(:blueprint_source_verifier, previous) end)

    assert {:default, @repository, commit, @path} =
             SourceVerifier.verify(@repository, fixture.commit, @path)

    assert commit == fixture.commit

    assert {:ok, %{bytes: @bytes}} =
             SourceVerifier.verify(@repository, fixture.commit, @path,
               source_checkout: fixture.checkout
             )

    assert {:error, _} =
             SourceVerifier.verify(@repository, fixture.commit, @path, source_checkout: nil)
  end

  defp verify(fixture, opts \\ []) do
    LocalGitVerifier.verify(
      Keyword.get(opts, :repository, @repository),
      Keyword.get(opts, :commit, fixture.commit),
      Keyword.get(opts, :path, @path),
      Keyword.get(opts, :checkout, fixture.checkout)
    )
  end

  defp commit_for_subtree!(fixture, subtree) do
    tree = write_object!(fixture.checkout, "tree", entry("40000", "plans", subtree))
    commit_for_tree!(fixture, tree)
  end

  defp commit_for_tree!(fixture, tree) do
    write_object!(fixture.checkout, "commit", """
    tree #{tree}
    author Fixture <fixture@example.invalid> 1700000000 +0000
    committer Fixture <fixture@example.invalid> 1700000000 +0000

    Pinned fixture
    """)
  end

  defp entry(mode, name, oid),
    do: mode <> " " <> name <> <<0>> <> Base.decode16!(oid, case: :lower)

  defp write_object!(checkout, type, bytes) do
    raw = "#{type} #{byte_size(bytes)}\0" <> bytes
    oid = :crypto.hash(:sha, raw) |> Base.encode16(case: :lower)
    replace_object!(checkout, oid, type, bytes)
    oid
  end

  defp replace_object!(checkout, oid, type, bytes) do
    path = object_path(checkout, oid)
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
    File.write!(path, :zlib.compress("#{type} #{byte_size(bytes)}\0" <> bytes))
  end

  defp object_path(checkout, <<prefix::binary-size(2), suffix::binary>>),
    do: Path.join([checkout, ".git", "objects", prefix, suffix])

  defp git!(checkout, args) do
    {out, 0} =
      System.cmd("git", ["-C", checkout] ++ args,
        env: [{"GIT_CONFIG_NOSYSTEM", "1"}, {"GIT_CONFIG_GLOBAL", "/dev/null"}],
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp restore(key, nil), do: Application.delete_env(:task_host, key)
  defp restore(key, value), do: Application.put_env(:task_host, key, value)
  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
