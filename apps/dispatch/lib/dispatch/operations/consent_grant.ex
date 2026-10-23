defmodule Dispatch.Operations.ConsentGrant do
  @moduledoc """
  A participant's consent to share their location for one assignment
  (Sections 6.1, 22.5, 25.3).

  Explicit, visible and revocable: location sharing begins only with an active,
  unrevoked grant, and revoking it stops collection and portal updates except
  for samples acquired before the revocation (acceptance criterion 4). A grant
  is never edited otherwise: a new consent is a new grant, so what was agreed
  to, and when, stays on record.

  `scope_json` names the assignment the consent covers (`"assignment_id"`).
  """

  use Ash.Resource,
    otp_app: :dispatch,
    domain: Dispatch.Operations,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias Dispatch.Access.Checks.{ActingOnSelf, HasCapability, OwnRecords}

  postgres do
    table "consent_grants"
    repo Dispatch.Repo

    custom_indexes do
      index [:participant_id, :granted_at]
    end
  end

  multitenancy do
    strategy :attribute
    attribute :tenant_id
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :tenant_id, :uuid, allow_nil?: false, public?: true
    attribute :participant_id, :uuid, allow_nil?: false, public?: true
    attribute :role_assignment_id, :uuid, allow_nil?: false, public?: true

    attribute :kind, :atom do
      constraints one_of: [:LOCATION_SHARING]
      allow_nil? false
      public? true
    end

    attribute :scope_json, :map, allow_nil?: false, public?: true
    attribute :granted_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :expires_at, :utc_datetime_usec do
      description "The end of the sharing window: the assignment's end plus its grace period."
      public? true
    end

    attribute :revoked_at, :utc_datetime_usec, public?: true
  end

  actions do
    defaults [:read]

    create :begin_location_consent do
      accept [:tenant_id, :participant_id, :role_assignment_id, :scope_json, :expires_at]
      change set_attribute(:kind, :LOCATION_SHARING)
      change set_attribute(:granted_at, &DateTime.utc_now/0)
    end

    update :close_location_consent do
      description "Brings the expiry forward to the trip's end plus grace (Section 6.1). System work."
      accept [:expires_at]
      require_atomic? false
    end

    update :revoke_location_consent do
      description "Ends the consent at once. A revoked grant is never reinstated."
      accept []
      require_atomic? false
      validate attribute_equals(:revoked_at, nil), message: "is already revoked"
      change set_attribute(:revoked_at, &DateTime.utc_now/0)
    end
  end

  policies do
    # Section 23.2 attaches `self_only` and `requires_consent` to
    # `location.share.self`: the consent is the participant's own to give.
    policy action([:begin_location_consent, :revoke_location_consent]) do
      forbid_unless HasCapability.of("location.share.self")
      authorize_if ActingOnSelf.on(:participant_id)
    end

    policy action_type(:read) do
      authorize_if HasCapability.of("operations.participant.read")
      forbid_unless HasCapability.of("location.share.self")
      authorize_if OwnRecords.on(:participant_id)
    end
  end

  @doc "Whether `grant` covers an acquisition at `at` (granted, unexpired, unrevoked then)."
  @spec covers?(map(), DateTime.t()) :: boolean()
  def covers?(grant, %DateTime{} = at) do
    DateTime.compare(at, grant.granted_at) != :lt and before?(at, grant.expires_at) and
      before?(at, grant.revoked_at)
  end

  defp before?(_at, nil), do: true
  defp before?(at, bound), do: DateTime.compare(at, bound) == :lt
end
