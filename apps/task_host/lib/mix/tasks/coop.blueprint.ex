defmodule Mix.Tasks.Coop.Blueprint do
  @shortdoc "Apply a pinned blueprint: coop.blueprint <CHAPTER>/<TENANT>/<PROJECT> <REPOSITORY> <COMMIT> <PATH>"
  @moduledoc """
  Apply a project's blueprint, its roadmaps and workflows, from a pinned
  source with the governance key
  (docs/architecture/2026-10-20-hierarchy-and-blueprints.md).

      mix coop.blueprint chapter-1/tenant-1/maths school/curriculum <commit> maths/year-7.yaml

  Reads the blueprint at the forge, checking every object against the
  identity the commit declares (`TaskHost.Blueprints.ForgejoVerifier`),
  and shows what it defines. Once confirmed, sends the exact bytes to the
  server, which stores them and prepares a `TaskBlueprintAppliedV1`; the
  key in `HARNESS_KEYS_DIR` signs it only if it applies exactly the bytes
  and source read here. Does not start the application. `--server`
  defaults to `$BIZKIT_URL`, then `http://127.0.0.1:4001`, the task host.

  Add `--source-checkout /path/to/clone` to verify raw Git objects in a local
  GitHub checkout with Git 2.45+ (`TaskHost.Blueprints.LocalGitVerifier`). This
  performs no fetch and ignores working-tree changes and replacement refs.
  The origin must match the repository label; it is not remote authentication.
  The selected commit and path, and the exact bytes verified there, are still
  what the governance key authorizes. Without this option, Forgejo is unchanged.
  """

  use Mix.Task

  alias CoopSubstrate.Blueprints
  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops
  alias TaskHost.Blueprints.SourceVerifier

  @usage "usage: mix coop.blueprint <CHAPTER>/<TENANT>/<PROJECT> <REPOSITORY> <COMMIT> <PATH> [--source-checkout PATH] [--server URL] [--yes]"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [server: :string, yes: :boolean, source_checkout: :string])

    with [] <- invalid,
         [scope, repository, commit, path] <- positional,
         [chapter, tenant, project] <- String.split(scope, "/") do
      base = opts[:server] || CoopSubstrate.Governance.Client.default_server()
      apply_blueprint(base, {chapter, tenant, project}, repository, commit, path, opts)
    else
      _ -> Mix.raise(@usage)
    end
  end

  defp apply_blueprint(base, {chapter, tenant, project}, repository, commit, path, opts) do
    with {:ok, signer} <- Ops.load_signer("governance"),
         {:ok, %{tree: tree, bytes: bytes}} <-
           SourceVerifier.verify(repository, commit, path, Keyword.take(opts, [:source_checkout])),
         {:ok, blueprint} <- Blueprints.read(bytes) do
      source = %{"repository" => repository, "commit" => commit, "tree" => tree, "path" => path}

      Mix.shell().info("""
      #{repository} @ #{commit} (tree #{tree}) #{path}
      manifest sha256: #{Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)}
      #{describe(blueprint)}
      Apply to #{chapter} / #{tenant} / #{project}, signed by governance key #{signer.key_id}?
      """)

      if opts[:yes] || Mix.shell().yes?("Apply?") do
        url =
          "#{String.trim_trailing(base, "/")}/api/v1/chapters/#{Client.segment(chapter)}" <>
            "/tenants/#{Client.segment(tenant)}/projects/#{Client.segment(project)}/blueprints"

        params = Map.put(source, "manifest", Base.url_encode64(bytes, padding: false))

        case Client.sign_held(
               url,
               signer,
               &Blueprints.expected?(&1, {chapter, tenant, project}, source, bytes),
               params
             ) do
          {:ok, %{"event_id" => id}} -> Mix.shell().info("applied: event #{id}")
          {:error, reason} -> Mix.raise("not applied: #{inspect(reason)}")
        end
      else
        Mix.shell().info("not applied; nothing was signed")
      end
    else
      {:error, reason} -> Mix.raise("cannot apply: #{inspect(reason)}")
    end
  end

  defp describe(blueprint) do
    "#{blueprint["project"]["name"]}\n" <>
      Enum.map_join(blueprint["roadmaps"], "\n", fn r ->
        "  #{r["key"]}  #{r["name"]}\n" <>
          Enum.map_join(r["workflows"], "\n", fn w ->
            "    #{w["id"]}  #{w["name"]}  (#{length(w["tasks"])} tasks)"
          end)
      end)
  end
end
