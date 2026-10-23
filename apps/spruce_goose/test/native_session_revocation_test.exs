defmodule SpruceGoose.NativeSessionRevocationTest do
  use SpruceGoose.DataCase, async: false

  alias BizKit.Identity.Sessions
  alias SpruceGoose.Web.NativeSessionStore

  defmodule PausedPostgresStore do
    @behaviour BizKit.Identity.SessionStore
    defdelegate put(hash, principal, identity, at), to: NativeSessionStore
    defdelegate delete(hash), to: NativeSessionStore
    defdelegate delete_principal(principal), to: NativeSessionStore

    def get(hash) do
      row = NativeSessionStore.get(hash)

      if Application.get_env(:biz_kit_identity, :pause_postgres_read) == {hash, :armed} do
        owner = Application.fetch_env!(:biz_kit_identity, :postgres_read_owner)
        ref = make_ref()
        send(owner, {:postgres_read, self(), ref})

        receive do
          {:resume, ^ref} -> :ok
        after
          5_000 -> raise "Postgres read was not resumed"
        end
      end

      row
    end
  end

  setup do
    old = Application.fetch_env!(:biz_kit_identity, :session_store)
    Application.put_env(:biz_kit_identity, :session_store, PausedPostgresStore)
    Application.put_env(:biz_kit_identity, :postgres_read_owner, self())

    on_exit(fn ->
      Application.put_env(:biz_kit_identity, :session_store, old)
      Application.delete_env(:biz_kit_identity, :pause_postgres_read)
      Application.delete_env(:biz_kit_identity, :postgres_read_owner)
    end)

    :ok
  end

  for kind <- [:token, :principal] do
    @kind kind
    test "Postgres #{@kind} revocation wins over a captured store read" do
      principal = BizKit.Identity.Principal.new_id()
      identity = %{issuer: "https://idp.test", subject: principal}
      token = Sessions.create_native(principal, identity)
      other = Sessions.create_native(BizKit.Identity.Principal.new_id(), identity)
      reference = Sessions.reference(token)
      now = System.system_time(:millisecond)
      restart_sessions()
      hash = :crypto.hash(:sha256, token)
      Application.put_env(:biz_kit_identity, :pause_postgres_read, {hash, :armed})
      fetch = Task.async(fn -> Sessions.fetch(token, now) end)
      assert_receive {:postgres_read, reader, ref}, 2_000

      case @kind do
        :token -> :ok = Sessions.revoke(token)
        :principal -> :ok = Sessions.revoke_principal(principal)
      end

      Application.delete_env(:biz_kit_identity, :pause_postgres_read)
      send(reader, {:resume, ref})
      assert Task.await(fetch) == {:error, :unknown_session}
      assert Sessions.fetch(token, now) == {:error, :unknown_session}
      assert Sessions.fetch_reference(reference, now) == {:error, :unknown_session}
      assert NativeSessionStore.get(hash) == :error
      restart_sessions()
      assert Sessions.fetch(token, now) == {:error, :unknown_session}
      assert {:ok, _} = Sessions.fetch_reference(Sessions.reference(other), now)
      assert {:ok, _} = Sessions.fetch(other, now)
    end
  end

  defp restart_sessions do
    :ok = Supervisor.terminate_child(BizKit.Identity.Supervisor, Sessions)
    {:ok, _} = Supervisor.restart_child(BizKit.Identity.Supervisor, Sessions)
  end
end
