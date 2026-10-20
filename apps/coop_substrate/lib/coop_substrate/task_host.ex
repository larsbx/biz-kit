defmodule CoopSubstrate.TaskHost do
  @moduledoc """
  The ledger as `TaskCore`'s host: artifacts are verified in the custody
  store (`Harness.Artifacts`), definitions are named by the canonical
  profile's hash (`Canonical`), and blueprints are YAML in that store.
  """

  @behaviour TaskCore.Host

  @impl true
  def verify_artifact(digest, limit), do: CoopSubstrate.Harness.Artifacts.verify(digest, limit)

  @impl true
  def hash(term), do: CoopSubstrate.Canonical.hash!(term)

  # A blueprint is YAML in the custody store, at most the custody limit
  # (docs/architecture/2026-10-20-hierarchy-and-blueprints.md).
  @impl true
  def read_blueprint(digest) do
    with {:ok, bytes} <- CoopSubstrate.Harness.Artifacts.get_bounded(digest),
         do: CoopSubstrate.Blueprints.decode(bytes)
  end
end
