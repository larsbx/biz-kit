defmodule DispatchWeb.LocationJSON do
  @moduledoc "How a location consent is written on `/v1`, wherever it appears (`LocationConsent`)."

  @spec consent(struct()) :: map()
  def consent(grant) do
    %{
      consent_grant_id: grant.id,
      assignment_id: grant.scope_json["assignment_id"],
      granted_at: grant.granted_at,
      expires_at: grant.expires_at,
      revoked_at: grant.revoked_at
    }
  end
end
