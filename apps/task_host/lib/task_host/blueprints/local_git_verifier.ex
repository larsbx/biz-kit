defmodule TaskHost.Blueprints.LocalGitVerifier do
  @moduledoc """
  Verify a blueprint in an explicitly selected, complete local Git checkout.

  Rehashes the raw commit, every tree on the selected path, and the final blob.
  Working-tree files, replacement refs, filters and network fetches are not used.
  The caller supplies the immutable commit identity; the GitHub origin is only
  a repository-label consistency check, not proof of remote ownership or trust.

  Requires Git 2.45+ for `--no-lazy-fetch`. The manifest must be a non-executable
  regular file, at most 1 MiB (or the smaller `:blueprint_max_bytes` setting).
  """

  @max_bytes 1_048_576
  @max_commit_bytes 65_536
  @command_timeout_ms 5_000
  @oid ~r/\A[0-9a-f]{40}\z/
  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @path ~r/\A[A-Za-z0-9._\/-]{1,512}\z/

  @spec verify(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{tree: String.t(), digest: String.t(), bytes: binary()}} | {:error, term()}
  def verify(repository, commit, path, checkout) do
    with :ok <- valid_source(repository, commit, path, checkout),
         {:ok, git} <- git_context(checkout),
         :ok <- repository_matches(git, repository),
         {:ok, raw_commit} <- object(git, "commit", commit, @max_commit_bytes),
         {:ok, root_tree} <- commit_tree(raw_commit),
         {:ok, blob} <- walk(git, root_tree, String.split(path, "/")),
         {:ok, max_bytes} <- manifest_limit(),
         {:ok, bytes} <- object(git, "blob", blob, max_bytes) do
      {:ok,
       %{
         tree: root_tree,
         digest: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
         bytes: bytes
       }}
    end
  end

  defp valid_source(repository, commit, path, checkout)
       when is_binary(repository) and is_binary(commit) and is_binary(path) and
              is_binary(checkout) do
    segments = String.split(path, "/")

    cond do
      byte_size(repository) > 200 or not Regex.match?(@repository, repository) or
          Enum.any?(String.split(repository, "/"), &(&1 in [".", ".."])) ->
        {:error, "repository must be OWNER/REPO"}

      not Regex.match?(@oid, commit) ->
        {:error, "commit must be exactly 40 lowercase hexadecimal characters"}

      not Regex.match?(@path, path) or length(segments) > 32 or
          Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        {:error,
         "manifest path must be a relative Git path without traversal (at most 32 segments)"}

      checkout == "" or String.contains?(checkout, <<0>>) or not File.dir?(checkout) ->
        {:error, "source checkout must be an existing Git checkout directory"}

      true ->
        :ok
    end
  end

  defp valid_source(_, _, _, _), do: {:error, "invalid local Git source"}

  defp git_context(checkout) do
    case System.find_executable("git") do
      nil ->
        {:error, "local source verification requires Git 2.45+"}

      executable ->
        git = %{executable: executable, checkout: Path.expand(checkout), env: git_env()}

        with {:ok, "sha1\n"} <- run(git, ["rev-parse", "--show-object-format"]),
             {:ok, root} <- run(git, ["rev-parse", "--show-toplevel"]),
             true <- String.trim_trailing(root, "\n") == git.checkout do
          {:ok, git}
        else
          {:error, _} = error -> error
          _ -> {:error, "source checkout must be the root of a SHA-1 Git working tree"}
        end
    end
  end

  defp repository_matches(git, expected) do
    with {:ok, origin} <-
           run(git, ["config", "--local", "--no-includes", "--get-all", "remote.origin.url"]),
         [_, label] <-
           Regex.run(
             ~r/\A(?:https:\/\/github\.com\/|ssh:\/\/git@github\.com\/|git@github\.com:)([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)\n\z/i,
             origin
           ),
         true <-
           String.downcase(String.replace_suffix(label, ".git", "")) == String.downcase(expected) do
      :ok
    else
      _ -> {:error, "source checkout must have one GitHub origin matching the repository label"}
    end
  end

  defp manifest_limit do
    case Application.get_env(:task_host, :blueprint_max_bytes, @max_bytes) do
      limit when is_integer(limit) and limit > 0 -> {:ok, min(limit, @max_bytes)}
      _ -> {:error, "blueprint_max_bytes must be a positive integer"}
    end
  end

  defp object(git, type, oid, max_bytes) do
    with {:ok, actual_type} <- run(git, ["cat-file", "-t", oid]),
         true <- actual_type == type <> "\n" or {:error, "expected a Git #{type} object"},
         {:ok, size_text} <- run(git, ["cat-file", "-s", oid]),
         {size, "\n"} when size >= 0 <- Integer.parse(size_text),
         true <- size <= max_bytes or {:error, "Git #{type} exceeds #{max_bytes} bytes"},
         {:ok, bytes} <- run(git, ["cat-file", type, oid], max_bytes),
         true <-
           byte_size(bytes) == size or {:error, "Git #{type} size changed during verification"},
         true <- hash(type, bytes) == oid or {:error, "Git #{type} does not hash to #{oid}"} do
      {:ok, bytes}
    else
      {:error, _} = error -> error
      _ -> {:error, "invalid Git #{type} size"}
    end
  end

  defp hash(type, bytes),
    do:
      :crypto.hash(:sha, "#{type} #{byte_size(bytes)}\0" <> bytes)
      |> Base.encode16(case: :lower)

  defp commit_tree(bytes) do
    with [headers, _message] <- :binary.split(bytes, "\n\n"),
         ["tree " <> tree | rest] <- :binary.split(headers, "\n", [:global]),
         true <- Regex.match?(@oid, tree),
         false <- Enum.any?(rest, &String.starts_with?(&1, "tree ")) do
      {:ok, tree}
    else
      _ -> {:error, "Git commit must declare exactly one root tree"}
    end
  end

  defp walk(git, tree, [name | remaining]) do
    with {:ok, bytes} <- object(git, "tree", tree, @max_bytes),
         {:ok, entries} <- tree_entries(bytes, %{}, nil),
         {:ok, {mode, oid}} <- Map.fetch(entries, name) do
      case {mode, remaining} do
        {"40000", [_ | _]} ->
          walk(git, oid, remaining)

        {"100644", []} ->
          {:ok, oid}

        _ ->
          {:error, "manifest path must traverse trees and end in a non-executable regular file"}
      end
    else
      :error -> {:error, "manifest path is absent from the verified Git tree"}
      {:error, _} = error -> error
    end
  end

  defp tree_entries(<<>>, entries, _previous), do: {:ok, entries}

  defp tree_entries(bytes, entries, previous) do
    with [header, <<oid::binary-size(20), rest::binary>>] <- :binary.split(bytes, <<0>>),
         [mode, name] <- :binary.split(header, " "),
         true <- mode in ["40000", "100644", "100755", "120000", "160000"],
         true <- name not in ["", ".", ".."] and not String.contains?(name, "/"),
         false <- Map.has_key?(entries, name),
         order = name <> if(mode == "40000", do: "/", else: ""),
         true <- is_nil(previous) or previous < order do
      tree_entries(rest, Map.put(entries, name, {mode, Base.encode16(oid, case: :lower)}), order)
    else
      _ -> {:error, "invalid, duplicate, truncated or unordered Git tree entry"}
    end
  end

  # Ignore ambient Git settings that can redirect object reads or inject config.
  # Raw cat-file does not run working-tree filters or hooks. Missing objects are
  # refused, so promisor remotes and their configured helpers cannot be invoked.
  defp git_env do
    System.get_env()
    |> Enum.filter(fn {key, _} -> String.starts_with?(key, "GIT_") end)
    |> Map.new(fn {key, _} -> {key, nil} end)
    |> Map.merge(%{
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_OPTIONAL_LOCKS" => "0"
    })
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
    end)
  end

  # Bound the subprocess stream itself, not only Git's reported object size.
  # Argument vectors never pass through a shell. Stderr may contain local config
  # secrets; return a fixed error rather than forwarding subprocess output.
  defp run(git, args, limit \\ 2_048) do
    args =
      [
        "--no-pager",
        "--no-replace-objects",
        "--no-lazy-fetch",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "core.fsmonitor=false",
        "-C",
        git.checkout
      ] ++ args

    port =
      Port.open({:spawn_executable, String.to_charlist(git.executable)}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: Enum.map(args, &String.to_charlist/1),
        env: git.env
      ])

    try do
      collect(port, [], 0, limit, System.monotonic_time(:millisecond) + @command_timeout_ms)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ in [ArgumentError, ErlangError] -> {:error, "could not execute local Git"}
  end

  defp collect(port, chunks, size, limit, deadline) do
    receive do
      {^port, {:data, bytes}} when size + byte_size(bytes) <= limit ->
        collect(port, [bytes | chunks], size + byte_size(bytes), limit, deadline)

      {^port, {:data, _bytes}} ->
        {:error, "local Git output exceeds #{limit} bytes"}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _status}} ->
        {:error,
         "local Git read failed; requires Git 2.45+ and all pinned objects locally available"}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {:error, "local Git read timed out"}
    end
  end
end
