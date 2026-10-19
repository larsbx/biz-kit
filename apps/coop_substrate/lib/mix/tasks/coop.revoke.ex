defmodule Mix.Tasks.Coop.Revoke do
  @shortdoc "Revoke a device's grant: coop.revoke <GRANT_ID> [--server URL] [--yes]"
  @moduledoc """
  Revoke an operator or reviewer grant with the governance key
  (docs/architecture/2026-10-19-device-revocation.md): for a person's only
  device when it is lost or compromised, or when they leave, and for any
  reviewer device. People revoke their other operator devices themselves,
  from the web view.

      mix coop.revoke 01J… --server https://bizkit.example

  Shows the grant (principal, project, device label and key) and, once
  confirmed, signs its revocation with the governance key in
  `HARNESS_KEYS_DIR` and submits it to the server. Does not start the
  application. `--server` defaults to `$BIZKIT_URL`, then
  `http://127.0.0.1:4000`.
  """

  use Mix.Task

  alias CoopSubstrate.Devices.Revoker
  alias CoopSubstrate.Harness.Ops

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, _} = OptionParser.parse(args, strict: [server: :string, yes: :boolean])

    id =
      List.first(positional) ||
        Mix.raise("usage: mix coop.revoke <GRANT_ID> [--server URL] [--yes]")

    base = opts[:server] || System.get_env("BIZKIT_URL", "http://127.0.0.1:4000")

    with {:ok, signer} <- Ops.load_signer("governance"),
         {:ok, details} <- Revoker.fetch(base, id) do
      Mix.shell().info("""
      #{String.capitalize(details["role"])} grant #{details["grant_id"]}#{if details["active"], do: "", else: " (already revoked)"}
        principal  #{details["principal_id"]}
        project    #{details["chapter_id"]} / #{details["tenant_id"]} / #{details["project_id"]}
        device     #{details["label"] || "(unlabelled)"} (key #{details["key_id"]})
      Revoke it, signed by governance key #{signer.key_id}?
      """)

      if opts[:yes] || Mix.shell().yes?("Revoke?") do
        case Revoker.revoke(base, details, signer) do
          {:ok, %{"event_id" => event}} -> Mix.shell().info("revoked: event #{event}")
          {:error, reason} -> Mix.raise("not revoked: #{inspect(reason)}")
        end
      else
        Mix.shell().info("not revoked; nothing was signed")
      end
    else
      {:error, reason} -> Mix.raise("cannot revoke: #{inspect(reason)}")
    end
  end
end
