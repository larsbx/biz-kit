defmodule CoopSubstrate.Devices do
  @moduledoc """
  A person's devices in a project, and their revocation
  (docs/architecture/2026-10-19-device-revocation.md). A device is an active
  operator grant naming the person's principal and the device's key.

    * **By its holder** (`prepare_revocation/4`): a `TaskDeviceRevokedV1`
      signed by one of the person's devices still enrolled in the project,
      the lost one's sibling or the device itself. Held for the principal
      like a decision (`Commands.hold/5`); the device signs and submits it.
    * **By governance** (`prepare_governance_revocation/2`, `revoke/3`): a
      `TaskOperatorRevokedV1` for any grant, signed with a governance key by
      `mix coop.revoke`. Held for `{:revocation, grant_id}`.

  The server signs neither; the ledger admits both by its own rules.
  """

  alias CoopSubstrate.{Commands, Log}

  @type device :: %{grant_id: String.t(), key_id: String.t(), label: String.t() | nil}

  @doc "The principal's enrolled devices in the project."
  @spec list(String.t(), CoopSubstrate.Feed.View.scope()) :: [device()]
  def list(principal, scope) do
    for {id, g} <- Log.gate().orchestration.grants,
        g.active,
        g.principal_id == principal,
        scope(g) == scope,
        do: %{grant_id: id, key_id: g.key_id, label: g.device_label}
  end

  @doc "Prepare the holder's revocation of `grant_id`, to be signed by their device `key_id`."
  @spec prepare_revocation(String.t(), String.t(), CoopSubstrate.Feed.View.scope(), String.t()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare_revocation(principal, key_id, {chapter, tenant, project} = scope, grant_id) do
    devices = list(principal, scope)

    with {:ok, signing} <- find(devices, &(&1.key_id == key_id), :no_operator_grant),
         {:ok, _target} <- find(devices, &(&1.grant_id == grant_id), :unknown_device),
         %{pubkey: pubkey} = Log.gate().orchestration.grants[signing.grant_id] do
      Commands.hold(
        principal,
        chapter,
        "TaskDeviceRevokedV1",
        %{
          "tenant_id" => tenant,
          "project_id" => project,
          "principal_id" => principal,
          "authorization_event_id" => signing.grant_id,
          "revoked_grant_event_id" => grant_id
        },
        %{role: "operator", pubkey: pubkey, key_id: key_id}
      )
    end
  end

  @doc "Any operator grant, for an administrator to judge."
  @spec fetch(String.t()) :: {:ok, map()} | {:error, :unknown_grant}
  def fetch(grant_id) do
    case Log.gate().orchestration.grants[grant_id] do
      nil ->
        {:error, :unknown_grant}

      g ->
        {:ok,
         %{
           grant_id: grant_id,
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
    with {:ok, %{active: true, scope: {chapter, tenant, project}}} <- active(fetch(grant_id)),
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold(
        {:revocation, grant_id},
        chapter,
        "TaskOperatorRevokedV1",
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
