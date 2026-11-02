defmodule Mix.Tasks.Coop.Owner.Succeed do
  @shortdoc "Offboard a chapter principal and atomically reassign every project they own"
  @moduledoc """
  Governance-signed chapter-wide offboarding with mandatory successor owners.

      mix coop.owner.succeed DEPARTING_PRINCIPAL CHAPTER \\
        --successor tenant-1/project-1=alice \\
        --successor tenant-1/project-2=bob \\
        --server https://bizkit.example --yes

  The operator's governance seed is read from HARNESS_KEYS_DIR and never
  transmitted. Every command returned by the server is compared to the
  expected canonical offboarding, ownership reassignment and governance-key
  revocations before any signature is emitted.

  The signed request is atomic. An intervening change to the chapter's
  holdings, owners or governance keys is refused at ledger admission. No
  project is transferred merely because the departing principal is assigned
  an operator grant: only projects actually owned by that principal require
  a successor. For single-project offboarding without ownership changes,
  the existing coop.offboard command remains available.
  """
  use Mix.Task

  alias CoopSubstrate.Governance.Client
  alias CoopSubstrate.Harness.Ops
  alias CoopSubstrate.Offboarding.Offboarder
  alias TaskCore.Admission

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, positional, invalid} = parse_options(args)

    unless invalid == [] and length(positional) == 2 do
      Mix.raise(
        "usage: mix coop.owner.succeed PRINCIPAL CHAPTER " <>
          "[--successor TENANT/PROJECT=PRINCIPAL ...] [--server URL] [--yes]"
      )
    end

    [principal, chapter] = positional
    base = opts[:server] || System.get_env("BIZKIT_URL", "http://127.0.0.1:4000")

    with :ok <- segment(chapter),
         {:ok, successors} <- parse_successors(Keyword.get_values(opts, :successor)),
         {:ok, signer} <- Ops.load_signer("governance"),
         {:ok, details} <- Offboarder.fetch(base, principal, signer),
         :ok <- complete?(details, principal, chapter, successors) do
      projects =
        for p <- details["projects"],
            p["chapter_id"] == chapter and p["successor_required"],
            do: "#{p["tenant_id"]}/#{p["project_id"]}"

      Mix.shell().info(
        "Offboard #{principal} from chapter #{chapter} and transfer " <>
          "#{length(projects)} owned project(s): #{Enum.join(projects, ", ")}"
      )

      if opts[:yes] || Mix.shell().yes?("Sign the complete offboarding and succession batch?") do
        url =
          base <> "/api/v1/principals/" <> Client.segment(principal) <>
            "/chapter_offboarding"

        params = %{
          "chapter_id" => chapter,
          "successors" =>
            for {{tenant, project}, next} <- Enum.sort(successors) do
              %{
                "tenant_id" => tenant,
                "project_id" => project,
                "principal_id" => next
              }
            end
        }

        expected = &expected?(&1, details, principal, chapter, signer.key_id, successors)

        case Client.sign_batch(url, signer, expected, params) do
          {:ok, %{"events" => events}} ->
            Mix.shell().info("offboarded with #{length(events)} signed ledger events")

          {:error, reason} ->
            Mix.raise("not offboarded: #{inspect(reason)}")
        end
      else
        Mix.shell().info("nothing was signed")
      end
    else
      {:error, reason} -> Mix.raise("cannot prepare succession: #{inspect(reason)}")
    end
  end

  @doc """
  Parse the command-line switches without collapsing repeated `--successor`
  arguments. Both duplicate detection and multi-project succession depend on
  preserving the complete original sequence.
  """
  def parse_options(args) when is_list(args),
    do: OptionParser.parse(args, strict: [server: :string, yes: :boolean, successor: :keep])

  @doc false
  def parse_successors(items) when is_list(items) do
    Enum.reduce_while(items, {:ok, %{}}, fn value, {:ok, acc} ->
      case String.split(value, "=", parts: 2) do
        [scope, next] when is_binary(next) ->
          case String.split(scope, "/", parts: 2) do
            [tenant, project] ->
              key = {tenant, project}

              if Enum.all?([tenant, project], &(segment(&1) == :ok)) and
                   String.trim(next) != "" and not Map.has_key?(acc, key) do
                {:cont, {:ok, Map.put(acc, key, next)}}
              else
                {:halt, {:error, :invalid_successor_selection}}
              end

            _ ->
              {:halt, {:error, :invalid_successor_selection}}
          end

        _ ->
          {:halt, {:error, :invalid_successor_selection}}
      end
    end)
  end

  def parse_successors(_), do: {:error, :invalid_successor_selection}

  defp segment(s),
    do: if(Admission.segment?(s), do: :ok, else: {:error, :invalid_chapter_or_scope})

  @doc false
  def complete?(%{"principal_id" => stated, "projects" => projects}, principal, chapter, successors)
      when is_list(projects) and is_map(successors) and stated == principal do
    owned =
      for %{
            "chapter_id" => ^chapter,
            "accountable_owner" => ^principal,
            "tenant_id" => tenant,
            "project_id" => project
          } <- projects,
          do: {tenant, project}

    if MapSet.new(owned) == MapSet.new(Map.keys(successors)),
      do: :ok,
      else: {:error, {:successors_do_not_cover_owned_projects, owned}}
  end

  def complete?(_, _, _, _), do: {:error, :invalid_chapter_holdings}

  @doc false
  def expected?(
        cores,
        %{"principal_id" => stated, "projects" => projects, "keys" => keys} = details,
        principal,
        chapter,
        signer_key,
        successors
      )
      when is_list(cores) and is_list(projects) and is_list(keys) and stated == principal do
    chapter_projects =
      for %{"chapter_id" => ^chapter} = p <- projects,
          do: p

    offboardings =
      for p <- Enum.sort_by(chapter_projects, &{&1["tenant_id"], &1["project_id"]}) do
        {"TaskPrincipalOffboardedV1", %{
          "tenant_id" => p["tenant_id"],
          "project_id" => p["project_id"],
          "principal_id" => principal
        }}
      end

    assignments =
      for {{tenant, project}, next} <- Enum.sort(successors) do
        {"TaskProjectOwnerAssignedV1", %{
          "tenant_id" => tenant,
          "project_id" => project,
          "principal_id" => next
        }}
      end

    revocations =
      for key <- keys,
          key["chapter_id"] == chapter,
          do: key["key_id"]

    revocations =
      for key <- Enum.sort_by(revocations, &(&1 == signer_key)) do
        {"RoleKeyRevoked", %{"role" => "governance", "key_id" => key}}
      end

    actual =
      Enum.map(cores, fn core ->
        {core["type"], core["payload"], core["chapter_id"]}
      end)

    complete?(details, principal, chapter, successors) == :ok and
      actual ==
        for {type, payload} <- offboardings ++ assignments ++ revocations do
          {type, payload, chapter}
        end
  end

  def expected?(_, _, _, _, _, _), do: false
end
