defmodule TaskCore.Blueprint.Source do
  @moduledoc """
  Portable, immutable Git blueprint identity. This validates syntax, not Git
  objects: the host must verify the commit/tree/blob chain and retain the
  manifest bytes under their SHA-256 digest before admitting an application.
  No network, decoder, ledger or storage is required here.
  """

  @fields ~w(repository commit tree path manifest_digest)
  @repository ~r/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/
  @object ~r/\A[0-9a-f]{40}\z/
  @path ~r/\A[A-Za-z0-9._\/-]{1,512}\z/

  @doc "Validate a source map and select its identity fields; commit and tree use SHA-1, as the current forge verifier does."
  def normalize(%{"manifest_digest" => {:bytes, <<_::256>>}} = source) do
    with true <- matches?(@repository, source["repository"]),
         true <- matches?(@object, source["commit"]),
         true <- matches?(@object, source["tree"]),
         true <- matches?(@path, source["path"]),
         true <- Enum.all?(String.split(source["path"], "/"), &(&1 not in ["", ".", ".."])) do
      {:ok, Map.take(source, @fields)}
    else
      _ -> {:error, :invalid_blueprint_source}
    end
  end

  def normalize(_), do: {:error, :invalid_blueprint_source}

  defp matches?(regex, value), do: is_binary(value) and Regex.match?(regex, value)
end
