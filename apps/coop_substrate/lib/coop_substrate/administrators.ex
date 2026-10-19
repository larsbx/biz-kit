defmodule CoopSubstrate.Administrators do
  @moduledoc """
  A chapter's administrators (docs/architecture/2026-10-19-administration.md):
  its declared governance keys and the principal each was declared for. An
  administrator's browser holds such a key, enrolled like a device
  (`CoopSubstrate.Enrolments`, role `governance`).

  Any governance key revokes another (`RoleKeyRevoked`), with a reason; the
  ledger refuses to revoke a chapter's last one. Held for
  `{:role_key_revocation, chapter, key_id}`; the server signs nothing.
  """

  alias CoopSubstrate.{Commands, Log}

  @doc "The chapter's governance keys, each with the principal it names, if any."
  @spec list(String.t()) :: [%{key_id: String.t(), principal_id: String.t() | nil}]
  def list(chapter) do
    gate = Log.gate()

    for {key_id, _pubkey} <- gate.role_keys[{chapter, "governance"}] || %{} do
      %{key_id: key_id, principal_id: gate.role_key_members[{chapter, "governance", key_id}]}
    end
    |> Enum.sort_by(& &1.key_id)
  end

  @doc "Prepare the revocation of governance key `key_id`, to be signed by `governance_key_id`."
  @spec prepare_revocation(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Commands.pending()} | {:error, term()}
  def prepare_revocation(chapter, key_id, reason, governance_key_id) do
    with true <-
           Map.has_key?(Log.gate().role_keys[{chapter, "governance"}] || %{}, key_id) or
             {:error, :unknown_role_key},
         {:ok, signer} <- Commands.governance_signer(chapter, governance_key_id) do
      Commands.hold(
        {:role_key_revocation, chapter, key_id},
        chapter,
        "RoleKeyRevoked",
        %{"role" => "governance", "key_id" => key_id, "reason" => reason},
        signer
      )
    end
  end

  @spec revoke(String.t(), String.t(), String.t(), binary()) ::
          {:ok, CoopSubstrate.Protocol.Envelope.t()} | {:error, term()}
  def revoke(chapter, key_id, held_id, signature),
    do: Commands.submit({:role_key_revocation, chapter, key_id}, held_id, signature)
end
