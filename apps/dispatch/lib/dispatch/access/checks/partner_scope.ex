defmodule Dispatch.Access.Checks.PartnerScope do
  @moduledoc "SQL authorization for a partner's selected subject and active relationship."
  use Ash.Policy.FilterCheck

  alias Dispatch.Access.{Actor, RoleProfile}
  alias Dispatch.Identity.PrincipalResolution
  alias Dispatch.Accounts.{Participant, User}

  @impl true
  def describe(_), do: "active principal, selected assignment, tenant and party relationship"

  # Revalidation belongs in the policy too: a cached Actor is not a grant.
  # These are identity bootstrap reads, never domain data returned to a caller.
  def fresh(%Actor{principal_type: :PARTICIPANT} = actor) do
    with {:ok, fresh} <- PrincipalResolution.revalidate(actor),
         true <- fresh.principal_id == actor.principal_id,
         true <- fresh.role_assignment.principal_type == :PARTICIPANT,
         true <- fresh.role_assignment.tenant_id == actor.tenant_id,
         true <- fresh.role_assignment.role_definition.status == :ACTIVE,
         # REVIEWED-UNAUTHORIZED: identity bootstrap, no domain data returned.
         {:ok, %Participant{status: :ACTIVE} = participant} <-
           Ash.get(Participant, actor.principal_id, tenant: actor.tenant_id, authorize?: false),
         # REVIEWED-UNAUTHORIZED: confirm the principal can still authenticate.
         {:ok, %User{status: :ACTIVE}} <- Ash.get(User, participant.user_id, authorize?: false) do
      {:ok, fresh}
    else
      _ -> :error
    end
  end

  def fresh(_), do: :error

  @impl true
  def filter(actor, _context, opts) do
    with {:ok, actor} <- fresh(actor),
         true <- Actor.can?(actor, Keyword.fetch!(opts, :capability)) do
      subject(actor, Keyword.fetch!(opts, :subject))
    else
      _ -> expr(false)
    end
  end

  def subject(actor, :stop) do
    a = actor.role_assignment
    now = actor.at
    org = a.organization_id
    tenant = actor.tenant_id
    id = a.scope_id

    permitted_kinds =
      case RoleProfile.fetch(a.role_definition.profile_module) do
        {:ok, module} ->
          if function_exported?(module, :validate_stop_kind, 1),
            do:
              Enum.filter([:PICKUP, :DELIVERY], &(module.validate_stop_kind(&1) == :ok)) ++
                [:OTHER],
            else: []

        _ ->
          []
      end

    permitted_relationships =
      Enum.flat_map(Enum.reject(permitted_kinds, &(&1 == :OTHER)), fn
        :PICKUP -> [:SHIPPER, :FACILITY]
        :DELIVERY -> [:RECEIVER, :FACILITY]
        :OTHER -> [:SHIPPER, :RECEIVER, :FACILITY]
      end)

    case a.scope_type do
      :STOP ->
        expr(
          tenant_id == ^tenant and id == ^id and kind in ^permitted_kinds and
            exists(
              stop_parties,
              organization_id == ^org and tenant_id == ^tenant and
                relationship in ^permitted_relationships and status == :ACTIVE and
                starts_at <= ^now and (is_nil(ends_at) or ends_at > ^now)
            )
        )

      :LOAD ->
        expr(
          tenant_id == ^tenant and load_id == ^id and
            exists(
              load.load_parties,
              organization_id == ^org and tenant_id == ^tenant and
                relationship == :BROKER and status == :ACTIVE and starts_at <= ^now and
                (is_nil(ends_at) or ends_at > ^now)
            )
        )

      _ ->
        expr(false)
    end
  end

  def subject(actor, :load) do
    a = actor.role_assignment
    org = a.organization_id
    tenant = actor.tenant_id
    now = actor.at
    id = a.scope_id

    if a.scope_type == :LOAD do
      expr(
        tenant_id == ^tenant and id == ^id and
          exists(
            load_parties,
            organization_id == ^org and tenant_id == ^tenant and
              relationship == :BROKER and status == :ACTIVE and starts_at <= ^now and
              (is_nil(ends_at) or ends_at > ^now)
          )
      )
    else
      expr(false)
    end
  end

  # Child resources remain private to the contributing organization. A
  # relationship to the same freight is not permission to read another party's
  # proposals, proof references or communication content.
  def subject(actor, :record) do
    org = actor.role_assignment.organization_id
    tenant = actor.tenant_id
    stop_filter = subject(actor, :stop)
    expr(tenant_id == ^tenant and organization_id == ^org and exists(stop, ^stop_filter))
  end

  def subject(actor, :conversation) do
    a = actor.role_assignment
    org = a.organization_id
    now = actor.at
    tenant = actor.tenant_id
    id = a.scope_id

    if a.scope_type == :LOAD do
      expr(
        tenant_id == ^tenant and organization_id == ^org and load_id == ^id and
          exists(
            load.load_parties,
            organization_id == ^org and tenant_id == ^tenant and
              relationship == :BROKER and status == :ACTIVE and starts_at <= ^now and
              (is_nil(ends_at) or ends_at > ^now)
          )
      )
    else
      expr(false)
    end
  end

  def stop_kind?(actor, stop) do
    with {:ok, module} <- RoleProfile.fetch(actor.role_assignment.role_definition.profile_module),
         true <- function_exported?(module, :validate_stop_kind, 1) do
      module.validate_stop_kind(stop.kind) == :ok
    else
      _ -> false
    end
  end
end
