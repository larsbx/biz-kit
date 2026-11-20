defmodule ScfHost.ReleaseTasksTest do
  @moduledoc "Local first-run setup: keys, genesis, book, grant and env file, then a real sign-in."
  use CoopSubstrate.LogCase, async: false
  import Plug.Test
  alias CoopSubstrate.{Log, ProcurementTestClock, Scf}
  alias ScfHost.ReleaseTasks

  @now 1_800_000_000_000

  setup do
    ProcurementTestClock.set(@now)
    dir = Path.join(System.tmp_dir!(), "scf-setup-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    opts = %{
      data_dir: dir,
      chapter_id: "local",
      entity_id: "sarl-atlas",
      accountant_id: "comptable",
      first_year: 2026,
      grant_days: 365,
      port: 4090,
      passthrough: %{"EVENTSTORE_DATABASE" => "scf_eventstore"}
    }

    {:ok, opts: opts}
  end

  test "first run creates local keys, the book, the grant and a private env file", %{opts: opts} do
    assert {:ok, %{console_token: token, api_token: api, env_path: path}} =
             ReleaseTasks.setup(opts)

    assert byte_size(token) >= 43 and byte_size(api) >= 43

    assert %File.Stat{mode: mode} = File.stat!(path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert Bitwise.band(File.stat!(Path.join(opts.data_dir, "keys/governance.seed")).mode, 0o777) ==
             0o600

    assert Bitwise.band(File.stat!(opts.data_dir).mode, 0o777) == 0o700

    env = ReleaseTasks.read_env(path)
    assert env["SCF_ENABLED"] == "true" and env["SCF_ENTITY"] == "sarl-atlas"
    assert env["SCF_DATA_DIR"] == opts.data_dir and env["EVENTSTORE_DATABASE"] == "scf_eventstore"
    assert env["SCF_LOGIN_SHA256"] == Base.encode16(:crypto.hash(:sha256, token), case: :lower)
    refute File.read!(path) =~ token

    s = Scf.state(Log.gate())
    assert %{first_year: 2026} = s.books[{"local", "sarl-atlas"}]
    assert %{active: true, version: 1} = s.grants[{"local", "sarl-atlas", "comptable"}]

    # The env file is exactly what the console needs: sign in with the token.
    Application.put_env(:scf_host, :settings, ScfHost.Auth.from_env!(env))

    form =
      ScfHost.Web.call(conn(:get, "/login") |> Map.put(:scheme, :https), ScfHost.Web.init([]))

    [_, csrf] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, form.resp_body)
    Plug.CSRFProtection.delete_csrf_token()

    signed_in =
      conn(:post, "/login", %{"token" => token, "_csrf_token" => csrf})
      |> Map.put(:scheme, :https)
      |> recycle_cookies(form)
      |> ScfHost.Web.call(ScfHost.Web.init([]))

    assert signed_in.status == 303
    assert Plug.Conn.get_resp_header(signed_in, "location") == ["/journal"]
  end

  test "a rerun appends nothing, keeps the tokens and never prints them again", %{opts: opts} do
    {:ok, first} = ReleaseTasks.setup(opts)
    head = Log.head()
    before = File.read!(first.env_path)

    assert {:ok, second} = ReleaseTasks.setup(opts)
    refute Map.has_key?(second, :console_token)
    assert Log.head() == head
    assert File.read!(first.env_path) == before
  end

  test "lost tokens are recovered by rotation: new digests, same ledger, same keys", %{opts: opts} do
    {:ok, first} = ReleaseTasks.setup(opts)
    before = ReleaseTasks.read_env(first.env_path)
    head = Log.head()

    assert {:ok, %{console_token: token, api_token: api}} =
             ReleaseTasks.setup(Map.put(opts, :rotate_tokens, true))

    assert token != first.console_token and api != first.api_token
    after_ = ReleaseTasks.read_env(first.env_path)
    assert after_["SCF_LOGIN_SHA256"] == Base.encode16(:crypto.hash(:sha256, token), case: :lower)
    assert after_["SCF_API_SHA256"] == Base.encode16(:crypto.hash(:sha256, api), case: :lower)

    assert Map.drop(after_, ~w(SCF_LOGIN_SHA256 SCF_API_SHA256)) ==
             Map.drop(before, ~w(SCF_LOGIN_SHA256 SCF_API_SHA256))

    assert Log.head() == head
  end

  test "a chapter governed by another key is never adopted", %{opts: opts} do
    other = new_member("governance", "someone-else")

    {:ok, [_]} =
      Log.append(
        signed_event(
          other,
          "RoleKeyDeclared",
          %{
            "role" => "governance",
            "key_id" => "someone-else",
            "pubkey" => {:bytes, other.signer.pubkey}
          },
          chapter_id: "local",
          timestamp_ms: @now
        )
      )

    head = Log.head()
    assert {:error, :chapter_governed_by_another_key} = ReleaseTasks.setup(opts)
    assert Log.head() == head
    refute File.exists?(Path.join(opts.data_dir, "scf.env"))
  end

  test "an expired grant is renewed under the same key and the env file follows", %{opts: opts} do
    {:ok, first} = ReleaseTasks.setup(%{opts | grant_days: 1})
    login = ReleaseTasks.read_env(first.env_path)["SCF_LOGIN_SHA256"]
    ProcurementTestClock.set(@now + 2 * 86_400_000)

    assert {:ok, _} = ReleaseTasks.setup(opts)

    assert %{active: true, version: 2} =
             Scf.state(Log.gate()).grants[{"local", "sarl-atlas", "comptable"}]

    env = ReleaseTasks.read_env(first.env_path)
    assert env["SCF_GRANT_VERSION"] == "2"
    assert env["SCF_LOGIN_SHA256"] == login
  end
end
