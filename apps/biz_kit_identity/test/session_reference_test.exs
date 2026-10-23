defmodule BizKit.Identity.SessionReferenceTest do
  use ExUnit.Case, async: false

  alias BizKit.Identity
  alias BizKit.Identity.{Principal, Sessions, PausedSessionStore}

  setup do
    old = Application.get_all_env(:biz_kit_identity)
    principal = Principal.new_id()
    identity = %{issuer: "https://reference.test", subject: principal}
    Application.put_env(:biz_kit_identity, :bindings, [Map.put(identity, :principal, principal)])

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:biz_kit_identity),
          not Keyword.has_key?(old, key),
          do: Application.delete_env(:biz_kit_identity, key)

      Application.put_all_env(biz_kit_identity: old)
    end)

    %{principal: principal, identity: identity}
  end

  test "a reference cannot be used as a bearer, and expires at the same boundary", ctx do
    token = Sessions.create(ctx.principal, ctx.identity)
    reference = Sessions.reference(token)
    assert {:ok, session} = Identity.session_from_reference(reference)
    assert {:error, :unknown_session} = Identity.session(reference)
    assert {:ok, _} = Identity.session_from_reference(reference, session.expires_at - 1)
    assert {:error, :expired} = Identity.session_from_reference(reference, session.expires_at)
    assert {:error, _} = Identity.session_from_reference(reference)
  end

  test "unknown and malformed references fail closed" do
    for reference <- [nil, 42, %{}, "", "wsr_bad", "nsr_", String.duplicate("x", 100)] do
      assert {:error, :unknown_session} = Identity.session_from_reference(reference)
    end
  end

  test "references inherit logout, principal revocation and identity unbinding", ctx do
    for ending <- [:logout, :principal, :unbind] do
      token = Sessions.create(ctx.principal, ctx.identity)
      reference = Sessions.reference(token)
      assert {:ok, _} = Identity.session_from_reference(reference)

      case ending do
        :logout -> Identity.logout(token)
        :principal -> Identity.revoke_principal(ctx.principal)
        :unbind -> Application.put_env(:biz_kit_identity, :bindings, [])
      end

      assert {:error, _} = Identity.session_from_reference(reference)
    end
  end

  test "a native reference restores durably but a captured read cannot undo logout", ctx do
    {:ok, store} = PausedSessionStore.start_link()
    Application.put_env(:biz_kit_identity, :session_store, PausedSessionStore)
    on_exit(fn -> if Process.alive?(store), do: Agent.stop(store) end)
    token = Sessions.create_native(ctx.principal, ctx.identity)
    reference = Sessions.reference(token)
    restart()
    assert {:ok, _} = Identity.session_from_reference(reference)
    restart()
    PausedSessionStore.pause_next_read(self())
    lookup = Task.async(fn -> Identity.session_from_reference(reference) end)
    assert_receive {:store_read, reader, ref}
    :ok = Identity.logout(token)
    send(reader, {:resume, ref})
    assert {:error, _} = Task.await(lookup)
    restart()
    assert {:error, _} = Identity.session_from_reference(reference)
  end

  defp restart do
    :ok = Supervisor.terminate_child(BizKit.Identity.Supervisor, Sessions)
    {:ok, _} = Supervisor.restart_child(BizKit.Identity.Supervisor, Sessions)
  end
end
