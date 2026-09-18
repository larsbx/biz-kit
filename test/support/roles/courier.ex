defmodule Dispatch.Support.Roles.Courier do
  @moduledoc """
  A test-only field-role profile that permits concurrent assignments.

  Section 22.2 scopes the one-active-assignment rule to the `DRIVER` profile and
  lets other profiles declare a different cardinality. That branch is untestable
  without an actual other profile, and an untested branch of a constraint this
  close to authorization is indistinguishable from one that does not work.

  A courier running several parcel routes at once is the realistic case, but
  nothing here depends on the domain: its purpose is to prove that the partial
  unique index tracks the profile's declaration rather than applying universally.

  Section 33.2 anticipates exactly this — "a fake field-role profile can declare
  status and share location through canonical participant endpoints without
  adding a table, controller, tool schema, or Android repository." It compiles
  only in the test environment and appears only in the test allowlist, so it
  cannot be selected anywhere else.
  """

  use Dispatch.Access.Roles.Base,
    projection: :participant,
    android_features: ~w(home status inbox),
    concurrent_assignments: true
end
