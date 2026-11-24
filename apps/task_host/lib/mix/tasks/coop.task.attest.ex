defmodule Mix.Tasks.Coop.Task.Attest do
  @shortdoc "Verify and attest the source of an artifact in task custody"
  @moduledoc """
  Verify Git commit, tree and blob bytes, then sign a source attestation
  as an independent reviewer for the task's existing custody receipt.
  The ledger matches the bytes, slot, task version and project and records
  which reviewer attested the origin.

      mix coop.task.attest C/T/P TASK NAME RECEIPT REPO COMMIT PATH \
        --grant ID --key-id KEY --seed-file PATH --session-file TOKEN_PATH \
        [--source-checkout PATH] [--server URL] [--yes]
  """

  use Mix.Task

  alias TaskCore.Admission
  alias TaskHost.Blueprints.SourceVerifier
  alias TaskHost.OperatorClient, as: Client

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    switches = [
      server: :string,
      grant: :string,
      key_id: :string,
      seed_file: :string,
      session_file: :string,
      source_checkout: :string,
      yes: :boolean
    ]

    with {opts, [scope, task, name, receipt, repo, commit, path], []} <-
           OptionParser.parse(args, strict: switches),
         true <- Admission.segment?(task),
         {:ok, scope} <- Client.scope(scope),
         {:ok, base} <- Client.server(opts),
         {:ok, signer} <- Client.signer(opts),
         {:ok, session} <- Client.session(opts),
         {:ok, %{"task_id" => ^task, "version" => version}} <-
           Client.get(base, scope, "/tasks/#{task}/view", signer),
         {:ok, %{tree: tree, bytes: bytes}} <-
           SourceVerifier.verify_artifact(
             repo,
             commit,
             path,
             Keyword.take(opts, [:source_checkout])
           ) do
      digest = :crypto.hash(:sha256, bytes)
      hex = Base.encode16(digest, case: :lower)
      source = %{"repository" => repo, "commit" => commit, "tree" => tree, "path" => path}

      fields =
        Map.merge(source, %{
          "task_id" => task,
          "name" => name,
          "custody_receipt_id" => receipt,
          "size_bytes" => byte_size(bytes),
          "artifact_digest" => hex
        })

      expected =
        fields
        |> Map.put("expected_version", version)
        |> Map.put("artifact_digest", %{"$bytes" => Base.url_encode64(digest, padding: false)})

      Mix.shell().info(
        "Attest #{inspect(name)} on #{task} at version #{version} from #{repo}@#{commit}:#{path}"
      )

      Mix.shell().info("Tree #{tree}, SHA-256 #{hex}, custody #{receipt}")

      if opts[:yes] || Mix.shell().yes?("Sign this source attestation?") do
        request = Map.put(fields, "action", "attest_artifact")

        with {:ok, held} <-
               Client.prepare(base, scope, session, signer, %{
                 "request" => request,
                 "expect" => expected
               }),
             {:ok, result} <- Client.submit(base, session, signer, held) do
          Mix.shell().info(Jason.encode!(result))
        else
          {:error, reason} -> Mix.raise("artifact attestation refused #{inspect(reason)}")
        end
      else
        Mix.shell().info("artifact attestation declined")
      end
    else
      {:error, reason} -> Mix.raise("artifact attestation refused #{inspect(reason)}")
      _ -> Mix.raise("usage is available through mix help coop.task.attest")
    end
  end
end
