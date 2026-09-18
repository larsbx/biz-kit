defmodule Dispatch.Operations do
  @moduledoc """
  Participant status declarations, location samples, geofence events, stop
  readiness, and route snapshots.

  Section 1's four kinds of information stay distinct here. A declaration is
  authored only by the participant; a geofence or an agent runtime may suggest
  `AT_PICKUP` but cannot set it, and a correction appends a superseding event
  rather than rewriting history.

  Slice 1 onward adds resources; the domain itself is declared from Slice 0 so
  each one has a named home rather than being invented under deadline.
  """

  use Ash.Domain

  resources do
  end
end
