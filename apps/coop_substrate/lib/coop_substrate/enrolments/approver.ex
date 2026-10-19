defmodule CoopSubstrate.Enrolments.Approver do
  @moduledoc """
  The administrator's side of device enrolment
  (docs/architecture/2026-10-19-device-enrolment.md), behind
  `mix coop.enrol`: show the request, then sign the operator or reviewer
  grant, or the administrator's governance key declaration, with the
  governance key only if it grants exactly that request
  (`CoopSubstrate.Governance.Client`).
  """

  alias CoopSubstrate.Governance.Client

  @doc "The request a code names, as the server reports it."
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(base, code), do: Client.get(url(base, code))

  @doc "Approve the request `details` describes (from `fetch/2`), signing with `signer`."
  @spec approve(String.t(), map(), Client.signer()) :: {:ok, map()} | {:error, term()}
  def approve(base, %{"code" => code} = details, signer),
    do: Client.sign_held(url(base, code) <> "/approval", signer, &grants?(&1, details))

  @doc "Whether the decoded core is exactly the grant the request asks for."
  @spec grants?(map(), map()) :: boolean()
  def grants?(core, %{"role" => "governance"} = details) do
    core["type"] == "RoleKeyDeclared" and core["chapter_id"] == details["chapter_id"] and
      core["payload"] == %{
        "role" => "governance",
        "key_id" => details["key_id"],
        "pubkey" => {:bytes, Base.url_decode64!(details["public_key"], padding: false)},
        "member_id" => details["principal_id"]
      }
  end

  def grants?(core, details) do
    core["type"] == CoopSubstrate.Enrolments.grant_type(details["role"]) and
      core["chapter_id"] == details["chapter_id"] and
      core["payload"] == %{
        "tenant_id" => details["tenant_id"],
        "project_id" => details["project_id"],
        "principal_id" => details["principal_id"],
        "key_id" => details["key_id"],
        "pubkey" => {:bytes, Base.url_decode64!(details["public_key"], padding: false)},
        "device_label" => details["label"]
      }
  end

  defp url(base, code), do: base <> "/api/v1/enrolments/" <> Client.segment(code)
end
