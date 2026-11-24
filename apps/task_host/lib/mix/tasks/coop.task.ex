defmodule Mix.Tasks.Coop.Task do
  @shortdoc "Read scoped work and sign a reviewed task command"
  @moduledoc """
  Read tasks, checklists, hierarchy or the current project grant.

      mix coop.task list C/T/P --grant ID --key-id KEY --seed-file PATH
      mix coop.task show C/T/P TASK --grant ID --key-id KEY --seed-file PATH
      mix coop.task todo-list C/T/P TASK --grant ID --key-id KEY --seed-file PATH
      mix coop.task hierarchy C/T/P --grant ID --key-id KEY --seed-file PATH
      mix coop.task whoami C/T/P --grant ID --key-id KEY --seed-file PATH
      mix coop.task verify-sop C/T/P TASK FILE --grant ID --key-id KEY --seed-file PATH
      mix coop.task projects --session-file TOKEN_PATH

  List accepts `--state` or `--open`, plus `--roadmap`, `--workflow`, `--text` and `--limit`.
  Continue with the same filters, `--after` and `--snapshot` from the result.

  Sign a JSON intent with `request` (one task-host command) and `expect`
  (the complete reviewed event payload except scope, principal and grant).
  Use `{"$bytes": "base64url"}` for byte-string fields. The device signs
  only a matching held command under the named active grant.

      mix coop.task act C/T/P INTENT.json --session-file TOKEN_PATH \
        --grant ID --key-id KEY --seed-file PATH [--yes]

  Use a private file containing a bearer obtained from the native sign-in
  exchange. Uploading bytes under that session gives their digest.

      mix coop.task upload C/T/P FILE --session-file TOKEN_PATH [--evidence-for TASK]

  Provision a CLI device using the existing governance approval.

      mix coop.task keygen PATH
      mix coop.task enrol C/T/P LABEL --seed-file PATH --session-file TOKEN_PATH [--role reviewer]
      mix coop.task devices C/T/P --session-file TOKEN_PATH

  Use `id` or `validate-id ID` for the published legacy task ID spelling.
  An ID names no authority. The server is selected with `--server` or `BIZKIT_URL`.
  """

  use Mix.Task

  alias TaskHost.OperatorClient, as: Client
  alias TaskCore.Admission

  @options [
    server: :string,
    grant: :string,
    key_id: :string,
    seed_file: :string,
    session_file: :string,
    yes: :boolean,
    evidence_for: :string,
    state: :string,
    open: :boolean,
    roadmap: :string,
    workflow: :string,
    text: :string,
    limit: :string,
    after: :string,
    snapshot: :string,
    role: :string
  ]
  @filters [:state, :open, :roadmap, :workflow, :text, :limit, :after, :snapshot]

  @impl true
  def run(["id"]) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%dT%H%M%SZ")
    nonce = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
    print(%{id: "tsk-" <> stamp <> "-" <> nonce})
  end

  def run(["validate-id", id]) do
    with [_, stamp] <- Regex.run(~r/\Atsk-(\d{8}T\d{6}Z)-[0-9a-f]{8}\z/, id),
         {:ok, _, 0} <- DateTime.from_iso8601(stamp, :basic) do
      print(%{id: id, valid: true})
    else
      _ -> Mix.raise("invalid task ID")
    end
  end

  def run(["keygen", path]), do: print(unwrap(Client.keygen(path)))

  def run(["projects" | args]) do
    Mix.Task.run("app.config")

    case OptionParser.parse(args, strict: @options) do
      {opts, [], []} ->
        base = unwrap(Client.server(opts))
        session = unwrap(Client.session(opts))
        params = Map.new(Keyword.take(opts, [:limit, :after, :snapshot]))
        print(unwrap(Client.projects(base, session, params)))

      _ ->
        usage()
    end
  end

  def run(args) do
    Mix.Task.run("app.config")

    with {opts, [action, scope | rest], []} <- OptionParser.parse(args, strict: @options),
         {:ok, scope} <- Client.scope(scope),
         {:ok, base} <- Client.server(opts) do
      dispatch(action, rest, base, scope, opts)
    else
      {:error, reason} -> Mix.raise("task command refused #{inspect(reason)}")
      _ -> usage()
    end
  end

  defp dispatch("list", [], base, scope, opts) do
    params = Map.new(Keyword.take(opts, @filters))
    read(base, scope, "/tasks", opts, params) |> print()
  end

  defp dispatch("hierarchy", [], base, scope, opts),
    do: print(read(base, scope, "/hierarchy", opts))

  defp dispatch("whoami", [], base, scope, opts),
    do: print(read(base, scope, "/access", opts))

  defp dispatch(action, [id], base, scope, opts) when action in ~w(show todo-list) do
    unless Admission.segment?(id), do: Mix.raise("invalid scoped task ID")
    result = read(base, scope, "/tasks/#{id}/view", opts)
    unless result["task_id"] == id, do: Mix.raise("task response did not match the requested ID")

    print(
      if(action == "todo-list",
        do: Map.take(result, ~w(chapter_id tenant_id project_id task_id todos)),
        else: result
      )
    )
  end

  defp dispatch("verify-sop", [id, file], base, scope, opts) do
    unless Admission.segment?(id), do: Mix.raise("invalid scoped task ID")
    task = read(base, scope, "/tasks/#{id}/view", opts)
    unless task["task_id"] == id, do: Mix.raise("task response did not match the requested ID")
    pin = unwrap(Client.verify_sop(task, file))
    print(Map.merge(Map.take(task, ~w(chapter_id tenant_id project_id task_id version)), pin))
  end

  defp dispatch("upload", [file], base, scope, opts) do
    session = unwrap(Client.session(opts))
    print(unwrap(Client.upload(base, scope, session, file, opts[:evidence_for])))
  end

  defp dispatch("enrol", [label], base, scope, opts) do
    session = unwrap(Client.session(opts))
    seed = unwrap(Client.seed(opts[:seed_file]))
    print(unwrap(Client.enrol(base, scope, session, seed, label, opts[:role] || "operator")))
  end

  defp dispatch("devices", [], base, scope, opts) do
    session = unwrap(Client.session(opts))
    print(unwrap(Client.devices(base, scope, session)))
  end

  defp dispatch("act", [file], base, scope, opts) do
    session = unwrap(Client.session(opts))
    signer = unwrap(Client.signer(opts))
    intent = unwrap(read_intent(file))
    held = unwrap(Client.prepare(base, scope, session, signer, intent))

    if opts[:yes] ||
         Mix.shell().yes?(
           "Sign reviewed #{held.type} for #{Tuple.to_list(scope) |> Enum.join("/")}?"
         ) do
      print(unwrap(Client.submit(base, session, signer, held)))
    else
      Mix.shell().info("command declined")
    end
  end

  defp dispatch(_, _, _, _, _), do: usage()

  defp read(base, scope, suffix, opts, params \\ %{}) do
    signer = unwrap(Client.signer(opts))
    unwrap(Client.get(base, scope, suffix, signer, params))
  end

  defp read_intent(file) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size in 1..131_072 <- File.stat(file),
         {:ok, bytes} when byte_size(bytes) == size <- File.read(file),
         {:ok, %{"request" => %{}, "expect" => %{}} = intent}
         when map_size(intent) == 2 <- Jason.decode(bytes) do
      {:ok, intent}
    else
      _ -> {:error, :bad_intent}
    end
  end

  defp print(result), do: Mix.shell().info(Jason.encode!(result))
  defp unwrap({:ok, result}), do: result
  defp unwrap({:error, reason}), do: Mix.raise("task command refused #{inspect(reason)}")
  defp usage, do: Mix.raise("usage is available through mix help coop.task")
end
