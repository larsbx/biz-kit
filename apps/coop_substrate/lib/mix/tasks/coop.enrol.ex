defmodule Mix.Tasks.Coop.Enrol do
  @shortdoc "Approve a device enrolment: coop.enrol <CODE> [--server URL] [--yes]"
  @moduledoc """
  Approve a person's device enrolment by the code their device showed
  (docs/architecture/2026-10-19-device-enrolment.md):

      mix coop.enrol ABCD-EFGH-JKLM --server https://bizkit.example

  Shows the request (who signed in, for which project, which key and label)
  and, once confirmed, signs the operator grant with the governance key in
  `HARNESS_KEYS_DIR` and submits it to the server, whose ledger admits it.

  Does not start the application: the running server is the only appender.
  `--server` defaults to `$BIZKIT_URL`, then `http://127.0.0.1:4000`.
  """

  use Mix.Task

  alias CoopSubstrate.Enrolments.Approver
  alias CoopSubstrate.Harness.Ops

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, _} = OptionParser.parse(args, strict: [server: :string, yes: :boolean])

    code =
      List.first(positional) || Mix.raise("usage: mix coop.enrol <CODE> [--server URL] [--yes]")

    base = opts[:server] || System.get_env("BIZKIT_URL", "http://127.0.0.1:4000")

    with {:ok, signer} <- Ops.load_signer("governance"),
         {:ok, details} <- Approver.fetch(base, code) do
      Mix.shell().info("""
      Device enrolment #{details["code"]}
        principal  #{details["principal_id"]}
        signed in  #{details["identity"]["subject"]} at #{details["identity"]["issuer"]}
        project    #{details["chapter_id"]} / #{details["tenant_id"]} / #{details["project_id"]}
        device     #{details["label"]} (key #{details["key_id"]})
      Grant it operator access, signed by governance key #{signer.key_id}?
      """)

      if opts[:yes] || Mix.shell().yes?("Approve?") do
        case Approver.approve(base, details, signer) do
          {:ok, %{"event_id" => id}} -> Mix.shell().info("granted: event #{id}")
          {:error, reason} -> Mix.raise("not granted: #{inspect(reason)}")
        end
      else
        Mix.shell().info("not approved; nothing was signed")
      end
    else
      {:error, reason} -> Mix.raise("cannot approve: #{inspect(reason)}")
    end
  end
end
