defmodule Mix.Tasks.Coop.Task.Authority do
  @shortdoc "Inspect current and ended authority in one project"
  @moduledoc """
  Read a bounded page of the project's grants and delegations under a
  governance key. The ledger event ID is the identity of a grant.

      mix coop.task.authority C/T/P [--role operator] [--active true] \
        [--principal PRINCIPAL_ID] [--limit 50] [--after EVENT_ID --snapshot HEAD] \
        [--server URL]

  Principal IDs are the current identity bindings. Legacy registry names,
  wildcard grants and legacy grant IDs convey no authority here.
  """

  use Mix.Task

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops
  alias TaskHost.OperatorClient

  @filters [
    principal: :string,
    role: :string,
    active: :string,
    limit: :string,
    after: :string,
    snapshot: :string
  ]

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    with {opts, [scope], []} <- OptionParser.parse(args, strict: [server: :string] ++ @filters),
         {:ok, {chapter, tenant, project} = scope} <- OperatorClient.scope(scope),
         {:ok, base} <- OperatorClient.server(opts),
         {:ok, signer} <- Ops.load_signer("governance"),
         query = URI.encode_query(Keyword.take(opts, Keyword.keys(@filters))),
         url = base <> OperatorClient.project_path(scope) <> "/authority?" <> query,
         {:ok,
          %{"chapter_id" => ^chapter, "tenant_id" => ^tenant, "project_id" => ^project} = page} <-
           Client.get_signed(url, signer) do
      Mix.shell().info(Jason.encode!(page))
    else
      {:error, reason} -> Mix.raise("authority read refused #{inspect(reason)}")
      _ -> Mix.raise("usage is available through mix help coop.task.authority")
    end
  end
end
