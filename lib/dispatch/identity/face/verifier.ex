defmodule Dispatch.Identity.Face.Verifier do
  @moduledoc """
  Server-side face-verification port (Sections 7 and 25.6).

  The comparison itself never happens here. Section 7.3 keeps raw frames, the
  template, landmarks, liveness signals, and the similarity score inside the
  on-device verifier, so the server's role is to decide whether a challenge may
  be issued at all and to classify the outcome into the Section 7.4 taxonomy.
  """

  @typedoc "The canonical result taxonomy of Section 7.4."
  @type result ::
          :VERIFIED
          | :NOT_MATCHED
          | :LIVENESS_FAILED
          | :QUALITY_INSUFFICIENT
          | :MULTIPLE_FACES
          | :USER_CANCELLED
          | :LOCKED_OUT
          | :CONSENT_REQUIRED
          | :ENROLLMENT_REQUIRED
          | :DEVICE_UNTRUSTED
          | :SENSOR_UNAVAILABLE
          | :CHALLENGE_INVALID
          | :PROVIDER_ERROR
          | :REVIEW_REQUIRED

  @doc "Stable provider identifier recorded on attestations and metrics."
  @callback provider_id() :: String.t()

  @doc "Whether a challenge may be issued for this purpose under current policy."
  @callback issue_challenge?(purpose :: atom()) :: boolean()

  @doc """
  Classifies a submitted attestation into the canonical taxonomy.

  Section 33.1 requires every provider result to map exactly once, with unknown
  values failing as `PROVIDER_ERROR` rather than as a low-confidence success.
  """
  @callback verify(request :: map()) :: {:ok, result()} | {:error, term()}

  @doc "The non-face path for a purpose (Section 7.6)."
  @callback fallback_result(purpose :: atom()) :: {:ok, result()} | {:error, term()}
end
