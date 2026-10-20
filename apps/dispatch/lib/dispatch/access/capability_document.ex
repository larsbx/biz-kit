defmodule Dispatch.Access.CapabilityDocument do
  @moduledoc """
  The signed server capability document of Section 23.2.

  "Android features are enabled from a signed server capability document, not
  from `if role == DRIVER` checks." This module decides what that document
  says; `Dispatch.Access.CapabilitySigner` signs it.

  ## What the document is not

  It is not authority. Every request the client makes is authorized again by
  the Ash policies behind it, against the role assignment the request names.
  The document tells the client which surfaces to *offer*, so a participant is
  not shown a control the server would refuse — and a stale or tampered copy
  can at worst offer one, never make it succeed.

  ## Binding

  A document names the OIDC subject, tenant, participant and role assignment it
  was issued for, and expires. The client rejects one whose subject or
  assignment is not the session's own, so a document cannot be carried from
  one login or one selected role to another.

  ## Features never exceed capabilities

  A profile module lists the Android features its role uses, but Section 23.2
  forbids a profile module from granting anything. So a feature that needs a
  capability is published only when the assignment carries it: a profile that
  lists `status` without `status.declare.self` publishes no status feature.
  """

  alias Dispatch.Access
  alias Dispatch.Access.Actor
  alias Dispatch.Operations.Status

  @schema_version 1

  # Twelve hours spans a working shift, so a device that went offline after the
  # morning refresh still has a current document by the end of it. The document
  # gates presentation only (see above), so the window trades staleness of
  # *offered* controls, not of authority.
  @ttl_seconds 12 * 60 * 60

  # The capability each feature exercises. A feature absent from this map needs
  # none beyond an active assignment.
  @feature_capability %{
    "status" => "status.declare.self",
    "location_sharing" => "location.share.self",
    "approvals" => "proposal.decide.self",
    "inbox" => "communications.read.self"
  }

  @doc "The document schema version the client must understand."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Seconds from issue to expiry."
  @spec ttl_seconds() :: pos_integer()
  def ttl_seconds, do: @ttl_seconds

  @doc """
  The claims for `actor`, authenticated as `subject`.

  Pure: `actor.at` is the issue instant, so the same actor always yields the
  same document.
  """
  @spec claims(Actor.t(), String.t()) :: map()
  def claims(%Actor{} = actor, subject) when is_binary(subject) do
    assignment = actor.role_assignment
    definition = assignment.role_definition
    capabilities = Actor.capabilities(actor)
    issued_at = DateTime.to_unix(actor.at)

    %{
      "schema_version" => @schema_version,
      "sub" => subject,
      "tenant_id" => actor.tenant_id,
      "participant_id" => actor.principal_id,
      "role_assignment_id" => assignment.id,
      "role" => %{
        "key" => definition.key,
        "label" => definition.label,
        "version" => definition.version
      },
      "capabilities" => Enum.map(capabilities, &capability(&1, definition.constraints_json)),
      "features" => features(actor, capabilities),
      "status_options" => status_options(capabilities),
      "iat" => issued_at,
      "exp" => issued_at + @ttl_seconds
    }
  end

  defp capability(key, constraints) do
    %{"key" => key, "constraints" => constraints |> Map.get(key, []) |> Enum.sort()}
  end

  defp features(actor, capabilities) do
    actor.role_assignment
    |> Access.android_features(actor.at)
    |> Enum.filter(fn feature ->
      case Map.fetch(@feature_capability, feature) do
        {:ok, required} -> required in capabilities
        :error -> true
      end
    end)
    |> Enum.sort()
  end

  # Section 5.1's vocabulary travels in the document so the client has one
  # source for it rather than a copy that can drift: the labels, the order, and
  # which codes need a note are all the server's.
  defp status_options(capabilities) do
    if "status.declare.self" in capabilities do
      Enum.map(Status.all(), fn code ->
        %{
          "value" => Atom.to_string(code),
          "label" => Status.label(code),
          "requires_note" => Status.requires_note?(code)
        }
      end)
    else
      []
    end
  end
end
