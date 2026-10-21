defmodule SpruceGoose.GrantHistoryTest do
  use SpruceGoose.DataCase, async: false

  alias SpruceGoose.Actors.{Actor, Grant, Registry, Resolver, Scope}
  alias SpruceGoose.CLI.{Command, Executor}

  test "revocation retains provenance, removes authority and permits a fresh grant" do
    subject = actor!("history-agent")
    admin = Application.fetch_env!(:spruce_goose, :default_actor)
    assert {:ok, _} = Executor.run({:grant_role, subject.name, "operator", "*"}, admin)
    [original] = grants(subject)
    assert Scope.holds?(subject, :operator, :global)

    assert {:error, _} =
             Executor.run({:revoke_role, subject.name, "operator", "*"}, subject.name)

    assert [^original] = grants(subject)

    assert {:ok, %{grants: []}} =
             Executor.run({:revoke_role, subject.name, "operator", "*"}, admin)

    assert grants(subject) == []
    refute Scope.holds?(subject, :operator, :global)
    refute Scope.holds?(subject, :reader, :global)
    assert Scope.readable_projects(subject) == []
    assert Scope.summary(subject) == []
    assert {:ok, %{grants: []}} = Executor.run(:whoami, subject.name)
    assert {:error, _} = Executor.run(:list_projects, subject.name)
    assert %{grants: []} = Ash.load!(subject, :grants, authorize?: false)

    assert {:ok, %{grants: [closed]}} = Executor.run({:grant_history, subject.name, nil}, admin)
    assert closed.id == original.id
    assert closed.actor == subject.name
    assert closed.granted_by == admin
    assert closed.granted_at == original.granted_at
    assert closed.revoked_by == admin
    assert DateTime.compare(closed.revoked_at, original.granted_at) in [:eq, :gt]

    assert {:error, _} = Executor.run({:revoke_role, subject.name, "operator", "*"}, admin)
    assert {:ok, %{grants: [^closed]}} = Executor.run({:grant_history, subject.name, nil}, admin)

    assert {:ok, _} = Executor.run({:grant_role, subject.name, "operator", "*"}, admin)
    assert [replacement] = grants(subject)
    refute replacement.id == original.id
    assert Scope.holds?(subject, :operator, :global)
    assert {:error, _} = Executor.run({:grant_role, subject.name, "operator", "*"}, admin)
    assert {:ok, %{grants: history}} = Executor.run({:grant_history, subject.name, nil}, admin)
    assert length(history) == 2
    assert Enum.find(history, &(&1.id == original.id)) == closed
    assert {:ok, %{grants: [active]}} = Executor.run({:list_grants, subject.name, nil}, admin)
    assert active.id == replacement.id
    assert active.revoked_at == nil
  end

  test "revoked admins confer no registry power or last-admin recovery capacity" do
    backup = actor!("history-admin")
    admin = Application.fetch_env!(:spruce_goose, :default_actor)
    assert {:ok, _} = Executor.run({:grant_role, backup.name, "admin", "*"}, admin)
    assert {:ok, stale} = Resolver.resolve(backup.name)
    assert {:ok, _} = Executor.run({:revoke_role, backup.name, "admin", "*"}, admin)
    assert {:error, _} = Registry.grant(backup.name, "operator", "*", stale)
    assert {:error, _} = Registry.grant_history(nil, nil, stale)
    assert {:error, message} = Executor.run({:revoke_role, admin, "admin", "*"}, admin)
    assert message =~ "last active global admin"
  end

  test "database refuses deletion, rewriting, reopening and incomplete revocation" do
    subject = actor!("history-guard")

    grant =
      Ash.create!(
        Grant,
        %{
          actor_id: subject.id,
          role: :reader,
          scope: "*",
          granted_by: "test"
        },
        authorize?: false
      )

    id = Ecto.UUID.dump!(grant.id)

    for sql <- [
          "DELETE FROM actor_grants WHERE id = $1",
          "UPDATE actor_grants SET granted_by = 'forged' WHERE id = $1",
          "UPDATE actor_grants SET revoked_at = now() WHERE id = $1"
        ] do
      assert {:error, %Postgrex.Error{}} = Repo.query(sql, [id], mode: :savepoint)
    end

    assert {:ok, closed} =
             Ash.update(grant, %{revoked_by: "test"}, action: :revoke, authorize?: false)

    for sql <- [
          "DELETE FROM actor_grants WHERE id = $1",
          "UPDATE actor_grants SET revoked_at = NULL, revoked_by = NULL WHERE id = $1",
          "UPDATE actor_grants SET revoked_by = 'forged' WHERE id = $1"
        ] do
      assert {:error, %Postgrex.Error{}} = Repo.query(sql, [id], mode: :savepoint)
    end

    assert [persisted] =
             Ash.read!(Grant, action: :history, authorize?: false)
             |> Enum.filter(&(&1.id == grant.id))

    assert persisted.revoked_at == closed.revoked_at
    assert persisted.revoked_by == "test"

    assert {:error, %Postgrex.Error{}} =
             Repo.query("DELETE FROM actors WHERE id = $1", [Ecto.UUID.dump!(subject.id)],
               mode: :savepoint
             )

    assert Ash.Resource.Info.action(Grant, :destroy) == nil
  end

  test "history is an explicit admin-only CLI command" do
    subject = actor!("history-reader")
    name = subject.name
    assert {:ok, {:grant_history, nil, nil}} = Command.parse(["grant", "history"])

    assert {:ok, {:grant_history, ^name, "reader"}} =
             Command.parse(["grant", "history", "--actor", subject.name, "--role", "reader"])

    assert {:error, _} = Executor.run({:grant_history, nil, nil}, subject.name)
  end

  defp actor!(name) do
    Ash.create!(Actor, %{name: name, kind: :human, created_by: "history-test"}, authorize?: false)
  end

  defp grants(actor) do
    Ash.read!(Grant, authorize?: false) |> Enum.filter(&(&1.actor_id == actor.id))
  end
end
