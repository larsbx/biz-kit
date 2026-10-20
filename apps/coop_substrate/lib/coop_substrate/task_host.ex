defmodule CoopSubstrate.TaskHost do
  @moduledoc """
  The ledger as `TaskCore`'s host: artifacts are verified in the custody
  store (`Harness.Artifacts`), and definitions are named by the canonical
  profile's hash (`Canonical`).
  """

  @behaviour TaskCore.Host

  @impl true
  def verify_artifact(digest, limit), do: CoopSubstrate.Harness.Artifacts.verify(digest, limit)

  @impl true
  def hash(term), do: CoopSubstrate.Canonical.hash!(term)
end
