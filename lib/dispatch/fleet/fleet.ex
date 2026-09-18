defmodule Dispatch.Fleet do
  @moduledoc """
  Vehicles, trailers, loads, stops, assignments, and the party relationships
  that scope access to them.

  Section 22.2 makes a `LOAD`- or `STOP`-scoped grant require both an active
  role assignment and a matching active party row, so an organization kind, a
  phone number, or a caller's claim never grants access on its own.

  """

  use Ash.Domain

  resources do
    resource Dispatch.Fleet.Vehicle
    resource Dispatch.Fleet.Trailer
    resource Dispatch.Fleet.Load
    resource Dispatch.Fleet.LoadParty
    resource Dispatch.Fleet.Stop
    resource Dispatch.Fleet.StopParty
    resource Dispatch.Fleet.Assignment
    resource Dispatch.Fleet.AssignmentContact
  end
end
