defmodule Dispatch.Identity.Face.DisabledVerifier do
  @moduledoc """
  The server-side counterpart to Android's `DisabledFaceVerifier` (Section 25.6).

  `FACE_1_TO_1_ENABLED` defaults to false (Section 31), and while it is false no
  face challenge may be issued. Section 7.4 gives the two results that express
  this without asserting a match or a mismatch: `ENROLLMENT_REQUIRED` when no
  enrollment could exist, and `REVIEW_REQUIRED` when policy deliberately routes
  to the non-face path.

  Section 7.6 requires every face-gated purpose to keep an equivalent non-face
  fallback, so a disabled verifier degrades the mechanism and never the outcome.
  """

  @behaviour Dispatch.Identity.Face.Verifier

  @impl true
  def provider_id, do: "disabled"

  @impl true
  def issue_challenge?(_purpose), do: false

  @impl true
  def verify(_request), do: {:ok, :ENROLLMENT_REQUIRED}

  @impl true
  def fallback_result(_purpose), do: {:ok, :REVIEW_REQUIRED}
end
