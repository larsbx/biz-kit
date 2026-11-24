defmodule Dispatch.Access.MutationAuthority do
  @moduledoc """
  Current authority for a Board transition, inside its mutation transaction.

  Acquire the trip lock first, then the selected role assignment and its current
  definition in that order. SHARE row locks conflict with ordinary UPDATE and
  DELETE (including non-key updates), and remain held through mutation/audit
  commit. Never substitute another role held by the same principal.

  The admission instant is read AFTER all database locks. PostgreSQL transaction
  time and Actor.at can both predate a lock wait and are not admission clocks.
  Session checks are fresh at admission; the external Identity singleton is not
  part of this database transaction or a cross-store atomic commit protocol.
  """

  import Ecto.Query, only: [from: 2]
  alias Dispatch.Access.Actor
  alias Dispatch.Accounts.{RoleAssignment, RoleDefinition}
  alias Dispatch.Repo

  @spec transition(Actor.t()) :: {:ok, Actor.t()} | {:error, :forbidden}
  def transition(%Actor{} = actor) do
    with true <- Repo.in_transaction?(),
         true <- lock_row("role_assignments", actor.role_assignment.id, actor.tenant_id),
         {:ok, %RoleAssignment{} = assignment} <-
           Ash.get(RoleAssignment, actor.role_assignment.id,
             authorize?: false,
             tenant: actor.tenant_id
           ),
         true <- selected_context?(actor, assignment),
         true <- lock_row("role_definitions", assignment.role_definition_id, actor.tenant_id),
         {:ok, %RoleDefinition{status: :ACTIVE} = definition} <-
           Ash.get(RoleDefinition, assignment.role_definition_id,
             authorize?: false,
             tenant: actor.tenant_id
           ),
         true <- lock_identity(actor),
         at = DateTime.utc_now(),
         {:ok, fresh} <-
           Actor.from_assignment(%{assignment | role_definition: definition}, at: at),
         true <- Actor.can?(fresh, "assignment.update.status"),
         # This board mutates organization-owned trips. Narrower grants are
         # handled by their own scoped APIs, never widened here.
         true <- assignment.scope_type == :ORGANIZATION and is_nil(assignment.scope_id),
         true <- Map.get(definition.constraints_json, "assignment.update.status", []) == [],
         true <- authenticated?(actor.authentication, at) do
      {:ok, %{fresh | authentication: actor.authentication}}
    else
      _ -> {:error, :forbidden}
    end
  end

  defp selected_context?(actor, assignment) do
    assignment.principal_type == actor.principal_type and
      assignment.principal_id == actor.principal_id and
      assignment.tenant_id == actor.tenant_id and
      assignment.organization_id == actor.role_assignment.organization_id
  end

  # REVIEWED-UNAUTHORIZED: raw reads only lock the tenant-scoped selected rows;
  # no capability comes from the projection or a caller-supplied timestamp.
  defp lock_row(table, id, tenant) do
    from(row in table,
      where: row.id == type(^id, :binary_id) and row.tenant_id == type(^tenant, :binary_id),
      select: row.id,
      lock: "FOR SHARE"
    )
    |> Repo.one()
    |> is_binary()
  end

  # Authentication metadata exists only for HTTP-originated actors. Internal
  # jobs select an actor directly and are still subject to current grant checks.
  defp lock_identity(%Actor{authentication: nil}), do: true

  defp lock_identity(%Actor{principal_type: :PARTICIPANT} = actor) do
    subject = actor.authentication.subject

    from(p in "participants",
      join: u in "users",
      on: u.id == p.user_id,
      where: p.id == type(^actor.principal_id, :binary_id),
      where: p.tenant_id == type(^actor.tenant_id, :binary_id),
      where: p.status == "ACTIVE" and u.status == "ACTIVE" and u.oidc_subject == ^subject,
      select: p.id,
      lock: "FOR SHARE"
    )
    |> Repo.one()
    |> is_binary()
  end

  defp lock_identity(_actor), do: false

  defp authenticated?(nil, _at), do: true

  defp authenticated?(%{subject: subject, expires_at: expires} = authentication, at) do
    valid_time = match?(%DateTime{}, expires) and DateTime.compare(at, expires) == :lt

    case authentication[:session_reference] do
      reference when is_binary(reference) ->
        (is_nil(expires) or valid_time) and live_session?(reference, authentication, subject)

      _ ->
        valid_time
    end
  end

  defp authenticated?(_authentication, _at), do: false

  defp live_session?(reference, authentication, subject) do
    case BizKit.Identity.session_from_reference(reference) do
      {:ok, session} ->
        if authentication[:native?] do
          session.principal == authentication[:session_principal] and
            Dispatch.Identity.Native.subject(session) == {:ok, subject}
        else
          session.principal == subject
        end

      _ ->
        false
    end
  catch
    :exit, _ -> false
  end
end
