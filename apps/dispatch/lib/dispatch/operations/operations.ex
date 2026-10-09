defmodule Dispatch.Operations do
  @moduledoc """
  Participant status declarations, location samples, geofence events, stop
  readiness, and route snapshots.

  Section 1's four kinds of information stay distinct here. A declaration is
  authored only by the participant; a geofence or an agent runtime may suggest
  `AT_PICKUP` but cannot set it, and a correction appends a superseding event
  rather than rewriting history.

  """

  use Ash.Domain

  resources do
    resource Dispatch.Operations.ParticipantStatusEvent
  end
end
