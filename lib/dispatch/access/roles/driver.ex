defmodule Dispatch.Access.Roles.Driver do
  @moduledoc """
  The initial field-role profile (Section 23.2).

  `DRIVER` is a seeded, versioned role definition, not an identity type. It may
  be renamed in presentation without changing its stable key, and adding an
  owner-operator, team-driver, or courier profile means a new definition rather
  than a change here.
  """

  use Dispatch.Access.Roles.Base,
    projection: :participant,
    android_features: ~w(
      home
      status
      map
      inbox
      approvals
      settings
      location_sharing
      eld_notifications
    )

  alias Dispatch.Operations.Status

  @doc """
  Whether the driver may declare `requested` from `current`.

  Section 5.1 lets a driver correct or supersede a status at any time — a
  correction is a new event, never a rewrite — so almost every transition is
  legal. What this validates is the small set of rules Section 24.1 does state:
  the status must be canonical, and `DELAYED` and `BREAKDOWN` carry a required
  note, which the caller supplies in `context`.
  """
  @impl Dispatch.Access.RoleProfile
  def validate_status_transition(_current, requested, context) do
    cond do
      not Status.known?(requested) ->
        {:error, :unknown_status}

      Status.requires_note?(requested) and blank?(Map.get(context, :note)) ->
        {:error, :note_required}

      true ->
        :ok
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
