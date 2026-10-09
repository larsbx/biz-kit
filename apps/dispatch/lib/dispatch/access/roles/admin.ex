defmodule Dispatch.Access.Roles.Admin do
  @moduledoc """
  Tenant administration (Section 23.2).

  An administrator manages configuration, memberships, role assignments,
  integrations, retention, and audit. The profile grants no operational
  visibility: Section 23.3 states that an administrative role does not satisfy
  an operational read check, and acceptance criterion 14 requires a separate
  scoped role before precise location, message content, or negotiated load data
  becomes readable.

  It declares no Android features because Section 4.3 gives `ADMIN` a portal
  surface (`/settings`) and no field application.
  """

  use Dispatch.Access.Roles.Base, projection: :settings
end
