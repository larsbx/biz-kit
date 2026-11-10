defmodule TaskHost.Blueprints.SourceVerifier do
  @moduledoc "Fetch and verify immutable blueprint source bytes."

  @callback verify(String.t(), String.t(), String.t()) ::
              {:ok, %{tree: String.t(), digest: String.t(), bytes: binary()}} | {:error, term()}

  def verify(repository, commit, path) do
    module =
      Application.get_env(
        :task_host,
        :blueprint_source_verifier,
        TaskHost.Blueprints.ForgejoVerifier
      )

    module.verify(repository, commit, path)
  end
end
