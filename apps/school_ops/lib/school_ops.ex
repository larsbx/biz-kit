defmodule SchoolOps do
  @moduledoc """
  Read-only access to reviewed K–12 curriculum materials bundled with biz-kit.

  These are **authoring records**, not learner records or evidence of mastery.
  The snapshot has no write API, separate event store or runtime credentials.
  """

  @doc """
  Read a path within the pinned upstream content snapshot.

  Paths must be ordinary forward-slash-separated relative paths. Absolute paths,
  empty segments, dot segments and backslashes are rejected before filesystem
  access. The import contains only regular files, never symbolic links.
  """
  @spec read(String.t()) :: {:ok, binary()} | {:error, term()}
  def read(relative_path) when is_binary(relative_path) do
    if safe_path?(relative_path) do
      case :code.priv_dir(:school_ops) do
        directory when is_list(directory) ->
          File.read(Path.join([List.to_string(directory), "content", relative_path]))

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_path}
    end
  end

  def read(_), do: {:error, :invalid_path}

  defp safe_path?(path) do
    parts = String.split(path, "/", trim: false)

    not String.starts_with?(path, "/") and
      Enum.all?(parts, fn part ->
        part not in ["", ".", ".."] and not String.contains?(part, ["\\", <<0>>])
      end)
  end
end
