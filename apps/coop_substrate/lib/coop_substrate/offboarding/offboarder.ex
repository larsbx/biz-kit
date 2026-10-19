defmodule CoopSubstrate.Offboarding.Offboarder do
  @moduledoc """
  The administrator's side of offboarding
  (docs/architecture/2026-10-19-offboarding.md), behind `mix coop.offboard`:
  show what the principal holds, then, project by project, sign its
  `TaskPrincipalOffboardedV1` with the governance key only if it offboards
  exactly that principal from exactly that project
  (`CoopSubstrate.Governance.Client`).
  """

  alias CoopSubstrate.Governance.Client

  @doc "What the principal holds in the chapters `signer` governs (a signed read)."
  @spec fetch(String.t(), String.t(), Client.signer()) :: {:ok, map()} | {:error, term()}
  def fetch(base, principal, signer), do: Client.get_signed(url(base, principal), signer)

  @doc "Offboard from every project in `details`; stops at the first refusal."
  @spec offboard(String.t(), map(), Client.signer()) :: {:ok, [map()]} | {:error, term()}
  def offboard(base, %{"principal_id" => principal, "projects" => projects}, signer) do
    Enum.reduce_while(projects, {:ok, []}, fn project, {:ok, done} ->
      scope = Map.take(project, ~w(chapter_id tenant_id project_id))

      case Client.sign_held(
             url(base, principal) <> "/offboarding",
             signer,
             &offboards?(&1, principal, scope),
             scope
           ) do
        {:ok, appended} -> {:cont, {:ok, done ++ [Map.merge(scope, appended)]}}
        error -> {:halt, error}
      end
    end)
  end

  @spec offboards?(map(), String.t(), map()) :: boolean()
  def offboards?(core, principal, scope) do
    core["type"] == "TaskPrincipalOffboardedV1" and core["chapter_id"] == scope["chapter_id"] and
      core["payload"] == %{
        "tenant_id" => scope["tenant_id"],
        "project_id" => scope["project_id"],
        "principal_id" => principal
      }
  end

  defp url(base, principal), do: base <> "/api/v1/principals/" <> URI.encode(principal)
end
