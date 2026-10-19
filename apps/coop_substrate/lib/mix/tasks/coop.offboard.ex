defmodule Mix.Tasks.Coop.Offboard do
  @shortdoc "Offboard a principal from every project: coop.offboard <PRINCIPAL_ID> [--server URL] [--yes]"
  @moduledoc """
  End everything a principal holds, in every project, with the governance
  key (docs/architecture/2026-10-19-offboarding.md): device, suggester and
  reviewer grants, and delegations to or by them.

      mix coop.offboard prn_… --server https://bizkit.example

  Lists what the principal holds per project and, once confirmed, signs one
  `TaskPrincipalOffboardedV1` per project with the governance key in
  `HARNESS_KEYS_DIR` and submits it to the server. Each ends whatever the
  principal holds in that project when the ledger admits it. If it stops
  part-way, running it again offboards the rest. Does not start the
  application. `--server` defaults to `$BIZKIT_URL`, then
  `http://127.0.0.1:4000`.
  """

  use Mix.Task

  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Offboarding.Offboarder

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, _} = OptionParser.parse(args, strict: [server: :string, yes: :boolean])

    principal =
      List.first(positional) ||
        Mix.raise("usage: mix coop.offboard <PRINCIPAL_ID> [--server URL] [--yes]")

    base = opts[:server] || System.get_env("BIZKIT_URL", "http://127.0.0.1:4000")

    with {:ok, signer} <- Ops.load_signer("governance"),
         {:ok, details} <- Offboarder.fetch(base, principal, signer) do
      case details["projects"] do
        [] ->
          Mix.shell().info(
            "#{principal} holds nothing in the chapters this key governs; nothing to offboard"
          )

        projects ->
          Mix.shell().info("""
          Principal #{principal} holds
          #{Enum.map_join(projects, "\n", &describe/1)}
          Offboard it from #{length(projects)} project(s), signed by governance key #{signer.key_id}?
          """)

          if opts[:yes] || Mix.shell().yes?("Offboard?") do
            case Offboarder.offboard(base, details, signer) do
              {:ok, done} ->
                for d <- done,
                    do: Mix.shell().info("offboarded: #{project(d)}, event #{d["event_id"]}")

              {:error, reason} ->
                Mix.raise("not offboarded: #{inspect(reason)}")
            end
          else
            Mix.shell().info("not offboarded; nothing was signed")
          end
      end
    else
      {:error, reason} -> Mix.raise("cannot offboard: #{inspect(reason)}")
    end
  end

  defp project(p), do: "#{p["chapter_id"]} / #{p["tenant_id"]} / #{p["project_id"]}"

  defp describe(p) do
    "  #{project(p)}\n" <>
      Enum.map_join(p["held"], "\n", fn h ->
        "    #{h["kind"]}#{h["direction"] && " (#{h["direction"]})"}  " <>
          "#{h["label"] || "-"}  key #{h["key_id"]}  #{h["event_id"]}"
      end)
  end
end
