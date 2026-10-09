defmodule Dispatch.Identity.Face.DisabledVerifierTest do
  @moduledoc """
  Section 31 makes the disabled verifier the default, and Section 7.4 fixes what
  it may say. The distinction these protect is the one Section 7 is built on: a
  disabled feature must not be reported as a biometric decision.
  """

  use ExUnit.Case, async: true

  alias Dispatch.Identity.Face.DisabledVerifier

  test "no purpose may issue a challenge while face matching is disabled" do
    for purpose <- ~w(
          ACCOUNT_RECOVERY DEVICE_REBIND CONSEQUENTIAL_ACTION_APPROVAL
          SENSITIVE_DOCUMENT_ACCESS PAYOUT_OR_CONTACT_CHANGE
        )a do
      refute DisabledVerifier.issue_challenge?(purpose)
    end
  end

  test "verification reports ENROLLMENT_REQUIRED, never a match or a mismatch" do
    assert {:ok, :ENROLLMENT_REQUIRED} = DisabledVerifier.verify(%{})
  end

  test "the fallback path is REVIEW_REQUIRED, which asserts neither match nor mismatch" do
    assert {:ok, :REVIEW_REQUIRED} = DisabledVerifier.fallback_result(:ACCOUNT_RECOVERY)
  end

  test "the disabled verifier can never return VERIFIED" do
    results = [
      DisabledVerifier.verify(%{}),
      DisabledVerifier.fallback_result(:CONSEQUENTIAL_ACTION_APPROVAL)
    ]

    refute Enum.any?(results, &match?({:ok, :VERIFIED}, &1))
  end
end
