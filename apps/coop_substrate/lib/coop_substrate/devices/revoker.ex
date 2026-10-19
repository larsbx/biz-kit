defmodule CoopSubstrate.Devices.Revoker do
  @moduledoc """
  The administrator's side of device revocation
  (docs/architecture/2026-10-19-device-revocation.md), behind
  `mix coop.revoke`: show the grant, then sign its revocation
  (`TaskOperatorRevokedV1` or `TaskReviewerRevokedV1`) with the governance
  key only if it revokes exactly that grant
  (`CoopSubstrate.Governance.Client`).
  """

  alias CoopSubstrate.Governance.Client

  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(base, grant_id), do: Client.get(url(base, grant_id))

  @spec revoke(String.t(), map(), Client.signer()) :: {:ok, map()} | {:error, term()}
  def revoke(base, %{"grant_id" => id} = details, signer),
    do: Client.sign_held(url(base, id) <> "/revocation", signer, &revokes?(&1, details))

  @spec revokes?(map(), map()) :: boolean()
  def revokes?(core, details) do
    core["type"] == CoopSubstrate.Devices.revocation_type(details["role"]) and
      core["chapter_id"] == details["chapter_id"] and
      core["payload"] == %{
        "tenant_id" => details["tenant_id"],
        "project_id" => details["project_id"],
        "authorization_event_id" => details["grant_id"]
      }
  end

  defp url(base, grant_id), do: base <> "/api/v1/grants/" <> Client.segment(grant_id)
end
