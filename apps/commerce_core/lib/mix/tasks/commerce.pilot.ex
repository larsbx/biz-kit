defmodule Mix.Tasks.Commerce.Pilot do
  use Mix.Task
  @shortdoc "Score or export private merchant-pilot evidence offline"
  @moduledoc "Run from CommerceCore: mix commerce.pilot score SNAPSHOT or export INTAKE NEW_DIRECTORY. Starts no application."
  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case CommerceCore.MerchantPilot.CLI.main(args) do
      0 -> :ok
      _ -> Mix.raise("Merchant pilot operation refused; review the private input.")
    end
  end
end
