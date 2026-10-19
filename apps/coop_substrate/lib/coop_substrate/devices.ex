defmodule CoopSubstrate.Devices do
  @moduledoc """
  A person's devices in a project, and their revocation
  (docs/architecture/2026-10-19-device-revocation.md,
  2026-10-19-own-devices.md). A device is what names the person's principal
  and a key they hold: an active operator or reviewer grant in the project,
  or an administrator key declared for them in its chapter.

    * **By its holder** (`prepare_revocation/4`): signed by one of the
      person's devices, the lost one's sibling or the device itself, with the
      command its role signs: `TaskDeviceRevokedV1` from an operator device,
      `TaskReviewerDeviceRevokedV1` from a reviewer device, a governance
      revocation from an administrator browser. An administrator key is
      revoked only from an administrator browser (`RoleKeyRevoked`), since the
      chapter's keys are derived from its governance history alone. Held for the principal like a
      decision (`Commands.hold/5`); the device signs and submits it.
    * **By governance** (`prepare_governance_revocation/2`, `revoke/3`): a
      `TaskOperatorRevokedV1` for any operator grant, or a
      `TaskReviewerRevokedV1` for a reviewer grant
      (docs/architecture/2026-10-19-execution.md), signed with a governance
      key by `mix coop.revoke`. Held for `{:revocation, grant_id}`.

  The server signs neither; the ledger admits both by its own rules.
  """

  alias CoopSubstrate.{Commands, Log}

  @type kind :: String.t()
  @type device :: %{
          id: String.t(),
          kind: kind(),
          grant_id: String.t() | nil,
          key_id: String.t(),
          label: String.t() | nil
        }

  # The order a key signs in when it holds several roles.
  @kinds ~w(operator reviewer administrator)

  @doc """
  The principal's devices in the project: operator and reviewer grants
  (`id` is the grant's event ID), then administrator keys of the chapter
  (`id` is the key ID).
  """
  @spec list(String.t(), CoopSubstrate.Feed.View.scope()) :: [device()]
  def list(principal, {chapter, _, _} = scope) do
    gate = Log.gate()
    o = gate.orchestration
    declared = gate.role_keys[{chapter, "governance"}] || %{}

    grants =
      for {kind, grants} <- [{"operator", o.grants}, {"reviewer", o.dod_grants}],
          {id, g} <- Enum.sort(grants),
          g.active and g.principal_id == principal and scope(g) == scope,
          do: %{id: id, kind: kind, grant_id: id, key_id: g.key_id, label: g.device_label}

    keys =
      for {{^chapter, "governance", key_id}, ^principal} <- Enum.sort(gate.role_key_members),
          Map.has_key?(declared, key_id),
          do: %{id: key_id, kind: "administrator", grant_id: nil, key_id: key_id, label: nil}

    grants ++ keys
  end

  @doc """
  Prepare the holder's revocation of their device `id`, to be signed by their
  device `key_id` with the command its role signs.
  """
  @spec prepare_revocation(String.t(), String.t(), CoopSubstrate.Feed.View.scope(), String.t()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare_revocation(principal, key_id, {chapter, _, _} = scope, id) do
    devices = list(principal, scope)

    with {:ok, target} <- find(devices, &(&1.id == id), :unknown_device),
         {:ok, signer} <- signing(devices, key_id, target) do
      {type, payload} = revocation(signer, target, principal, scope)
      Commands.hold(principal, chapter, type, payload, signer_of(signer, chapter))
    end
  end

  # The signing device: this key's operator grant, else its reviewer grant,
  # else its administrator key; for an administrator key, only another (or
  # the same) administrator key.
  defp signing(devices, key_id, %{kind: "administrator"}) do
    cond do
      Enum.any?(devices, &(&1.key_id == key_id and &1.kind == "administrator")) ->
        signing(devices, key_id, nil, ["administrator"])

      Enum.any?(devices, &(&1.key_id == key_id)) ->
        {:error, :needs_administrator}

      true ->
        {:error, :no_device}
    end
  end

  defp signing(devices, key_id, _target), do: signing(devices, key_id, nil, @kinds)

  defp signing(devices, key_id, _target, kinds) do
    Enum.find_value(kinds, {:error, :no_device}, fn kind ->
      case Enum.find(devices, &(&1.key_id == key_id and &1.kind == kind)) do
        nil -> nil
        device -> {:ok, device}
      end
    end)
  end

  defp revocation(%{kind: kind} = signer, target, principal, {_, tenant, project})
       when kind in ["operator", "reviewer"] do
    {if(kind == "reviewer", do: "TaskReviewerDeviceRevokedV1", else: "TaskDeviceRevokedV1"),
     %{
       "tenant_id" => tenant,
       "project_id" => project,
       "principal_id" => principal,
       "authorization_event_id" => signer.id,
       "revoked_grant_event_id" => target.id
     }}
  end

  defp revocation(%{kind: "administrator"}, %{kind: "administrator"} = target, _, _),
    do:
      {"RoleKeyRevoked",
       %{"role" => "governance", "key_id" => target.id, "reason" => "Revoked by its holder"}}

  defp revocation(%{kind: "administrator"}, target, _, {_, tenant, project}),
    do:
      {revocation_type(if(target.kind == "reviewer", do: "reviewer", else: "operator")),
       %{"tenant_id" => tenant, "project_id" => project, "authorization_event_id" => target.id}}

  defp signer_of(%{kind: "administrator", key_id: key_id}, chapter) do
    {:ok, signer} = Commands.governance_signer(chapter, key_id)
    signer
  end

  defp signer_of(%{kind: kind, id: id, key_id: key_id}, _chapter) do
    o = Log.gate().orchestration
    grant = if kind == "reviewer", do: o.dod_grants[id], else: o.grants[id]
    %{role: kind, pubkey: grant.pubkey, key_id: key_id}
  end

  @doc "Any operator or reviewer grant, for an administrator to judge."
  @spec fetch(String.t()) :: {:ok, map()} | {:error, :unknown_grant}
  def fetch(grant_id) do
    o = Log.gate().orchestration

    case {o.grants[grant_id], o.dod_grants[grant_id]} do
      {nil, nil} ->
        {:error, :unknown_grant}

      {g, r} ->
        g = g || r

        {:ok,
         %{
           grant_id: grant_id,
           role: if(r, do: "reviewer", else: "operator"),
           principal_id: g.principal_id,
           scope: scope(g),
           key_id: g.key_id,
           label: g.device_label,
           active: g.active
         }}
    end
  end

  @doc "Prepare a governance revocation of `grant_id`, held for `{:revocation, grant_id}`."
  @spec prepare_governance_revocation(String.t(), String.t()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare_governance_revocation(grant_id, governance_key_id) do
    with {:ok, %{active: true, scope: {chapter, tenant, project}} = g} <- active(fetch(grant_id)),
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold(
        {:revocation, grant_id},
        chapter,
        revocation_type(g.role),
        %{"tenant_id" => tenant, "project_id" => project, "authorization_event_id" => grant_id},
        signer
      )
    end
  end

  @doc "Submit the governance signature for a held revocation."
  @spec revoke(String.t(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def revoke(grant_id, held_id, signature),
    do: Commands.submit({:revocation, grant_id}, held_id, signature)

  @doc "The ledger type that revokes a grant of this role."
  def revocation_type("operator"), do: "TaskOperatorRevokedV1"
  def revocation_type("reviewer"), do: "TaskReviewerRevokedV1"
  def revocation_type(_role), do: nil

  defp active({:ok, %{active: false}}), do: {:error, :grant_already_revoked}
  defp active(other), do: other

  defp find(devices, pred, error) do
    case Enum.find(devices, pred) do
      nil -> {:error, error}
      device -> {:ok, device}
    end
  end

  defp scope(g), do: {g.chapter_id, g.tenant_id, g.project_id}
end
