defmodule ScfHost.ReleaseTasks do
  @moduledoc """
  Local first-run tasks for the `scf` release, run with the server stopped:

      bin/scf eval 'ScfHost.ReleaseTasks.migrate()'
      bin/scf eval 'ScfHost.ReleaseTasks.setup()'

  `setup/0` is idempotent. On this machine it:

  1. creates the governance and accountant signing keys under
     `SCF_DATA_DIR/keys` (0600 seed files, never overwritten);
  2. declares the governance key for `SCF_CHAPTER` if the chapter has none
     (trust on first use), and refuses a chapter governed by another key;
  3. opens the book of `SCF_ENTITY` from `SCF_FIRST_YEAR`, and grants
     (or renews a lapsed grant for) the accountant key;
  4. writes `SCF_DATA_DIR/scf.env` (0600) with everything the host reads,
     printing the console and API tokens once; the file holds only their
     SHA-256 digests, and a rerun never re-issues them. If they are lost,
     `rotate_tokens/0` issues new ones.

  All keys and data stay on this machine.
  """
  alias CoopSubstrate.{Crypto, Log, Scf}
  alias CoopSubstrate.Protocol.Envelope

  @passthrough ~w(EVENTSTORE_HOST EVENTSTORE_PORT EVENTSTORE_USERNAME EVENTSTORE_PASSWORD EVENTSTORE_DATABASE)

  def migrate, do: CoopSubstrate.ReleaseTasks.init_event_stores()

  @doc "Run setup from the environment and report on stdout."
  def setup, do: run(%{})

  @doc """
  Issue new console and API tokens (if the printed ones were lost); their old
  digests stop working, and so do existing sessions. No ledger event.
  """
  def rotate_tokens, do: run(%{rotate_tokens: true})

  defp run(extra) do
    {:ok, _} = Application.ensure_all_started(:coop_substrate)

    case setup(Map.merge(options(System.get_env()), extra)) do
      {:ok, result} ->
        IO.puts(
          "SCF book ready: #{result.entity_id}, exercice #{result.open_year}. Settings: #{result.env_path}"
        )

        if result[:console_token] do
          IO.puts("""

          Console token (shown once; only its digest is stored):
            #{result.console_token}
          API token (Authorization: Bearer …; shown once):
            #{result.api_token}
          """)
        end

        :ok

      {:error, reason} ->
        IO.puts(:stderr, "SCF setup refused: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def options(env) do
    %{
      data_dir: Map.fetch!(env, "SCF_DATA_DIR"),
      chapter_id: Map.get(env, "SCF_CHAPTER", "local"),
      entity_id: Map.fetch!(env, "SCF_ENTITY"),
      accountant_id: Map.get(env, "SCF_ACCOUNTANT", "comptable"),
      first_year:
        env |> Map.get("SCF_FIRST_YEAR", to_string(Date.utc_today().year)) |> String.to_integer(),
      grant_days: env |> Map.get("SCF_GRANT_DAYS", "365") |> String.to_integer(),
      port: env |> Map.get("SCF_PORT", "4090") |> String.to_integer(),
      passthrough: Map.take(env, @passthrough)
    }
  end

  @doc "Idempotent local setup; see the moduledoc."
  def setup(o) do
    keys = Path.join(o.data_dir, "keys")

    # The data directory also holds the pièces: private to this user.
    with :ok <- File.mkdir_p(o.data_dir),
         :ok <- File.chmod(o.data_dir, 0o700),
         {:ok, gov} <- seed(keys, "governance"),
         {:ok, acct} <- seed(keys, "scf_accountant"),
         :ok <- genesis(o.chapter_id, gov),
         :ok <- open_book(o, gov),
         {:ok, version} <- grant(o, gov, acct) do
      write_env(o, acct, version)
    end
  end

  # -- keys -------------------------------------------------------------------------

  defp seed(dir, role) do
    path = Path.join(dir, role <> ".seed")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.chmod(dir, 0o700),
         {:ok, seed} <- read_or_create_seed(path) do
      pubkey = Crypto.pubkey_from_seed(seed)

      {:ok,
       %{
         seed: seed,
         pubkey: pubkey,
         key_id: "k-" <> Base.encode16(binary_part(pubkey, 0, 4), case: :lower)
       }}
    end
  end

  defp read_or_create_seed(path) do
    case File.read(path) do
      {:ok, hex} ->
        Base.decode16(String.trim(hex), case: :mixed)

      {:error, :enoent} ->
        {_pubkey, seed} = Crypto.generate_keypair()
        with :ok <- private_write(path, Base.encode16(seed, case: :lower)), do: {:ok, seed}

      error ->
        error
    end
  end

  # -- ledger -----------------------------------------------------------------------

  defp genesis(chapter, gov) do
    case Log.gate().role_keys[{chapter, "governance"}] do
      nil ->
        append(chapter, gov, "RoleKeyDeclared", %{
          "role" => "governance",
          "key_id" => gov.key_id,
          "pubkey" => {:bytes, gov.pubkey}
        })

      %{} = keys ->
        if keys[gov.key_id] == gov.pubkey,
          do: :ok,
          else: {:error, :chapter_governed_by_another_key}
    end
  end

  defp open_book(o, gov) do
    if Map.has_key?(Scf.state(Log.gate()).books, {o.chapter_id, o.entity_id}),
      do: :ok,
      else:
        append(o.chapter_id, gov, "ScfBookOpenedV1", %{
          "entity_id" => o.entity_id,
          "first_year" => o.first_year
        })
  end

  # A current grant for this key is kept; a missing, lapsed or replaced one is (re)issued.
  defp grant(o, gov, acct) do
    current = Scf.state(Log.gate()).grants[{o.chapter_id, o.entity_id, o.accountant_id}]
    now = Scf.clock_ms()

    case current do
      %{active: true, key_id: key, pubkey: pub, expires_at_ms: exp, version: v}
      when key == acct.key_id and pub == acct.pubkey and exp > now ->
        {:ok, v}

      _ ->
        expected = if current, do: current.version, else: 0

        with :ok <-
               append(o.chapter_id, gov, "ScfAccountantGrantedV1", %{
                 "entity_id" => o.entity_id,
                 "accountant_id" => o.accountant_id,
                 "key_id" => acct.key_id,
                 "pubkey" => {:bytes, acct.pubkey},
                 "active" => true,
                 "expires_at_ms" => now + o.grant_days * 86_400_000,
                 "expected_version" => expected
               }),
             do: {:ok, expected + 1}
    end
  end

  defp append(chapter, gov, type, payload) do
    with {:ok, env} <-
           Envelope.new(
             type: type,
             chapter_id: chapter,
             payload: payload,
             timestamp_ms: div(Scf.clock_ms(), 1_000) * 1_000,
             signers: [%{role: "governance", key_id: gov.key_id, pubkey: gov.pubkey}]
           ),
         {:ok, signed} <- Envelope.sign(env, gov.key_id, gov.seed),
         {:ok, [_]} <- Log.append(signed) do
      :ok
    end
  end

  # -- env file ---------------------------------------------------------------------

  defp write_env(o, acct, version) do
    path = Path.join(o.data_dir, "scf.env")
    existing = if File.exists?(path), do: read_env(path), else: %{}

    {secrets, tokens} =
      case existing do
        %{"SCF_LOGIN_SHA256" => _, "SCF_API_SHA256" => _, "SCF_SECRET_KEY_BASE" => secret}
        when is_map_key(o, :rotate_tokens) ->
          console = token()
          api = token()

          {%{
             "SCF_LOGIN_SHA256" => digest(console),
             "SCF_API_SHA256" => digest(api),
             "SCF_SECRET_KEY_BASE" => secret
           }, %{console_token: console, api_token: api}}

        %{"SCF_LOGIN_SHA256" => _, "SCF_API_SHA256" => _, "SCF_SECRET_KEY_BASE" => _} ->
          {Map.take(existing, ~w(SCF_LOGIN_SHA256 SCF_API_SHA256 SCF_SECRET_KEY_BASE)), %{}}

        _ ->
          console = token()
          api = token()

          {%{
             "SCF_LOGIN_SHA256" => digest(console),
             "SCF_API_SHA256" => digest(api),
             "SCF_SECRET_KEY_BASE" => Base.encode64(:crypto.strong_rand_bytes(64))
           }, %{console_token: console, api_token: api}}
      end

    settings =
      o.passthrough
      |> Map.merge(secrets)
      |> Map.merge(%{
        "SCF_ENABLED" => "true",
        "SCF_PORT" => to_string(o.port),
        "SCF_DATA_DIR" => o.data_dir,
        "SCF_CHAPTER" => o.chapter_id,
        "SCF_ENTITY" => o.entity_id,
        "SCF_ACCOUNTANT" => o.accountant_id,
        "SCF_KEY_ID" => acct.key_id,
        "SCF_SIGNING_SEED_HEX" => Base.encode16(acct.seed, case: :lower),
        "SCF_GRANT_VERSION" => to_string(version)
      })

    body = Enum.map_join(Enum.sort(settings), fn {k, v} -> "#{k}=#{quote_value(v)}\n" end)
    open_year = Scf.state(Log.gate()).books[{o.chapter_id, o.entity_id}].projection.open_year

    with :ok <- if(settings == existing, do: :ok, else: replace(path, body)) do
      {:ok, Map.merge(tokens, %{env_path: path, entity_id: o.entity_id, open_year: open_year})}
    end
  end

  @doc "Parse a setup env file (`KEY='value'` lines)."
  def read_env(path) do
    for line <- path |> File.read!() |> String.split("\n", trim: true),
        [k, v] <- [String.split(line, "=", parts: 2)],
        into: %{},
        do: {k, unquote_value(v)}
  end

  # Single-quoted for POSIX shells (`set -a; . scf.env`); values never hold quotes.
  defp quote_value(v) do
    if String.contains?(v, ["'", "\n"]), do: raise("unquotable setting"), else: "'" <> v <> "'"
  end

  defp unquote_value("'" <> rest), do: String.trim_trailing(rest, "'")
  defp unquote_value(v), do: v

  defp replace(path, body) do
    tmp = path <> ".tmp"
    File.rm(tmp)
    with :ok <- private_write(tmp, body), do: File.rename(tmp, path)
  end

  # Created 0600 before any secret byte is written; never overwrites.
  defp private_write(path, body) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :exclusive, :binary, :raw]) do
      try do
        with :ok <- File.chmod(path, 0o600), :ok <- :file.write(file, body), do: :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp digest(token), do: Base.encode16(:crypto.hash(:sha256, token), case: :lower)
end
