defmodule Dispatch.Identity.Native do
  @moduledoc "Explicit platform-principal to existing Dispatch-account link. No email or provider-subject inference."
  @spec subject(map()) :: {:ok, String.t()} | {:error, :unlinked_principal}
  def subject(session) do
    case Map.get(Application.get_env(:dispatch, :mobile_principals, %{}), session.principal) do
      subject when is_binary(subject) and byte_size(subject) > 0 -> {:ok, subject}
      _ -> {:error, :unlinked_principal}
    end
  end
end
